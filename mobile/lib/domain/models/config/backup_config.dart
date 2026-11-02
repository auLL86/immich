import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

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
  }) = _BackupConfig;

  int? get maxFileSizeBytes => maxFileSizeMb > 0 ? maxFileSizeMb * 1000 * 1000 : null;
}
