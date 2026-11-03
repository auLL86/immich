import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/backup/backup_filter_profile.model.dart';
import 'package:immich_mobile/domain/services/backup_filter.service.dart';

BackupFilterInput _photo({
  DateTime? createdAt,
  bool favorite = false,
  String name = 'IMG_0001.HEIC',
  List<String> albums = const ['Camera'],
  String? path,
  bool? screenshot,
}) => BackupFilterInput(
  isVideo: false,
  isImage: true,
  createdAt: createdAt ?? DateTime(2026, 11, 3, 12),
  isFavorite: favorite,
  fileName: name,
  albumNames: albums,
  relativePath: path,
  isScreenshotSubtype: screenshot,
);

BackupFilterInput _video({DateTime? createdAt, List<String> albums = const ['Camera'], String name = 'IMG_0002.MOV'}) =>
    BackupFilterInput(
      isVideo: true,
      isImage: false,
      createdAt: createdAt ?? DateTime(2026, 11, 3, 12),
      fileName: name,
      albumNames: albums,
    );

const _mb = 1000 * 1000;

void main() {
  group('defaults', () {
    test('default profile lets everything through (PR #1 behaviour)', () {
      final f = BackupFilter(BackupFilterProfile.defaults);
      expect(f.evaluate(_photo()), isNull);
      expect(f.evaluate(_video()), isNull);
      expect(f.evaluate(_photo(name: 'Screenshot_2026.png', albums: ['Screenshots'])), isNull);
      expect(f.evaluate(_photo(albums: ['WhatsApp Images'])), isNull);
      expect(f.uploadLivePhotoMotion, isTrue);
      expect(f.powerAllows(batteryLevel: 1, isCharging: false), isTrue);
    });

    test('default max size is 100 MB and 0 means unlimited', () {
      final f = BackupFilter(BackupFilterProfile.defaults);
      expect(f.evaluateSize(100 * _mb, onLan: false), BackupSizeDecision.upload);
      expect(f.evaluateSize(100 * _mb + 1, onLan: false), BackupSizeDecision.skipTooLarge);
      expect(f.evaluateSize(100 * _mb + 1, onLan: true), BackupSizeDecision.skipTooLarge);
      final unlimited = BackupFilter(const BackupFilterProfile(maxFileSizeMb: 0));
      expect(unlimited.evaluateSize(50000 * _mb, onLan: false), BackupSizeDecision.upload);
    });
  });

  group('media type', () {
    test('photos only', () {
      final f = BackupFilter(const BackupFilterProfile(mediaType: BackupMediaTypeFilter.photos));
      expect(f.evaluate(_photo()), isNull);
      expect(f.evaluate(_video()), BackupSkipReason.mediaType);
    });
    test('videos only', () {
      final f = BackupFilter(const BackupFilterProfile(mediaType: BackupMediaTypeFilter.videos));
      expect(f.evaluate(_photo()), BackupSkipReason.mediaType);
      expect(f.evaluate(_video()), isNull);
    });
  });

  group('date range', () {
    final f = BackupFilter(BackupFilterProfile(startDate: DateTime(2026, 11, 1), endDate: DateTime(2026, 11, 3)));
    test('start date inclusive', () {
      expect(f.evaluate(_photo(createdAt: DateTime(2026, 10, 31, 23, 59))), BackupSkipReason.dateRange);
      expect(f.evaluate(_photo(createdAt: DateTime(2026, 11, 1))), isNull);
    });
    test('end date inclusive for the whole day', () {
      expect(f.evaluate(_photo(createdAt: DateTime(2026, 11, 3, 23, 59, 59))), isNull);
      expect(f.evaluate(_photo(createdAt: DateTime(2026, 11, 4))), BackupSkipReason.dateRange);
    });
    test('open-ended end date', () {
      final g = BackupFilter(BackupFilterProfile(startDate: DateTime(2026, 11, 1)));
      expect(g.evaluate(_photo(createdAt: DateTime(2030))), isNull);
    });
  });

  group('albums', () {
    test('always-backup albums bypass type/date/favorite/screenshot/messaging filters (case-insensitive)', () {
      final f = BackupFilter(
        BackupFilterProfile(
          mediaType: BackupMediaTypeFilter.photos,
          startDate: DateTime(2030),
          favoritesOnly: true,
          skipScreenshots: true,
          skipMessagingApps: true,
          alwaysBackupAlbums: const ['  Keluarga '],
        ),
      );
      expect(f.evaluate(_video(albums: ['keluarga'])), isNull);
      expect(f.evaluate(_photo(albums: ['KELUARGA', 'WhatsApp Images'], name: 'Screenshot_1.png')), isNull);
      expect(f.evaluate(_photo()), BackupSkipReason.dateRange);
    });

    test('only selected albums keeps only always-backup albums', () {
      final f = BackupFilter(const BackupFilterProfile(onlySelectedAlbums: true, alwaysBackupAlbums: ['Work']));
      expect(f.evaluate(_photo(albums: ['Work'])), isNull);
      expect(f.evaluate(_photo(albums: ['Camera'])), BackupSkipReason.notInSelectedAlbums);
    });

    test('always-backup albums ignore the size cap but still wait for LAN', () {
      final f = BackupFilter(const BackupFilterProfile(maxFileSizeMb: 10));
      expect(f.evaluateSize(20 * _mb, onLan: false, alwaysBackup: true), BackupSizeDecision.upload);
      final lan = BackupFilter(const BackupFilterProfile(largeFilesLanOnly: true, largeFileThresholdMb: 10));
      expect(lan.evaluateSize(20 * _mb, onLan: false, alwaysBackup: true), BackupSizeDecision.deferUntilLan);
    });
  });

  group('favorites', () {
    test('favorites only', () {
      final f = BackupFilter(const BackupFilterProfile(favoritesOnly: true));
      expect(f.evaluate(_photo(favorite: true)), isNull);
      expect(f.evaluate(_photo()), BackupSkipReason.notFavorite);
    });
  });

  group('screenshots', () {
    final f = BackupFilter(const BackupFilterProfile(skipScreenshots: true));
    test('iOS subtype', () {
      expect(f.evaluate(_photo(screenshot: true, name: 'IMG_1234.PNG')), BackupSkipReason.screenshot);
      expect(f.evaluate(_photo(screenshot: false)), isNull);
    });
    test('album, Android path and file name', () {
      expect(f.evaluate(_photo(albums: ['Screenshots'])), BackupSkipReason.screenshot);
      expect(f.evaluate(_photo(albums: ['Tangkapan layar'])), BackupSkipReason.screenshot);
      expect(f.evaluate(_photo(path: 'Pictures/Screenshots/')), BackupSkipReason.screenshot);
      expect(f.evaluate(_photo(path: 'Movies/ScreenRecorder/')), BackupSkipReason.screenshot);
      expect(f.evaluate(_photo(name: 'Screenshot_20261103-101010.png', albums: [])), BackupSkipReason.screenshot);
      expect(f.evaluate(_photo(name: 'screen_recording_2026.mp4', albums: [])), BackupSkipReason.screenshot);
    });
    test('normal photos are kept', () {
      expect(f.evaluate(_photo(path: 'DCIM/Camera/')), isNull);
      expect(f.evaluate(_photo(albums: ['My screenshots of art'])), isNull);
    });
  });

  group('messaging apps', () {
    final f = BackupFilter(const BackupFilterProfile(skipMessagingApps: true));
    test('WhatsApp and Telegram detection', () {
      expect(f.evaluate(_photo(albums: ['WhatsApp Images'])), BackupSkipReason.messagingApp);
      expect(f.evaluate(_photo(albums: ['Telegram'])), BackupSkipReason.messagingApp);
      expect(
        f.evaluate(_photo(path: 'Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video/')),
        BackupSkipReason.messagingApp,
      );
      expect(f.evaluate(_photo(path: 'Pictures/Telegram/')), BackupSkipReason.messagingApp);
      expect(f.evaluate(_photo(name: 'IMG-20261103-WA0007.jpg', albums: [])), BackupSkipReason.messagingApp);
      expect(f.evaluate(_photo()), isNull);
    });
  });

  group('large files only via LAN/Tailscale', () {
    final f = BackupFilter(
      const BackupFilterProfile(maxFileSizeMb: 0, largeFilesLanOnly: true, largeFileThresholdMb: 100),
    );
    test('deferred (not rejected) off-LAN, uploaded on LAN', () {
      expect(f.evaluateSize(150 * _mb, onLan: false), BackupSizeDecision.deferUntilLan);
      expect(f.evaluateSize(150 * _mb, onLan: true), BackupSizeDecision.upload);
      expect(f.evaluateSize(50 * _mb, onLan: false), BackupSizeDecision.upload);
      expect(BackupSkipReason.largeFileNeedsLan.isDeferred, isTrue);
      expect(BackupSkipReason.tooLarge.isDeferred, isFalse);
    });
    test('uses the smaller non-zero limit off-LAN', () {
      final g = BackupFilter(
        const BackupFilterProfile(maxFileSizeMb: 50, largeFilesLanOnly: true, largeFileThresholdMb: 100),
      );
      expect(g.evaluateSize(60 * _mb, onLan: false), BackupSizeDecision.deferUntilLan);
      expect(g.evaluateSize(60 * _mb, onLan: true), BackupSizeDecision.upload);
    });
  });

  group('LAN / Tailscale host detection', () {
    test('private, CGNAT, ts.net and local names', () {
      for (final h in [
        '192.168.1.10',
        '10.0.0.5',
        '172.16.0.1',
        '172.31.255.255',
        '100.64.0.1',
        '100.127.1.1',
        'macmini.tail1234.ts.net',
        'macmini.local',
        'localhost',
        'macmini',
        '127.0.0.1',
        '[fd7a:115c:a1e0::1]',
      ]) {
        expect(isLanOrTailscaleHost(h), isTrue, reason: h);
      }
    });
    test('public hosts', () {
      for (final h in ['foto.sitrbatam.com', '8.8.8.8', '172.32.0.1', '100.128.0.1', '100.63.255.255', '']) {
        expect(isLanOrTailscaleHost(h), isFalse, reason: h);
      }
    });
    test('urls', () {
      expect(isLanOrTailscaleUrl('https://foto.sitrbatam.com/api'), isFalse);
      expect(isLanOrTailscaleUrl('http://192.168.1.2:2283/api'), isTrue);
      expect(isLanOrTailscaleUrl('http://100.101.102.103:2283/api'), isTrue);
      expect(isLanOrTailscaleUrl(null), isFalse);
      expect(isLanOrTailscaleUrl('not a url'), isFalse);
    });
  });

  group('charging / battery', () {
    test('charging requirement', () {
      final f = BackupFilter(const BackupFilterProfile(requireCharging: true));
      expect(f.powerAllows(isCharging: false, batteryLevel: 90), isFalse);
      expect(f.powerAllows(isCharging: true, batteryLevel: 5), isTrue);
      expect(f.powerAllows(), isTrue, reason: 'unknown never blocks');
    });
    test('battery threshold default 30%', () {
      final f = BackupFilter(const BackupFilterProfile(batteryCheckEnabled: true));
      expect(f.profile.minBatteryPercent, 30);
      expect(f.powerAllows(batteryLevel: 29, isCharging: true), isFalse);
      expect(f.powerAllows(batteryLevel: 30, isCharging: false), isTrue);
      expect(f.powerAllows(isCharging: false), isTrue);
    });
  });

  group('recent videos', () {
    final now = DateTime(2026, 11, 3, 12);
    test('delays videos younger than the configured minutes', () {
      final f = BackupFilter(const BackupFilterProfile(delayRecentVideos: true));
      expect(
        f.evaluate(_video(createdAt: now.subtract(const Duration(minutes: 59))), now: now),
        BackupSkipReason.recentVideo,
      );
      expect(f.evaluate(_video(createdAt: now.subtract(const Duration(minutes: 61))), now: now), isNull);
      expect(f.evaluate(_photo(createdAt: now), now: now), isNull);
      expect(BackupSkipReason.recentVideo.isDeferred, isTrue);
    });
    test('off by default', () {
      final f = BackupFilter(BackupFilterProfile.defaults);
      expect(f.evaluate(_video(createdAt: now), now: now), isNull);
    });
    test('applies even in always-backup albums', () {
      final f = BackupFilter(const BackupFilterProfile(delayRecentVideos: true, alwaysBackupAlbums: ['A']));
      expect(
        f.evaluate(
          _video(createdAt: now, albums: ['A']),
          now: now,
        ),
        BackupSkipReason.recentVideo,
      );
    });
  });

  group('live photos', () {
    test('still only', () {
      expect(
        BackupFilter(const BackupFilterProfile(livePhotoMode: LivePhotoMode.still)).uploadLivePhotoMotion,
        isFalse,
      );
    });
  });
}
