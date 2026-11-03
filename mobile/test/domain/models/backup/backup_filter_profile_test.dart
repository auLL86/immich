import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/backup/backup_filter_profile.model.dart';
import 'package:immich_mobile/services/backup_filter_sync.service.dart';

void main() {
  group('BackupFilterProfile', () {
    test('defaults are all off except the 100 MB cap', () {
      const p = BackupFilterProfile.defaults;
      expect(p.maxFileSizeMb, 100);
      expect(p.maxFileSizeBytes, 100000000);
      expect(p.startDate, isNull);
      expect(p.endDate, isNull);
      expect(p.mediaType, BackupMediaTypeFilter.all);
      expect(p.largeFilesLanOnly, isFalse);
      expect(p.skipScreenshots || p.favoritesOnly || p.skipMessagingApps, isFalse);
      expect(p.requireCharging || p.batteryCheckEnabled || p.delayRecentVideos, isFalse);
      expect(p.minBatteryPercent, 30);
      expect(p.delayRecentVideosMinutes, 60);
      expect(p.livePhotoMode, LivePhotoMode.full);
    });

    test('json round trip', () {
      final p = BackupFilterProfile(
        startDate: DateTime(2026, 11, 3),
        endDate: DateTime(2026, 12, 31),
        mediaType: BackupMediaTypeFilter.videos,
        maxFileSizeMb: 0,
        largeFilesLanOnly: true,
        alwaysBackupAlbums: const ['Keluarga'],
        livePhotoMode: LivePhotoMode.still,
      );
      final json = jsonDecode(jsonEncode(p.toJson())) as Map<String, Object?>;
      expect(json['startDate'], '2026-11-03');
      expect(json['endDate'], '2026-12-31');
      expect(BackupFilterProfile.fromJson(json), p);
      expect(p.maxFileSizeBytes, isNull, reason: '0 = unlimited');
    });

    test('invalid or unknown values fall back to the base', () {
      final p = BackupFilterProfile.fromJson({
        'mediaType': 'gifs',
        'maxFileSizeMb': 'big',
        'minBatteryPercent': 250,
        'livePhotoMode': 7,
        'skipScreenshots': 'yes',
        'unknownKey': true,
        'startDate': '2026-11-03T10:00:00Z',
      });
      expect(p.mediaType, BackupMediaTypeFilter.all);
      expect(p.maxFileSizeMb, 100);
      expect(p.minBatteryPercent, 100);
      expect(p.livePhotoMode, LivePhotoMode.full);
      expect(p.skipScreenshots, isFalse);
      expect(p.startDate, DateTime(2026, 11, 3));
    });

    test('patch replaces only given keys and null clears dates', () {
      final p = BackupFilterProfile(startDate: DateTime(2026, 1, 1), maxFileSizeMb: 5);
      final q = p.patch({'favoritesOnly': true});
      expect(q.startDate, DateTime(2026, 1, 1));
      expect(q.maxFileSizeMb, 5);
      expect(q.favoritesOnly, isTrue);
      expect(p.patch({'startDate': null}).startDate, isNull);
    });

    test('album keys are trimmed and case-insensitive', () {
      expect(const BackupFilterProfile(alwaysBackupAlbums: [' Keluarga ', 'WORK']).alwaysBackupAlbumKeys, {
        'keluarga',
        'work',
      });
    });
  });

  group('BackupFilterDocument', () {
    final server = {
      'version': 4,
      'updatedAt': '2026-11-03T03:00:00Z',
      'profile': {'maxFileSizeMb': 0, 'requireCharging': false, 'skipScreenshots': true},
      'devices': {
        'phone-1': {
          'name': 'Pixel',
          'overrides': {'requireCharging': true, 'minBatteryPercent': 50},
        },
      },
    };

    test('parses server json and applies per-device overrides', () {
      final doc = BackupFilterDocument.fromServerJson(server);
      expect(doc.version, 4);
      expect(doc.profile.skipScreenshots, isTrue);
      expect(doc.effectiveFor(null).requireCharging, isFalse);
      expect(doc.effectiveFor('other').requireCharging, isFalse);
      final mine = doc.effectiveFor('phone-1');
      expect(mine.requireCharging, isTrue);
      expect(mine.minBatteryPercent, 50);
      expect(mine.skipScreenshots, isTrue);
    });

    test('cache encode/decode keeps dirty state', () {
      final doc = BackupFilterDocument.fromServerJson(server).copyWith(
        dirty: true,
        dirtyKeys: {'favoritesOnly'},
        profile: BackupFilterProfile.defaults.patch({'favoritesOnly': true}),
      );
      final back = BackupFilterDocument.decode(doc.encode());
      expect(back.version, 4);
      expect(back.dirty, isTrue);
      expect(back.dirtyKeys, {'favoritesOnly'});
      expect(back.profile.favoritesOnly, isTrue);
      expect(back.deviceOverrides['phone-1']?['minBatteryPercent'], 50);
    });

    test('missing or corrupt cache falls back to the legacy max size', () {
      expect(BackupFilterDocument.decode(null, legacyMaxFileSizeMb: 250).profile.maxFileSizeMb, 250);
      expect(BackupFilterDocument.decode('{oops', legacyMaxFileSizeMb: 0).profile.maxFileSizeMb, 0);
      expect(BackupFilterDocument.decode('').version, 0);
    });
  });

  group('backupFilterBaseUrls', () {
    test('public endpoint uses the same origin only', () {
      expect(backupFilterBaseUrls('https://foto.sitrbatam.com/api'), [
        Uri.parse('https://foto.sitrbatam.com/immich-filters'),
      ]);
    });
    test('LAN/Tailscale endpoint also tries the direct port', () {
      expect(backupFilterBaseUrls('http://192.168.1.5:2283/api'), [
        Uri.parse('http://192.168.1.5:2283/immich-filters'),
        Uri.parse('http://192.168.1.5:2284/immich-filters'),
      ]);
      expect(backupFilterBaseUrls('http://100.70.1.2:2283/api').length, 2);
    });
    test('no endpoint', () {
      expect(backupFilterBaseUrls(null), isEmpty);
      expect(backupFilterBaseUrls(''), isEmpty);
    });
  });
}
