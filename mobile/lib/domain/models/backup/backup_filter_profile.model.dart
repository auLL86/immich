import 'dart:convert';

/// Which media types the automatic backup / importers pick up.
enum BackupMediaTypeFilter {
  all,
  photos,
  videos;

  static BackupMediaTypeFilter parse(Object? v) =>
      BackupMediaTypeFilter.values.firstWhere((e) => e.name == v, orElse: () => BackupMediaTypeFilter.all);
}

/// How Live Photos are uploaded by the automatic backup.
enum LivePhotoMode {
  /// Still photo + motion video (upstream behaviour).
  full,

  /// Still photo only; the motion part is not uploaded.
  still;

  static LivePhotoMode parse(Object? v) =>
      LivePhotoMode.values.firstWhere((e) => e.name == v, orElse: () => LivePhotoMode.full);
}

/// Shared backup/import filter profile (schemaVersion 1).
///
/// The same JSON document is used by the mobile app, the Mac USB importer and the Windows app and
/// is stored by the `immich-filters` service next to the Immich server. All filters default to
/// "off" so a default profile does not change upstream behaviour, except [maxFileSizeMb] = 100.
/// Sizes are megabytes of 1,000,000 bytes, dates are local calendar dates (end inclusive) and
/// album names are compared case-insensitively.
class BackupFilterProfile {
  final DateTime? startDate;
  final DateTime? endDate;
  final BackupMediaTypeFilter mediaType;
  final int maxFileSizeMb;
  final bool largeFilesLanOnly;
  final int largeFileThresholdMb;
  final bool onlySelectedAlbums;
  final List<String> alwaysBackupAlbums;
  final bool skipScreenshots;
  final bool favoritesOnly;
  final bool skipMessagingApps;
  final bool requireCharging;
  final bool batteryCheckEnabled;
  final int minBatteryPercent;
  final bool delayRecentVideos;
  final int delayRecentVideosMinutes;
  final LivePhotoMode livePhotoMode;

  const BackupFilterProfile({
    this.startDate,
    this.endDate,
    this.mediaType = BackupMediaTypeFilter.all,
    this.maxFileSizeMb = 100,
    this.largeFilesLanOnly = false,
    this.largeFileThresholdMb = 100,
    this.onlySelectedAlbums = false,
    this.alwaysBackupAlbums = const [],
    this.skipScreenshots = false,
    this.favoritesOnly = false,
    this.skipMessagingApps = false,
    this.requireCharging = false,
    this.batteryCheckEnabled = false,
    this.minBatteryPercent = 30,
    this.delayRecentVideos = false,
    this.delayRecentVideosMinutes = 60,
    this.livePhotoMode = LivePhotoMode.full,
  });

  static const defaults = BackupFilterProfile();

  bool get hasDateRange => startDate != null || endDate != null;

  int? get maxFileSizeBytes => maxFileSizeMb > 0 ? maxFileSizeMb * 1000 * 1000 : null;

  int? get largeFileThresholdBytes => largeFileThresholdMb > 0 ? largeFileThresholdMb * 1000 * 1000 : null;

  Set<String> get alwaysBackupAlbumKeys => alwaysBackupAlbums.map(albumKey).toSet();

  static String albumKey(String name) => name.trim().toLowerCase();

  static DateTime? _date(Object? v) {
    if (v is! String || v.isEmpty) {
      return null;
    }
    final d = DateTime.tryParse(v.length >= 10 ? v.substring(0, 10) : v);
    return d == null ? null : DateTime(d.year, d.month, d.day);
  }

  static String? _dateString(DateTime? d) => d == null
      ? null
      : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static int _int(Object? v, int fallback, {int min = 0, int? max}) {
    if (v is! num) {
      return fallback;
    }
    var i = v.round();
    if (i < min) {
      i = min;
    }
    if (max != null && i > max) {
      i = max;
    }
    return i;
  }

  static bool _bool(Object? v, bool fallback) => v is bool ? v : fallback;

  /// Parses [json] onto [base] (defaults when omitted). Unknown keys are ignored, invalid values
  /// keep the base value so a newer/older server never breaks the backup.
  factory BackupFilterProfile.fromJson(Map<String, Object?> json, {BackupFilterProfile base = defaults}) {
    return BackupFilterProfile(
      startDate: json.containsKey('startDate') ? _date(json['startDate']) : base.startDate,
      endDate: json.containsKey('endDate') ? _date(json['endDate']) : base.endDate,
      mediaType: json.containsKey('mediaType') ? BackupMediaTypeFilter.parse(json['mediaType']) : base.mediaType,
      maxFileSizeMb: _int(json['maxFileSizeMb'], base.maxFileSizeMb),
      largeFilesLanOnly: _bool(json['largeFilesLanOnly'], base.largeFilesLanOnly),
      largeFileThresholdMb: _int(json['largeFileThresholdMb'], base.largeFileThresholdMb),
      onlySelectedAlbums: _bool(json['onlySelectedAlbums'], base.onlySelectedAlbums),
      alwaysBackupAlbums: json['alwaysBackupAlbums'] is List
          ? (json['alwaysBackupAlbums']! as List).whereType<String>().toList(growable: false)
          : base.alwaysBackupAlbums,
      skipScreenshots: _bool(json['skipScreenshots'], base.skipScreenshots),
      favoritesOnly: _bool(json['favoritesOnly'], base.favoritesOnly),
      skipMessagingApps: _bool(json['skipMessagingApps'], base.skipMessagingApps),
      requireCharging: _bool(json['requireCharging'], base.requireCharging),
      batteryCheckEnabled: _bool(json['batteryCheckEnabled'], base.batteryCheckEnabled),
      minBatteryPercent: _int(json['minBatteryPercent'], base.minBatteryPercent, max: 100),
      delayRecentVideos: _bool(json['delayRecentVideos'], base.delayRecentVideos),
      delayRecentVideosMinutes: _int(json['delayRecentVideosMinutes'], base.delayRecentVideosMinutes),
      livePhotoMode: json.containsKey('livePhotoMode')
          ? LivePhotoMode.parse(json['livePhotoMode'])
          : base.livePhotoMode,
    );
  }

  Map<String, Object?> toJson() => {
    'startDate': _dateString(startDate),
    'endDate': _dateString(endDate),
    'mediaType': mediaType.name,
    'maxFileSizeMb': maxFileSizeMb,
    'largeFilesLanOnly': largeFilesLanOnly,
    'largeFileThresholdMb': largeFileThresholdMb,
    'onlySelectedAlbums': onlySelectedAlbums,
    'alwaysBackupAlbums': alwaysBackupAlbums,
    'skipScreenshots': skipScreenshots,
    'favoritesOnly': favoritesOnly,
    'skipMessagingApps': skipMessagingApps,
    'requireCharging': requireCharging,
    'batteryCheckEnabled': batteryCheckEnabled,
    'minBatteryPercent': minBatteryPercent,
    'delayRecentVideos': delayRecentVideos,
    'delayRecentVideosMinutes': delayRecentVideosMinutes,
    'livePhotoMode': livePhotoMode.name,
  };

  /// Returns a copy with the given JSON fields replaced (same keys as [toJson]).
  BackupFilterProfile patch(Map<String, Object?> changes) => BackupFilterProfile.fromJson(changes, base: this);

  @override
  bool operator ==(Object other) => other is BackupFilterProfile && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;

  @override
  String toString() => 'BackupFilterProfile(${jsonEncode(toJson())})';
}

/// Locally cached copy of the server document (`GET /immich-filters/v1/profile`).
class BackupFilterDocument {
  final int version;
  final String? updatedAt;
  final BackupFilterProfile profile;

  /// Per-device overrides keyed by device id (only the overridden keys).
  final Map<String, Map<String, Object?>> deviceOverrides;

  /// True when the local copy was edited and still has to be pushed to the server.
  final bool dirty;

  /// Keys edited locally since the last successful push (merged onto the server copy on push).
  final Set<String> dirtyKeys;

  const BackupFilterDocument({
    this.version = 0,
    this.updatedAt,
    this.profile = BackupFilterProfile.defaults,
    this.deviceOverrides = const {},
    this.dirty = false,
    this.dirtyKeys = const {},
  });

  BackupFilterProfile effectiveFor(String? deviceId) {
    final o = deviceId == null ? null : deviceOverrides[deviceId];
    return o == null || o.isEmpty ? profile : profile.patch(o);
  }

  factory BackupFilterDocument.fromServerJson(Map<String, Object?> json) {
    final devices = <String, Map<String, Object?>>{};
    final raw = json['devices'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final v = e.value;
        if (v is Map && v['overrides'] is Map) {
          devices[e.key.toString()] = Map<String, Object?>.from(v['overrides'] as Map);
        }
      }
    }
    return BackupFilterDocument(
      version: json['version'] is num ? (json['version']! as num).toInt() : 0,
      updatedAt: json['updatedAt'] as String?,
      profile: json['profile'] is Map
          ? BackupFilterProfile.fromJson(Map<String, Object?>.from(json['profile']! as Map))
          : BackupFilterProfile.defaults,
      deviceOverrides: devices,
    );
  }

  Map<String, Object?> toCacheJson() => {
    'version': version,
    'updatedAt': updatedAt,
    'profile': profile.toJson(),
    'devices': {
      for (final e in deviceOverrides.entries) e.key: {'overrides': e.value},
    },
    'dirty': dirty,
    'dirtyKeys': dirtyKeys.toList(),
  };

  factory BackupFilterDocument.fromCacheJson(Map<String, Object?> json) {
    final doc = BackupFilterDocument.fromServerJson(json);
    return BackupFilterDocument(
      version: doc.version,
      updatedAt: doc.updatedAt,
      profile: doc.profile,
      deviceOverrides: doc.deviceOverrides,
      dirty: json['dirty'] == true,
      dirtyKeys: json['dirtyKeys'] is List ? (json['dirtyKeys']! as List).whereType<String>().toSet() : const {},
    );
  }

  static BackupFilterDocument decode(String? cached, {int legacyMaxFileSizeMb = 100}) {
    if (cached == null || cached.isEmpty) {
      return BackupFilterDocument(profile: BackupFilterProfile(maxFileSizeMb: legacyMaxFileSizeMb));
    }
    try {
      return BackupFilterDocument.fromCacheJson(Map<String, Object?>.from(jsonDecode(cached) as Map));
    } catch (_) {
      return BackupFilterDocument(profile: BackupFilterProfile(maxFileSizeMb: legacyMaxFileSizeMb));
    }
  }

  String encode() => jsonEncode(toCacheJson());

  BackupFilterDocument copyWith({
    int? version,
    String? updatedAt,
    BackupFilterProfile? profile,
    Map<String, Map<String, Object?>>? deviceOverrides,
    bool? dirty,
    Set<String>? dirtyKeys,
  }) => BackupFilterDocument(
    version: version ?? this.version,
    updatedAt: updatedAt ?? this.updatedAt,
    profile: profile ?? this.profile,
    deviceOverrides: deviceOverrides ?? this.deviceOverrides,
    dirty: dirty ?? this.dirty,
    dirtyKeys: dirtyKeys ?? this.dirtyKeys,
  );
}
