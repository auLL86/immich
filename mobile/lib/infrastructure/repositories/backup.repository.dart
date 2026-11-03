import 'dart:async';

import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/album_asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.drift.dart';

@DriftAccessor()
class BackupRepository extends DatabaseAccessor<Drift> with $BackupRepositoryMixin {
  BackupRepository(super.attachedDatabase);

  Drift get _db => attachedDatabase;

  JoinedSelectStatement<$LocalAlbumAssetEntityTable, LocalAlbumAssetEntityData> _getExcludedSubquery() {
    return _db.localAlbumAssetEntity.selectOnly()
      ..addColumns([_db.localAlbumAssetEntity.assetId])
      ..join([
        innerJoin(
          _db.localAlbumEntity,
          _db.localAlbumAssetEntity.albumId.equalsExp(_db.localAlbumEntity.id),
          useColumns: false,
        ),
      ])
      ..where(_db.localAlbumEntity.backupSelection.equalsValue(BackupSelection.excluded));
  }

  /// Returns all backup-related counts in a single query.
  ///
  /// - total:     number of distinct assets in selected albums, excluding those that are also in excluded albums
  /// - backup:    number of those assets that already exist on the server for [userId]
  /// - remainder: number of those assets that do not yet exist on the server for [userId]
  ///              (includes processing)
  /// - processing: number of those assets that are still preparing/have a null checksum
  Future<({int total, int remainder, int processing})> getAllCounts(String userId) async {
    const sql = '''
        SELECT
        COUNT(*) AS total_count,
        COUNT(*) FILTER (WHERE lae.checksum IS NULL) AS processing_count,
        COUNT(*) FILTER (WHERE rae.id IS NULL) AS remainder_count
        FROM local_asset_entity lae
        LEFT JOIN main.remote_asset_entity rae
            ON lae.checksum = rae.checksum AND rae.owner_id = ?1
        WHERE EXISTS (
            SELECT 1
            FROM local_album_asset_entity laa
            INNER JOIN main.local_album_entity la on laa.album_id = la.id
            WHERE laa.asset_id = lae.id
                AND la.backup_selection = ?2
        )
        AND NOT EXISTS (
            SELECT 1
            FROM local_album_asset_entity laa
            INNER JOIN main.local_album_entity la on laa.album_id = la.id
            WHERE laa.asset_id = lae.id
                AND la.backup_selection = ?3
        );
      ''';

    final row = await _db
        .customSelect(
          sql,
          variables: [
            Variable.withString(userId),
            Variable.withInt(BackupSelection.selected.index),
            Variable.withInt(BackupSelection.excluded.index),
          ],
          readsFrom: {_db.localAlbumAssetEntity, _db.localAlbumEntity, _db.localAssetEntity, _db.remoteAssetEntity},
        )
        .getSingle();

    final data = row.data;
    return (
      total: (data['total_count'] as int?) ?? 0,
      remainder: (data['remainder_count'] as int?) ?? 0,
      processing: (data['processing_count'] as int?) ?? 0,
    );
  }

  /// Backup candidates: assets in selected albums and not in excluded albums, plus every asset in
  /// an album whose (case-insensitive) name is in [alwaysBackupAlbumNames] - those win over an
  /// excluded album - that are not on the server yet.
  Future<List<LocalAsset>> getCandidates(
    String userId, {
    bool onlyHashed = true,
    Iterable<String> alwaysBackupAlbumNames = const [],
  }) async {
    final selectedAlbumIds = _db.localAlbumEntity.selectOnly(distinct: true)
      ..addColumns([_db.localAlbumEntity.id])
      ..where(_db.localAlbumEntity.backupSelection.equalsValue(BackupSelection.selected));

    final alwaysNames = alwaysBackupAlbumNames.map((n) => n.trim().toLowerCase()).where((n) => n.isNotEmpty).toSet();

    final query = _db.localAssetEntity.select()
      ..where((lae) {
        Expression<bool> inSelection =
            existsQuery(
              _db.localAlbumAssetEntity.selectOnly()
                ..addColumns([_db.localAlbumAssetEntity.assetId])
                ..where(
                  _db.localAlbumAssetEntity.albumId.isInQuery(selectedAlbumIds) &
                      _db.localAlbumAssetEntity.assetId.equalsExp(lae.id),
                ),
            ) &
            lae.id.isNotInQuery(_getExcludedSubquery());
        if (alwaysNames.isNotEmpty) {
          final alwaysAlbumIds = _db.localAlbumEntity.selectOnly(distinct: true)
            ..addColumns([_db.localAlbumEntity.id])
            ..where(_db.localAlbumEntity.name.lower().isIn(alwaysNames));
          inSelection =
              inSelection |
              existsQuery(
                _db.localAlbumAssetEntity.selectOnly()
                  ..addColumns([_db.localAlbumAssetEntity.assetId])
                  ..where(
                    _db.localAlbumAssetEntity.albumId.isInQuery(alwaysAlbumIds) &
                        _db.localAlbumAssetEntity.assetId.equalsExp(lae.id),
                  ),
              );
        }
        return inSelection &
            notExistsQuery(
              _db.remoteAssetEntity.selectOnly()
                ..addColumns([_db.remoteAssetEntity.checksum])
                ..where(
                  _db.remoteAssetEntity.checksum.equalsExp(lae.checksum) & _db.remoteAssetEntity.ownerId.equals(userId),
                ),
            );
      })
      ..orderBy([(localAsset) => OrderingTerm.desc(localAsset.createdAt)]);

    if (onlyHashed) {
      query.where((lae) => lae.checksum.isNotNull());
    }

    return query.map((localAsset) => localAsset.toDto()).get();
  }

  /// Names of the local albums each of [assetIds] belongs to (lower-cased keys are not applied).
  Future<Map<String, Set<String>>> getAlbumNamesForAssets(Iterable<String> assetIds) async {
    final result = <String, Set<String>>{};
    final ids = assetIds.toList(growable: false);
    const chunk = 500;
    for (var i = 0; i < ids.length; i += chunk) {
      final part = ids.sublist(i, i + chunk > ids.length ? ids.length : i + chunk);
      final query = _db.localAlbumAssetEntity.selectOnly()
        ..addColumns([_db.localAlbumAssetEntity.assetId, _db.localAlbumEntity.name])
        ..join([
          innerJoin(
            _db.localAlbumEntity,
            _db.localAlbumAssetEntity.albumId.equalsExp(_db.localAlbumEntity.id),
            useColumns: false,
          ),
        ])
        ..where(_db.localAlbumAssetEntity.assetId.isIn(part));
      for (final row in await query.get()) {
        final id = row.read(_db.localAlbumAssetEntity.assetId);
        final name = row.read(_db.localAlbumEntity.name);
        if (id != null && name != null) {
          (result[id] ??= <String>{}).add(name);
        }
      }
    }
    return result;
  }

  /// Names of all local albums (for the always-backup album picker).
  Future<List<String>> getLocalAlbumNames() async {
    final query = _db.localAlbumEntity.selectOnly(distinct: true)..addColumns([_db.localAlbumEntity.name]);
    final names = (await query.get()).map((r) => r.read(_db.localAlbumEntity.name)).nonNulls.toSet().toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }
}
