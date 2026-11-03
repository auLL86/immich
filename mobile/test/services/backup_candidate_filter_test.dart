import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/backup/backup_filter_profile.model.dart';
import 'package:immich_mobile/domain/services/backup_filter.service.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/services/backup_candidate_filter.dart';
import 'package:mocktail/mocktail.dart';

class _MockConnectivityApi extends Mock implements ConnectivityApi {}

LocalAsset _asset(
  String id, {
  AssetType type = AssetType.image,
  String name = 'IMG_0001.JPG',
  bool favorite = false,
  DateTime? createdAt,
}) => LocalAsset(
  id: id,
  name: name,
  type: type,
  createdAt: createdAt ?? DateTime(2026, 11, 3, 10),
  updatedAt: DateTime(2026, 11, 3, 10),
  isFavorite: favorite,
  playbackStyle: type == AssetType.video ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
  isEdited: false,
);

void main() {
  group('apply', () {
    test('counts skipped reasons and keeps passing assets', () {
      final f = BackupCandidateFilter(
        const BackupFilterProfile(mediaType: BackupMediaTypeFilter.photos, skipMessagingApps: true),
        onLan: false,
        albumNames: {
          'wa': {'WhatsApp Images'},
          'cam': {'Camera'},
        },
      );
      final out = f.apply([_asset('cam'), _asset('wa'), _asset('vid', type: AssetType.video)]);
      expect(out.map((a) => a.id), ['cam']);
      expect(f.skipped, {BackupSkipReason.messagingApp: 1, BackupSkipReason.mediaType: 1});
      expect(f.skippedTotal, 2);
    });

    test('default profile filters nothing', () {
      final f = BackupCandidateFilter(BackupFilterProfile.defaults, onLan: false);
      final assets = [_asset('a'), _asset('b', type: AssetType.video, name: 'Screenshot.mp4')];
      expect(f.apply(assets), assets);
      expect(f.skippedTotal, 0);
    });
  });

  group('checkEntity', () {
    test('iOS screenshot subtype is detected at upload time', () {
      final f = BackupCandidateFilter(const BackupFilterProfile(skipScreenshots: true), onLan: false);
      expect(f.checkEntity(_asset('a'), iosSubtype: 4), BackupSkipReason.screenshot);
      expect(f.checkEntity(_asset('b'), iosSubtype: 0), isNull);
      expect(f.checkEntity(_asset('c'), relativePath: 'Pictures/Screenshots/'), BackupSkipReason.screenshot);
      expect(f.skipped[BackupSkipReason.screenshot], 2);
    });
    test('always-backup albums are not filtered at upload time', () {
      final f = BackupCandidateFilter(
        const BackupFilterProfile(skipScreenshots: true, alwaysBackupAlbums: ['Keep']),
        onLan: false,
        albumNames: {
          'a': {'Keep'},
        },
      );
      expect(f.checkEntity(_asset('a'), iosSubtype: 4), isNull);
    });
    test('no-op when screenshot/messaging filters are off', () {
      final f = BackupCandidateFilter(BackupFilterProfile.defaults, onLan: false);
      expect(f.checkEntity(_asset('a'), iosSubtype: 4), isNull);
    });
  });

  group('checkSize', () {
    test('defers large files off-LAN and counts them', () {
      final f = BackupCandidateFilter(
        const BackupFilterProfile(maxFileSizeMb: 0, largeFilesLanOnly: true, largeFileThresholdMb: 100),
        onLan: false,
      );
      expect(f.checkSize(_asset('a'), 200000000), BackupSizeDecision.deferUntilLan);
      expect(f.checkSize(_asset('b'), 1000), BackupSizeDecision.upload);
      expect(f.skipped, {BackupSkipReason.largeFileNeedsLan: 1});
    });
    test('uploads large files on LAN', () {
      final f = BackupCandidateFilter(const BackupFilterProfile(largeFilesLanOnly: true), onLan: true);
      expect(f.checkSize(_asset('a'), 900000000), BackupSizeDecision.upload);
    });
    test('PR #1 cap rejects', () {
      final f = BackupCandidateFilter(BackupFilterProfile.defaults, onLan: true);
      expect(f.checkSize(_asset('a'), 100000001), BackupSizeDecision.skipTooLarge);
      expect(f.skipped, {BackupSkipReason.tooLarge: 1});
    });
  });

  group('powerAllows', () {
    late _MockConnectivityApi api;
    setUp(() => api = _MockConnectivityApi());

    test('does not query the battery when nothing is required', () async {
      expect(
        await BackupCandidateFilter.powerAllows(api, BackupFilterProfile.defaults, upstreamRequireCharging: false),
        isTrue,
      );
      verifyNever(() => api.getBatteryStatus());
    });
    test('upstream require charging is honoured', () async {
      when(() => api.getBatteryStatus()).thenAnswer((_) async => BatteryStatus(level: 80, isCharging: false));
      expect(
        await BackupCandidateFilter.powerAllows(api, BackupFilterProfile.defaults, upstreamRequireCharging: true),
        isFalse,
      );
    });
    test('battery threshold', () async {
      when(() => api.getBatteryStatus()).thenAnswer((_) async => BatteryStatus(level: 20, isCharging: true));
      const p = BackupFilterProfile(batteryCheckEnabled: true);
      expect(await BackupCandidateFilter.powerAllows(api, p, upstreamRequireCharging: false), isFalse);
    });
    test('unknown level or errors never block', () async {
      when(() => api.getBatteryStatus()).thenAnswer((_) async => BatteryStatus(level: -1, isCharging: false));
      const p = BackupFilterProfile(batteryCheckEnabled: true);
      expect(await BackupCandidateFilter.powerAllows(api, p, upstreamRequireCharging: false), isTrue);
      when(() => api.getBatteryStatus()).thenThrow(Exception('no battery'));
      expect(
        await BackupCandidateFilter.powerAllows(
          api,
          p.patch({'requireCharging': true}),
          upstreamRequireCharging: false,
        ),
        isTrue,
      );
    });
  });
}
