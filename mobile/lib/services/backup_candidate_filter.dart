import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/backup/backup_filter_profile.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/backup_filter.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/services/backup_filter_sync.service.dart';

/// Applies the shared backup filters to one automatic backup run (foreground, Android worker and
/// iOS URLSession backup). Manual uploads never use this.
class BackupCandidateFilter {
  final BackupFilter filter;

  /// Whether the active server URL is on LAN/Tailscale (large-file rule).
  final bool onLan;
  final Map<String, Set<String>> _albumNames;
  final Map<BackupSkipReason, int> skipped = {};

  BackupCandidateFilter(BackupFilterProfile profile, {required this.onLan, Map<String, Set<String>>? albumNames})
    : filter = BackupFilter(profile),
      _albumNames = albumNames ?? {};

  BackupFilterProfile get profile => filter.profile;

  static bool get currentEndpointIsLan => isLanOrTailscaleUrl(Store.tryGet(StoreKey.serverEndpoint));

  /// Loads candidates for [userId] (including always-backup albums) and applies the metadata
  /// filters. File-level checks (size, iOS screenshot subtype) happen at upload time.
  static Future<({List<LocalAsset> candidates, BackupCandidateFilter filter})> load(
    BackupRepository repository,
    String userId, {
    bool onlyHashed = true,
    BackupFilterProfile? profile,
    bool? onLan,
    DateTime? now,
  }) async {
    final p = profile ?? BackupFilterSyncService.effectiveProfile;
    final all = await repository.getCandidates(
      userId,
      onlyHashed: onlyHashed,
      alwaysBackupAlbumNames: p.alwaysBackupAlbums,
    );
    final names = all.isEmpty ? <String, Set<String>>{} : await repository.getAlbumNamesForAssets(all.map((a) => a.id));
    final f = BackupCandidateFilter(p, onLan: onLan ?? currentEndpointIsLan, albumNames: names);
    return (candidates: f.apply(all, now: now), filter: f);
  }

  Set<String> albumNamesOf(LocalAsset asset) => _albumNames[asset.id] ?? const {};

  bool isAlwaysBackup(LocalAsset asset) => filter.isAlwaysBackup(albumNamesOf(asset));

  BackupFilterInput inputFor(LocalAsset asset, {String? relativePath, bool? isScreenshotSubtype}) => BackupFilterInput(
    isVideo: asset.type == AssetType.video,
    isImage: asset.type == AssetType.image,
    createdAt: asset.createdAt,
    isFavorite: asset.isFavorite,
    fileName: asset.name,
    albumNames: albumNamesOf(asset),
    relativePath: relativePath,
    isScreenshotSubtype: isScreenshotSubtype,
  );

  void _count(BackupSkipReason r) => skipped[r] = (skipped[r] ?? 0) + 1;

  List<LocalAsset> apply(List<LocalAsset> assets, {DateTime? now}) {
    final out = <LocalAsset>[];
    for (final a in assets) {
      final reason = filter.evaluate(inputFor(a), now: now);
      if (reason == null) {
        out.add(a);
      } else {
        _count(reason);
      }
    }
    return out;
  }

  /// Second pass once the platform entity is known (iOS screenshot subtype / Android path).
  /// Returns the reason when the asset must not be uploaded.
  BackupSkipReason? checkEntity(LocalAsset asset, {int? iosSubtype, String? relativePath}) {
    if (!profile.skipScreenshots && !profile.skipMessagingApps) {
      return null;
    }
    if (isAlwaysBackup(asset)) {
      return null;
    }
    final input = inputFor(
      asset,
      relativePath: relativePath,
      isScreenshotSubtype: iosSubtype == null ? null : (iosSubtype & 4) != 0,
    );
    BackupSkipReason? reason;
    if (profile.skipScreenshots && BackupFilter.looksLikeScreenshot(input)) {
      reason = BackupSkipReason.screenshot;
    } else if (profile.skipMessagingApps && BackupFilter.looksLikeMessagingApp(input)) {
      reason = BackupSkipReason.messagingApp;
    }
    if (reason != null) {
      _count(reason);
    }
    return reason;
  }

  /// Size rule for the upload unit; counts skips/deferrals.
  BackupSizeDecision checkSize(LocalAsset asset, int totalBytes) {
    final d = filter.evaluateSize(totalBytes, onLan: onLan, alwaysBackup: isAlwaysBackup(asset));
    if (d == BackupSizeDecision.skipTooLarge) {
      _count(BackupSkipReason.tooLarge);
    }
    if (d == BackupSizeDecision.deferUntilLan) {
      _count(BackupSkipReason.largeFileNeedsLan);
    }
    return d;
  }

  bool get uploadLivePhotoMotion => filter.uploadLivePhotoMotion;

  int get skippedTotal => skipped.values.fold(0, (a, b) => a + b);

  /// Charging / battery gate for automatic backups. The upstream "require charging" setting is
  /// honoured as well (it is otherwise only an OS scheduling constraint). Unknown values never block.
  static Future<bool> powerAllows(
    ConnectivityApi api,
    BackupFilterProfile profile, {
    bool? upstreamRequireCharging,
  }) async {
    final requireCharging =
        profile.requireCharging ||
        (upstreamRequireCharging ?? SettingsRepository.instance.appConfig.backup.requireCharging);
    if (!requireCharging && !profile.batteryCheckEnabled) {
      return true;
    }
    try {
      final status = await api.getBatteryStatus();
      return BackupFilter(
        profile.patch({'requireCharging': requireCharging}),
      ).powerAllows(batteryLevel: status.level < 0 ? null : status.level, isCharging: status.isCharging);
    } catch (_) {
      return true;
    }
  }
}
