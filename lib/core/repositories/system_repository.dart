import 'dart:io';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../models/enums.dart';
import '../services/app_paths.dart';
import '../services/media_storage.dart';
import 'family_repository.dart';

/// Trash / recovery, key-value settings and backup history.
class SystemRepository {
  SystemRepository(this.db, {this.storage = const MediaStorage()});
  final AppDatabase db;
  final MediaStorage storage;

  // ================================================================= trash

  Stream<List<DeletionRecord>> watchTrash() =>
      (db.select(db.deletionRecords)..orderBy([(d) => OrderingTerm.desc(d.deletedAt)])).watch();

  /// Restores a trashed record. Returns false if it no longer exists.
  Future<bool> restore(String recordId) async {
    final r = await (db.select(db.deletionRecords)..where((d) => d.id.equals(recordId))).getSingleOrNull();
    if (r == null) return false;
    await db.transaction(() async {
      switch (r.entityType) {
        case TrashEntity.person:
          await (db.update(db.persons)..where((x) => x.id.equals(r.entityId)))
              .write(const PersonsCompanion(deletedAt: Value(null)));
        case TrashEntity.event:
          await (db.update(db.familyEvents)..where((x) => x.id.equals(r.entityId)))
              .write(const FamilyEventsCompanion(deletedAt: Value(null)));
        case TrashEntity.media:
          await (db.update(db.mediaAssets)..where((x) => x.id.equals(r.entityId)))
              .write(const MediaAssetsCompanion(deletedAt: Value(null)));
        case TrashEntity.story:
          await (db.update(db.stories)..where((x) => x.id.equals(r.entityId)))
              .write(const StoriesCompanion(deletedAt: Value(null)));
        case TrashEntity.source:
          await (db.update(db.sources)..where((x) => x.id.equals(r.entityId)))
              .write(const SourcesCompanion(deletedAt: Value(null)));
        case TrashEntity.album:
          await (db.update(db.albums)..where((x) => x.id.equals(r.entityId)))
              .write(const AlbumsCompanion(deletedAt: Value(null)));
        case TrashEntity.tree:
          await (db.update(db.familyTrees)..where((x) => x.id.equals(r.entityId)))
              .write(const FamilyTreesCompanion(deletedAt: Value(null)));
        case TrashEntity.relationship:
          await _restoreRelationship(r);
      }
      await (db.delete(db.deletionRecords)..where((d) => d.id.equals(recordId))).go();
    });
    return true;
  }

  Future<void> _restoreRelationship(DeletionRecord r) async {
    final payload = r.payload;
    if (payload == null) return;
    final map = jsonDecode(payload) as Map<String, dynamic>;
    final kind = map.remove('kind');
    // Both people must still exist.
    if (kind == 'parentChild') {
      final link = ParentChildLink.fromJson(map);
      final ok = await _peopleExist([link.parentId, link.childId]);
      if (!ok) throw ValidationException('One of the people in this relationship no longer exists.');
      await db.into(db.parentChildLinks).insert(link, mode: InsertMode.insertOrIgnore);
    } else if (kind == 'partnership') {
      final s = Partnership.fromJson(map);
      final ok = await _peopleExist([s.personAId, s.personBId]);
      if (!ok) throw ValidationException('One of the people in this relationship no longer exists.');
      await db.into(db.partnerships).insert(s, mode: InsertMode.insertOrIgnore);
    }
  }

  Future<bool> _peopleExist(List<String> ids) async {
    final rows = await (db.select(db.persons)..where((p) => p.id.isIn(ids))).get();
    return rows.length == ids.toSet().length;
  }

  /// Permanently deletes a trashed record (and its files, for media).
  ///
  /// When a person is purged, photos that were linked ONLY to that person
  /// (not to other people, events, stories or albums) are purged too if
  /// [deleteExclusiveMedia] is true; otherwise they stay in the gallery.
  Future<void> purge(String recordId, {bool deleteExclusiveMedia = false}) async {
    final r = await (db.select(db.deletionRecords)..where((d) => d.id.equals(recordId))).getSingleOrNull();
    if (r == null) return;
    final filesToDelete = <(String?, String?)>[];
    await db.transaction(() async {
      switch (r.entityType) {
        case TrashEntity.person:
          if (deleteExclusiveMedia) {
            for (final m in await exclusiveMediaOf(r.entityId)) {
              filesToDelete.add((m.filePath, m.thumbPath));
              await (db.delete(db.mediaAssets)..where((x) => x.id.equals(m.id))).go();
            }
          }
          await (db.update(db.familyTrees)..where((t) => t.homePersonId.equals(r.entityId)))
              .write(const FamilyTreesCompanion(homePersonId: Value(null)));
          await (db.delete(db.persons)..where((x) => x.id.equals(r.entityId))).go();
          await db.customStatement(
              "DELETE FROM citations WHERE entity_type = 'person' AND entity_id = ?", [r.entityId]);
        case TrashEntity.event:
          await (db.delete(db.familyEvents)..where((x) => x.id.equals(r.entityId))).go();
          await db.customStatement(
              "DELETE FROM citations WHERE entity_type = 'event' AND entity_id = ?", [r.entityId]);
        case TrashEntity.media:
          final m = await (db.select(db.mediaAssets)..where((x) => x.id.equals(r.entityId))).getSingleOrNull();
          if (m != null) filesToDelete.add((m.filePath, m.thumbPath));
          await (db.update(db.persons)..where((p) => p.profileMediaId.equals(r.entityId)))
              .write(const PersonsCompanion(profileMediaId: Value(null)));
          await (db.delete(db.mediaAssets)..where((x) => x.id.equals(r.entityId))).go();
        case TrashEntity.story:
          await (db.delete(db.stories)..where((x) => x.id.equals(r.entityId))).go();
        case TrashEntity.source:
          await (db.delete(db.sources)..where((x) => x.id.equals(r.entityId))).go();
        case TrashEntity.album:
          await (db.delete(db.albums)..where((x) => x.id.equals(r.entityId))).go();
        case TrashEntity.tree:
          final media = await (db.select(db.mediaAssets)..where((m) => m.treeId.equals(r.entityId))).get();
          for (final m in media) {
            filesToDelete.add((m.filePath, m.thumbPath));
          }
          await (db.delete(db.familyTrees)..where((x) => x.id.equals(r.entityId))).go();
          await (db.delete(db.deletionRecords)..where((d) => d.treeId.equals(r.entityId))).go();
        case TrashEntity.relationship:
          break; // already removed; just drop the undo snapshot
      }
      await (db.delete(db.deletionRecords)..where((d) => d.id.equals(recordId))).go();
    });
    for (final (f, t) in filesToDelete) {
      await storage.deleteFiles(f, t);
    }
  }

  /// Photos linked only to [personId] and nothing else.
  Future<List<MediaAsset>> exclusiveMediaOf(String personId) async {
    final rows = await db.customSelect('''
      SELECT m.* FROM media_assets m
      JOIN media_persons mp ON mp.media_id = m.id AND mp.person_id = ?
      WHERE (SELECT COUNT(*) FROM media_persons x WHERE x.media_id = m.id) = 1
        AND NOT EXISTS (SELECT 1 FROM media_events e WHERE e.media_id = m.id)
        AND NOT EXISTS (SELECT 1 FROM story_media s WHERE s.media_id = m.id)
        AND NOT EXISTS (SELECT 1 FROM album_media a WHERE a.media_id = m.id)
    ''', variables: [Variable.withString(personId)], readsFrom: {db.mediaAssets}).get();
    return rows.map((r) => db.mediaAssets.map(r.data)).toList();
  }

  Future<void> emptyTrash() async {
    final all = await db.select(db.deletionRecords).get();
    for (final r in all) {
      await purge(r.id);
    }
  }

  /// Removes trash entries older than [days].
  Future<int> autoPurge({int days = 30}) async {
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final old = await (db.select(db.deletionRecords)..where((d) => d.deletedAt.isSmallerThanValue(cutoff))).get();
    for (final r in old) {
      try {
        await purge(r.id);
      } catch (_) {}
    }
    return old.length;
  }

  // ============================================================== settings

  Future<Map<String, String>> loadSettings() async {
    final rows = await db.select(db.appSettings).get();
    return {for (final r in rows) r.key: r.value};
  }

  Future<void> putSetting(String key, String value) =>
      db.into(db.appSettings).insertOnConflictUpdate(AppSettingsCompanion.insert(key: key, value: value));

  Future<void> putSettings(Map<String, String> values) async {
    await db.batch((b) {
      for (final e in values.entries) {
        b.insert(db.appSettings, AppSettingsCompanion.insert(key: e.key, value: e.value),
            mode: InsertMode.insertOrReplace);
      }
    });
  }

  // ======================================================== backup history

  Stream<List<BackupRecord>> watchBackupHistory() =>
      (db.select(db.backupRecords)..orderBy([(b) => OrderingTerm.desc(b.createdAt)])).watch();

  Future<void> logBackup({
    required String kind,
    required String fileName,
    int sizeBytes = 0,
    bool encrypted = false,
    String? summary,
  }) =>
      db.into(db.backupRecords).insert(BackupRecordsCompanion.insert(
            id: newId(),
            kind: kind,
            fileName: fileName,
            sizeBytes: Value(sizeBytes),
            encrypted: Value(encrypted),
            summary: Value(summary),
          ));

  // ============================================================ maintenance

  Future<StorageReport> storageReport() async {
    final paths = AppPaths.I;
    final dbSize = await paths.databaseFile.exists() ? await paths.databaseFile.length() : 0;
    var wal = 0;
    for (final ext in ['-wal', '-shm']) {
      final f = paths.databaseFile.path + ext;
      try {
        wal += await File(f).length();
      } catch (_) {}
    }
    final media = await AppPaths.sizeOf(paths.mediaRoot);
    final counts = await db.customSelect('''
      SELECT
        (SELECT COUNT(*) FROM media_assets WHERE kind = 'photo' AND deleted_at IS NULL) AS photos,
        (SELECT COUNT(*) FROM media_assets WHERE kind = 'document' AND deleted_at IS NULL) AS docs,
        (SELECT COUNT(*) FROM persons WHERE deleted_at IS NULL) AS people,
        (SELECT COUNT(*) FROM deletion_records) AS trash
    ''').getSingle();
    return StorageReport(
      databaseBytes: dbSize + wal,
      mediaBytes: media,
      photos: counts.read<int>('photos'),
      documents: counts.read<int>('docs'),
      people: counts.read<int>('people'),
      trashItems: counts.read<int>('trash'),
    );
  }

  /// Deletes media files on disk that no database row references.
  Future<int> cleanOrphanFiles() async {
    final rows = await db.select(db.mediaAssets).get();
    final known = <String>{};
    for (final m in rows) {
      known.add(AppPaths.I.resolve(m.filePath));
      if (m.thumbPath != null) known.add(AppPaths.I.resolve(m.thumbPath!));
    }
    var removed = 0;
    final root = AppPaths.I.mediaRoot;
    if (!await root.exists()) return 0;
    await for (final e in root.list(recursive: true)) {
      if (e is File && !known.contains(e.path)) {
        try {
          await e.delete();
          removed++;
        } catch (_) {}
      }
    }
    return removed;
  }
}

class StorageReport {
  const StorageReport({
    required this.databaseBytes,
    required this.mediaBytes,
    required this.photos,
    required this.documents,
    required this.people,
    required this.trashItems,
  });
  final int databaseBytes;
  final int mediaBytes;
  final int photos;
  final int documents;
  final int people;
  final int trashItems;
  int get totalBytes => databaseBytes + mediaBytes;
}
