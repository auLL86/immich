import 'package:immich_mobile/domain/models/backup/backup_filter_profile.model.dart';

/// Why the automatic backup did not upload an asset (yet).
enum BackupSkipReason {
  mediaType,
  dateRange,
  notInSelectedAlbums,
  notFavorite,
  screenshot,
  messagingApp,
  tooLarge,

  /// Deferred, not rejected: retried on the next run.
  recentVideo,

  /// Deferred, not rejected: uploaded once the active server URL is LAN/Tailscale.
  largeFileNeedsLan;

  bool get isDeferred => this == recentVideo || this == largeFileNeedsLan;
}

/// Metadata of one local asset that the cheap (DB-only) filters need.
class BackupFilterInput {
  final bool isVideo;
  final bool isImage;
  final DateTime createdAt;
  final bool isFavorite;
  final String fileName;

  /// Names of every local album/folder the asset is in (Android: bucket/folder names).
  final Iterable<String> albumNames;

  /// Android relative path (e.g. `Pictures/Screenshots/`), if known.
  final String? relativePath;

  /// iOS: PHAssetMediaSubtype.photoScreenshot, if known (needs the platform entity).
  final bool? isScreenshotSubtype;

  const BackupFilterInput({
    required this.isVideo,
    required this.isImage,
    required this.createdAt,
    this.isFavorite = false,
    this.fileName = '',
    this.albumNames = const [],
    this.relativePath,
    this.isScreenshotSubtype,
  });
}

enum BackupSizeDecision { upload, skipTooLarge, deferUntilLan }

/// Pure filter logic shared by the foreground backup, the Android worker and the iOS URLSession
/// backup. Manual uploads never go through this class.
class BackupFilter {
  final BackupFilterProfile profile;
  final Set<String> _always;

  BackupFilter(this.profile) : _always = profile.alwaysBackupAlbumKeys;

  static final _screenshotAlbum = RegExp(
    r'^(screenshots?|screen ?recordings?|screen ?records?|tangkapan layar|rekaman layar|screencasts?)$',
    caseSensitive: false,
  );
  static final _screenshotPath = RegExp(
    r'(^|/)(screenshots?|screen ?recordings?|screenrecorder|screen_recordings?|screencasts?)(/|$)',
    caseSensitive: false,
  );
  static final _screenshotFile = RegExp(
    r'^(screenshot|screen_recording|screenrecord|screen-recording|screenrecorder|scr_)[-_ ]?',
    caseSensitive: false,
  );
  static final _messagingName = RegExp(r'(whatsapp|telegram)', caseSensitive: false);
  static final _whatsappFile = RegExp(r'^(img|vid|aud|ptt|stk)-\d{8}-wa\d{3,}', caseSensitive: false);

  static bool isScreenshotAlbum(String name) => _screenshotAlbum.hasMatch(name.trim());

  static bool isMessagingAppAlbum(String name) => _messagingName.hasMatch(name);

  bool isAlwaysBackup(Iterable<String> albumNames) =>
      _always.isNotEmpty && albumNames.any((n) => _always.contains(BackupFilterProfile.albumKey(n)));

  static bool looksLikeScreenshot(BackupFilterInput a) {
    if (a.isScreenshotSubtype == true) {
      return true;
    }
    if (a.albumNames.any(isScreenshotAlbum)) {
      return true;
    }
    final p = a.relativePath;
    if (p != null && _screenshotPath.hasMatch(p)) {
      return true;
    }
    return _screenshotFile.hasMatch(a.fileName);
  }

  static bool looksLikeMessagingApp(BackupFilterInput a) {
    if (a.albumNames.any(isMessagingAppAlbum)) {
      return true;
    }
    final p = a.relativePath;
    if (p != null && _messagingName.hasMatch(p)) {
      return true;
    }
    return _whatsappFile.hasMatch(a.fileName);
  }

  /// Returns null when the asset passes every metadata filter (or is in an always-backup album),
  /// otherwise the first reason it was filtered out. Always-backup albums bypass type, date,
  /// favorites, screenshot, messaging and album filters but still honour the recent-video delay.
  BackupSkipReason? evaluate(BackupFilterInput a, {DateTime? now}) {
    final always = isAlwaysBackup(a.albumNames);
    if (!always) {
      if (profile.onlySelectedAlbums) {
        return BackupSkipReason.notInSelectedAlbums;
      }
      if (profile.mediaType == BackupMediaTypeFilter.photos && !a.isImage) {
        return BackupSkipReason.mediaType;
      }
      if (profile.mediaType == BackupMediaTypeFilter.videos && !a.isVideo) {
        return BackupSkipReason.mediaType;
      }
      if (!inDateRange(a.createdAt)) {
        return BackupSkipReason.dateRange;
      }
      if (profile.favoritesOnly && !a.isFavorite) {
        return BackupSkipReason.notFavorite;
      }
      if (profile.skipScreenshots && looksLikeScreenshot(a)) {
        return BackupSkipReason.screenshot;
      }
      if (profile.skipMessagingApps && looksLikeMessagingApp(a)) {
        return BackupSkipReason.messagingApp;
      }
    }
    if (isRecentVideo(a, now: now)) {
      return BackupSkipReason.recentVideo;
    }
    return null;
  }

  /// [createdAt] is compared as a local calendar date; [BackupFilterProfile.endDate] is inclusive.
  bool inDateRange(DateTime createdAt) {
    final local = createdAt.toLocal();
    final start = profile.startDate;
    final end = profile.endDate;
    if (start != null && local.isBefore(DateTime(start.year, start.month, start.day))) {
      return false;
    }
    if (end != null && !local.isBefore(DateTime(end.year, end.month, end.day + 1))) {
      return false;
    }
    return true;
  }

  bool isRecentVideo(BackupFilterInput a, {DateTime? now}) {
    if (!profile.delayRecentVideos || !a.isVideo || profile.delayRecentVideosMinutes <= 0) {
      return false;
    }
    final age = (now ?? DateTime.now()).difference(a.createdAt);
    return age < Duration(minutes: profile.delayRecentVideosMinutes);
  }

  /// Size rule for the whole upload unit (Live Photo = still + motion when both are uploaded).
  ///
  /// * LAN-only off: larger than [BackupFilterProfile.maxFileSizeMb] -> skipped (PR #1 behaviour).
  /// * LAN-only on: on a LAN/Tailscale server URL there is no cap; on any other URL anything over
  ///   the smaller of the two non-zero limits is deferred until the next run on LAN.
  /// * Always-backup albums ignore the size cap but are still deferred off-LAN.
  BackupSizeDecision evaluateSize(int totalBytes, {required bool onLan, bool alwaysBackup = false}) {
    final max = profile.maxFileSizeBytes;
    if (profile.largeFilesLanOnly) {
      if (onLan) {
        return BackupSizeDecision.upload;
      }
      final limits = [?max, ?profile.largeFileThresholdBytes];
      if (limits.isEmpty) {
        return BackupSizeDecision.upload;
      }
      final limit = limits.reduce((a, b) => a < b ? a : b);
      return totalBytes > limit ? BackupSizeDecision.deferUntilLan : BackupSizeDecision.upload;
    }
    if (alwaysBackup || max == null) {
      return BackupSizeDecision.upload;
    }
    return totalBytes > max ? BackupSizeDecision.skipTooLarge : BackupSizeDecision.upload;
  }

  /// Battery / charging gate for automatic runs. Unknown values (null) never block.
  bool powerAllows({int? batteryLevel, bool? isCharging}) {
    if (profile.requireCharging && isCharging == false) {
      return false;
    }
    if (profile.batteryCheckEnabled && batteryLevel != null && batteryLevel < profile.minBatteryPercent) {
      return false;
    }
    return true;
  }

  bool get uploadLivePhotoMotion => profile.livePhotoMode == LivePhotoMode.full;
}

/// True for hosts that are on the local network or the Tailscale tailnet: RFC1918 private ranges,
/// CGNAT/Tailscale 100.64.0.0/10, link-local, loopback, `*.ts.net`, `*.local` and bare hostnames.
bool isLanOrTailscaleHost(String host) {
  var h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) {
    h = h.substring(1, h.length - 1);
  }
  if (h.isEmpty) {
    return false;
  }
  if (h == 'localhost' ||
      h.endsWith('.ts.net') ||
      h.endsWith('.local') ||
      h.endsWith('.lan') ||
      h.endsWith('.home.arpa')) {
    return true;
  }
  final parts = h.split('.');
  if (parts.length == 4 && parts.every((p) => int.tryParse(p) != null)) {
    final o = parts.map(int.parse).toList();
    if (o.any((x) => x < 0 || x > 255)) {
      return false;
    }
    if (o[0] == 10 || o[0] == 127) {
      return true;
    }
    if (o[0] == 192 && o[1] == 168) {
      return true;
    }
    if (o[0] == 172 && o[1] >= 16 && o[1] <= 31) {
      return true;
    }
    if (o[0] == 169 && o[1] == 254) {
      return true;
    }
    if (o[0] == 100 && o[1] >= 64 && o[1] <= 127) {
      return true;
    }
    return false;
  }
  if (h.contains(':')) {
    // IPv6: loopback, unique-local fc00::/7, link-local fe80::/10, Tailscale fd7a:115c:a1e0::/48
    return h == '::1' ||
        h.startsWith('fc') ||
        h.startsWith('fd') ||
        h.startsWith('fe8') ||
        h.startsWith('fe9') ||
        h.startsWith('fea') ||
        h.startsWith('feb');
  }
  return !h.contains('.'); // single-label LAN hostname, e.g. "macmini"
}

bool isLanOrTailscaleUrl(String? url) {
  if (url == null || url.isEmpty) {
    return false;
  }
  final uri = Uri.tryParse(url);
  return uri != null && uri.host.isNotEmpty && isLanOrTailscaleHost(uri.host);
}
