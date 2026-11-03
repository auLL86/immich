import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/backup/backup_filter_profile.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/backup_filter.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';

/// Port of the `immich-filters` service on LAN/Tailscale (the public URL uses the same origin as
/// Immich with the `/immich-filters` path routed by the Cloudflare tunnel).
const kBackupFilterLanPort = 2284;
const kBackupFilterPath = '/immich-filters';

/// Candidate base URLs of the filter service for an Immich server endpoint such as
/// `https://foto.example.com/api` or `http://192.168.1.2:2283/api`.
List<Uri> backupFilterBaseUrls(String? serverEndpoint) {
  if (serverEndpoint == null || serverEndpoint.isEmpty) {
    return const [];
  }
  final uri = Uri.tryParse(serverEndpoint);
  if (uri == null || uri.host.isEmpty) {
    return const [];
  }
  final sameOrigin = uri.replace(path: kBackupFilterPath, query: null, fragment: null);
  final out = [sameOrigin];
  if (isLanOrTailscaleHost(uri.host)) {
    out.add(Uri(scheme: 'http', host: uri.host, port: kBackupFilterLanPort, path: kBackupFilterPath));
  }
  return out;
}

/// Keeps the locally cached shared filter document in sync with the `immich-filters` service.
/// Last write wins per key: local edits push only the edited keys, the server bumps `version`.
/// Offline the cached copy (or the defaults) is used, so the backup never waits on the network.
class BackupFilterSyncService {
  static final _log = Logger('BackupFilterSyncService');
  static Uri? _workingBase;
  static Future<BackupFilterDocument?>? _inFlight;
  static DateTime? _lastSync;

  static SettingsRepository get _settings => SettingsRepository.instance;

  static BackupFilterDocument get document => _settings.appConfig.backup.filterDocument;

  static String? get deviceId => Store.tryGet(StoreKey.deviceId);

  /// Profile with this device's overrides applied.
  static BackupFilterProfile get effectiveProfile => document.effectiveFor(deviceId);

  static Map<String, Object?>? get deviceOverrides {
    final id = deviceId;
    return id == null ? null : document.deviceOverrides[id];
  }

  static Future<void> _save(BackupFilterDocument doc) async {
    await _settings.write(SettingsKey.backupFilterProfile, doc.encode());
    // keep the PR #1 setting in sync so older code paths/readers agree
    await _settings.write(SettingsKey.backupMaxFileSizeMb, doc.profile.maxFileSizeMb);
  }

  /// Applies a local edit (keys of [BackupFilterProfile.toJson]) and pushes it in the background.
  static Future<void> updateProfile(Map<String, Object?> changes) async {
    final doc = document;
    await _save(
      doc.copyWith(profile: doc.profile.patch(changes), dirty: true, dirtyKeys: {...doc.dirtyKeys, ...changes.keys}),
    );
    unawaited(sync(force: true));
  }

  /// Sets (or with null clears) this device's overrides and pushes them in the background.
  static Future<void> updateDeviceOverrides(Map<String, Object?>? overrides) async {
    final id = deviceId;
    if (id == null) {
      return;
    }
    final doc = document;
    final devices = Map<String, Map<String, Object?>>.from(doc.deviceOverrides);
    if (overrides == null || overrides.isEmpty) {
      devices.remove(id);
    } else {
      devices[id] = overrides;
    }
    await _save(doc.copyWith(deviceOverrides: devices, dirty: true, dirtyKeys: {...doc.dirtyKeys, '@device'}));
    unawaited(sync(force: true));
  }

  static Map<String, String> _headers() {
    final headers = <String, String>{...ApiService.getRequestHeaders(), 'Accept': 'application/json'};
    final token = Store.tryGet(StoreKey.accessToken);
    if (token != null && token.isNotEmpty) {
      headers['x-immich-user-token'] = token;
    }
    return headers;
  }

  static http.Client _client() {
    try {
      return NetworkRepository.client;
    } catch (_) {
      return http.Client();
    }
  }

  /// Fetches the server profile (pushing pending local edits first). Returns the new document or
  /// null when sync is disabled/offline. Calls within [minInterval] are skipped unless [force].
  static Future<BackupFilterDocument?> sync({
    bool force = false,
    Duration minInterval = const Duration(minutes: 5),
    Duration timeout = const Duration(seconds: 8),
  }) {
    if (!_settings.appConfig.backup.filterSyncEnabled) {
      return Future.value(null);
    }
    final last = _lastSync;
    if (!force && last != null && DateTime.now().difference(last) < minInterval) {
      return Future.value(document);
    }
    return _inFlight ??= _sync(timeout).whenComplete(() => _inFlight = null);
  }

  static Future<BackupFilterDocument?> _sync(Duration timeout) async {
    final bases = [?_workingBase, ...backupFilterBaseUrls(Store.tryGet(StoreKey.serverEndpoint))];
    if (bases.isEmpty || Store.tryGet(StoreKey.accessToken) == null) {
      return null;
    }
    final client = _client();
    for (final base in bases.toSet()) {
      try {
        final doc = await _syncWith(client, base, timeout);
        if (doc != null) {
          _workingBase = base;
          _lastSync = DateTime.now();
          return doc;
        }
      } catch (e) {
        _log.fine('Filter sync via $base failed: $e');
      }
    }
    _workingBase = null;
    return null;
  }

  static Future<BackupFilterDocument?> _syncWith(http.Client client, Uri base, Duration timeout) async {
    final headers = _headers();
    final local = document;
    Map<String, Object?>? serverJson;

    if (local.dirty) {
      final keys = local.dirtyKeys.where((k) => k != '@device').toSet();
      if (keys.isNotEmpty) {
        final all = local.profile.toJson();
        final body = jsonEncode({
          'profile': {for (final k in keys) k: all[k]},
          'updatedBy': 'immich-mobile:${deviceId ?? '?'}',
        });
        final res = await client
            .put(
              base.replace(path: '${base.path}/v1/profile'),
              headers: {...headers, 'Content-Type': 'application/json'},
              body: body,
            )
            .timeout(timeout);
        if (res.statusCode == 404) {
          return null;
        }
        if (res.statusCode != 200) {
          throw Exception('PUT profile -> ${res.statusCode}');
        }
        serverJson = Map<String, Object?>.from(jsonDecode(res.body) as Map);
      }
      final id = deviceId;
      if (local.dirtyKeys.contains('@device') && id != null) {
        final overrides = local.deviceOverrides[id];
        final uri = base.replace(path: '${base.path}/v1/devices/${Uri.encodeComponent(id)}');
        final res = overrides == null
            ? await client.delete(uri, headers: headers).timeout(timeout)
            : await client
                  .put(
                    uri,
                    headers: {...headers, 'Content-Type': 'application/json'},
                    body: jsonEncode({'name': 'immich-mobile', 'overrides': overrides}),
                  )
                  .timeout(timeout);
        if (res.statusCode == 404 && overrides != null) {
          return null;
        }
        if (res.statusCode != 200) {
          throw Exception('device overrides -> ${res.statusCode}');
        }
        serverJson = Map<String, Object?>.from(jsonDecode(res.body) as Map);
      }
    }

    if (serverJson == null) {
      final res = await client.get(base.replace(path: '${base.path}/v1/profile'), headers: headers).timeout(timeout);
      if (res.statusCode == 404) {
        return null;
      }
      if (res.statusCode != 200) {
        throw Exception('GET profile -> ${res.statusCode}');
      }
      serverJson = Map<String, Object?>.from(jsonDecode(res.body) as Map);
    }

    var doc = BackupFilterDocument.fromServerJson(serverJson);
    final current = document;
    // an edit made while the request was in flight stays dirty and is pushed next time
    if (current.encode() != local.encode()) {
      final pendingKeys = current.dirtyKeys;
      final pending = current.profile.toJson();
      doc = doc.copyWith(
        profile: doc.profile.patch({for (final k in pendingKeys) k: pending[k]}),
        deviceOverrides: pendingKeys.contains('@device') ? current.deviceOverrides : null,
        dirty: true,
        dirtyKeys: pendingKeys,
      );
    }
    await _save(doc);
    return doc;
  }
}
