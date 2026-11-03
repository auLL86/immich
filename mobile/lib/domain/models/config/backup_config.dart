import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:immich_mobile/domain/models/backup/backup_filter_profile.model.dart';

part 'backup_config.freezed.dart';

@freezed
abstract class BackupConfig with _$BackupConfig {
  const BackupConfig._();

  const factory BackupConfig({
    @Default(false) bool enabled,
    @Default(false) bool useCellularForVideos,
    @Default(false) bool useCellularForPhotos,
    @Default(false) bool requireCharging,
    @Default(30) int triggerDelay,
    @Default(false) bool syncAlbums,
    @Default(100) int maxFileSizeMb,
    @Default(true) bool filterSyncEnabled,
    String? filterProfile,
  }) = _BackupConfig;

  int? get maxFileSizeBytes => maxFileSizeMb > 0 ? maxFileSizeMb * 1000 * 1000 : null;

  /// Locally cached shared filter document (see `BackupFilterDocument`). Falls back to the legacy
  /// [maxFileSizeMb] setting until the first sync.
  BackupFilterDocument get filterDocument => _decodeFilterDocument(filterProfile, maxFileSizeMb);
}

String? _lastFilterJson;
int _lastLegacyMb = -1;
BackupFilterDocument? _lastFilterDoc;

BackupFilterDocument _decodeFilterDocument(String? json, int legacyMb) {
  final cached = _lastFilterDoc;
  if (cached != null && json == _lastFilterJson && legacyMb == _lastLegacyMb) {
    return cached;
  }
  _lastFilterJson = json;
  _lastLegacyMb = legacyMb;
  return _lastFilterDoc = BackupFilterDocument.decode(json, legacyMaxFileSizeMb: legacyMb);
}
