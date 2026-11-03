/// Creates, inspects and restores `.ftbackup` archives.
///
/// Archive layout (ZIP):
/// ```
/// manifest.json          format, versions, trees, counts, sha256 per entry
/// data.json              rows of every family table for the chosen trees
/// media/<relative path>  photo / document files (optional)
/// ```
/// Optionally wrapped in the password-protected `FTENC1` container (see
/// backup_crypto.dart). Heavy work (zip, hashing, encryption) runs in a
/// background isolate; database access stays on the calling isolate.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../../core/repositories/system_repository.dart';
import '../../core/services/app_paths.dart';
import 'backup_crypto.dart';
import 'backup_format.dart';
import 'isolate_task.dart';

export 'backup_format.dart';
export 'isolate_task.dart' show ProgressCallback;

String _uuid() => const Uuid().v4();

/// What to put into a new backup.
class BackupRequest {
  const BackupRequest({
    required this.treeIds,
    this.includeMedia = true,
    this.includeSettings = false,
    this.password,
  });

  final List<String> treeIds;
  final bool includeMedia;
  final bool includeSettings;

  /// Null or empty = unencrypted.
  final String? password;

  bool get encrypted => password != null && password!.isNotEmpty;
}

/// A freshly written backup file.
class BackupResult {
  const BackupResult({
    required this.path,
    required this.sizeBytes,
    required this.encrypted,
    required this.counts,
    required this.treeNames,
    required this.missingFiles,
  });

  final String path;
  final int sizeBytes;
  final bool encrypted;
  final BackupCounts counts;
  final List<String> treeNames;
  final List<String> missingFiles;

  String get fileName => p.basename(path);

  String get summary => '${treeNames.join(', ')} · ${counts.summary}';
}

/// A validated, staged backup ready to be previewed and restored.
class BackupInspection {
  BackupInspection({
    required this.fileName,
    required this.sizeBytes,
    required this.encrypted,
    required this.manifest,
    required this.stagingDir,
    required this.counts,
    required this.treePeople,
    required this.warnings,
  });

  final String fileName;
  final int sizeBytes;
  final bool encrypted;
  final BackupManifest manifest;

  /// Directory holding the verified `data.json` and `media/…` files.
  final String stagingDir;

  /// Counts computed from the (verified) data itself.
  final BackupCounts counts;

  /// Tree id → number of people in the backup.
  final Map<String, int> treePeople;
  final List<String> warnings;

  String get dataPath => p.join(stagingDir, backupDataEntry);

  bool get hasSettings => manifest.includesSettings;

  /// Deletes the staged files.
  Future<void> dispose() async {
    try {
      final d = Directory(stagingDir);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }
}

enum RestoreMode {
  /// Every id is remapped; the backup becomes new, independent tree(s).
  asNew,

  /// One backup tree replaces the contents of an existing tree.
  replace,
}

class RestoreRequest {
  const RestoreRequest.asNew({required this.treeIds, this.restoreSettings = false})
      : mode = RestoreMode.asNew,
        sourceTreeId = null,
        targetTreeId = null;

  const RestoreRequest.replace({
    required String this.sourceTreeId,
    required String this.targetTreeId,
    this.restoreSettings = false,
  })  : mode = RestoreMode.replace,
        treeIds = const [];

  final RestoreMode mode;

  /// Backup trees to restore ([RestoreMode.asNew]).
  final List<String> treeIds;

  /// Backup tree whose data replaces [targetTreeId] ([RestoreMode.replace]).
  final String? sourceTreeId;
  final String? targetTreeId;

  /// Apply the backup's (safe) app preferences.
  final bool restoreSettings;
}

class RestoreResult {
  const RestoreResult({
    required this.treeIds,
    required this.treeNames,
    required this.counts,
    required this.settings,
    required this.missingMedia,
  });

  /// Ids of the restored trees on this device.
  final List<String> treeIds;
  final List<String> treeNames;
  final BackupCounts counts;

  /// Preferences to apply (only [restorableSettingKeys]).
  final Map<String, String> settings;

  /// Media records whose file was not present in the archive.
  final int missingMedia;

  String get summary => '${treeNames.join(', ')} · ${counts.summary}';
}

class BackupService {
  BackupService(this.db, {SystemRepository? system})
      : system = system ?? SystemRepository(db);

  final AppDatabase db;
  final SystemRepository system;

  // ============================================================== collect

  /// Reads every live (not trashed) row of [treeIds] into JSON maps and
  /// removes references to rows that are not part of the selection.
  Future<BackupTables> collectTables(
    List<String> treeIds, {
    bool includeMedia = true,
    bool includeSettings = false,
  }) async {
    final ids = treeIds.toSet().toList();
    List<Map<String, dynamic>> j(Iterable<DataClass> rows) =>
        [for (final r in rows) r.toJson(serializer: backupSerializer)];

    final t = <String, List<Map<String, dynamic>>>{};
    t['family_trees'] = j(await (db.select(db.familyTrees)
          ..where((x) => x.id.isIn(ids) & x.deletedAt.isNull()))
        .get());
    t['persons'] = j(await (db.select(db.persons)
          ..where((x) => x.treeId.isIn(ids) & x.deletedAt.isNull()))
        .get());
    t['parent_child_links'] = j(
        await (db.select(db.parentChildLinks)..where((x) => x.treeId.isIn(ids))).get());
    t['partnerships'] =
        j(await (db.select(db.partnerships)..where((x) => x.treeId.isIn(ids))).get());
    t['family_branches'] =
        j(await (db.select(db.familyBranches)..where((x) => x.treeId.isIn(ids))).get());
    t['person_branches'] = j(await (db.select(db.personBranches).join([
      innerJoin(db.familyBranches, db.familyBranches.id.equalsExp(db.personBranches.branchId)),
    ])
          ..where(db.familyBranches.treeId.isIn(ids)))
        .map((r) => r.readTable(db.personBranches))
        .get());
    t['family_events'] = j(await (db.select(db.familyEvents)
          ..where((x) => x.treeId.isIn(ids) & x.deletedAt.isNull()))
        .get());
    t['event_persons'] = j(await (db.select(db.eventPersons).join([
      innerJoin(db.familyEvents, db.familyEvents.id.equalsExp(db.eventPersons.eventId)),
    ])
          ..where(db.familyEvents.treeId.isIn(ids)))
        .map((r) => r.readTable(db.eventPersons))
        .get());
    if (includeMedia) {
      t['media_assets'] = j(await (db.select(db.mediaAssets)
            ..where((x) => x.treeId.isIn(ids) & x.deletedAt.isNull()))
          .get());
      t['media_persons'] = j(await (db.select(db.mediaPersons).join([
        innerJoin(db.mediaAssets, db.mediaAssets.id.equalsExp(db.mediaPersons.mediaId)),
      ])
            ..where(db.mediaAssets.treeId.isIn(ids)))
          .map((r) => r.readTable(db.mediaPersons))
          .get());
      t['media_events'] = j(await (db.select(db.mediaEvents).join([
        innerJoin(db.mediaAssets, db.mediaAssets.id.equalsExp(db.mediaEvents.mediaId)),
      ])
            ..where(db.mediaAssets.treeId.isIn(ids)))
          .map((r) => r.readTable(db.mediaEvents))
          .get());
    }
    t['albums'] = j(await (db.select(db.albums)
          ..where((x) => x.treeId.isIn(ids) & x.deletedAt.isNull()))
        .get());
    t['album_media'] = j(await (db.select(db.albumMedia).join([
      innerJoin(db.albums, db.albums.id.equalsExp(db.albumMedia.albumId)),
    ])
          ..where(db.albums.treeId.isIn(ids)))
        .map((r) => r.readTable(db.albumMedia))
        .get());
    t['stories'] = j(await (db.select(db.stories)
          ..where((x) => x.treeId.isIn(ids) & x.deletedAt.isNull()))
        .get());
    Future<List<Map<String, dynamic>>> storyRows<T extends Table, D extends DataClass>(
        TableInfo<T, D> table, GeneratedColumn<String> storyId) async {
      final rows = await (db.select(table).join([
        innerJoin(db.stories, db.stories.id.equalsExp(storyId)),
      ])
            ..where(db.stories.treeId.isIn(ids)))
          .map((r) => r.readTable(table))
          .get();
      return j(rows);
    }

    t['story_persons'] = await storyRows(db.storyPersons, db.storyPersons.storyId);
    t['story_events'] = await storyRows(db.storyEvents, db.storyEvents.storyId);
    t['story_media'] = await storyRows(db.storyMedia, db.storyMedia.storyId);
    t['story_tags'] = await storyRows(db.storyTags, db.storyTags.storyId);
    t['tags'] = j(await (db.select(db.tags)..where((x) => x.treeId.isIn(ids))).get());
    t['person_tags'] = j(await (db.select(db.personTags).join([
      innerJoin(db.tags, db.tags.id.equalsExp(db.personTags.tagId)),
    ])
          ..where(db.tags.treeId.isIn(ids)))
        .map((r) => r.readTable(db.personTags))
        .get());
    t['sources'] = j(await (db.select(db.sources)
          ..where((x) => x.treeId.isIn(ids) & x.deletedAt.isNull()))
        .get());
    t['citations'] = j(await (db.select(db.citations).join([
      innerJoin(db.sources, db.sources.id.equalsExp(db.citations.sourceId)),
    ])
          ..where(db.sources.treeId.isIn(ids)))
        .map((r) => r.readTable(db.citations))
        .get());
    t['custom_fields'] =
        j(await (db.select(db.customFields)..where((x) => x.treeId.isIn(ids))).get());
    t['person_custom_values'] = j(await (db.select(db.personCustomValues).join([
      innerJoin(db.customFields, db.customFields.id.equalsExp(db.personCustomValues.fieldId)),
    ])
          ..where(db.customFields.treeId.isIn(ids)))
        .map((r) => r.readTable(db.personCustomValues))
        .get());
    t['reminders'] =
        j(await (db.select(db.reminders)..where((x) => x.treeId.isIn(ids))).get());
    if (includeSettings) {
      t[settingsTableKey] = [
        for (final s in await db.select(db.appSettings).get())
          {'key': s.key, 'value': s.value}
      ];
    }
    return sanitizeTables(t);
  }

  // =============================================================== create

  /// Writes a backup of [req] into [outDir] (default: the app's export
  /// folder) and logs it in the backup history.
  Future<BackupResult> createBackup(
    BackupRequest req, {
    String? outDir,
    ProgressCallback? onProgress,
  }) async {
    if (req.treeIds.isEmpty) throw BackupException('Choose at least one family tree.');
    if (req.encrypted && req.password!.length < 6) {
      throw BackupException('Use a password with at least 6 characters.');
    }
    onProgress?.call(0, 'Reading family data…');
    final tables = await collectTables(req.treeIds,
        includeMedia: req.includeMedia, includeSettings: req.includeSettings);
    final trees = tables['family_trees']!;
    if (trees.isEmpty) throw BackupException('The selected trees no longer exist.');
    final counts = BackupCounts.of(tables);
    final treeInfos = [
      for (final t in trees)
        BackupTreeInfo(t['id'] as String, t['name'] as String,
            people: tables['persons']!.where((x) => x['treeId'] == t['id']).length),
    ];

    final files = <(String, String)>[];
    final unsafe = <String>[];
    if (req.includeMedia) {
      final paths = AppPaths.I;
      for (final m in tables['media_assets']!) {
        for (final rel in [m['filePath'], m['thumbPath']]) {
          if (rel is! String || rel.isEmpty) continue;
          final entry = '$backupMediaPrefix${rel.replaceAll('\\', '/')}';
          if (!isSafeMediaEntry(entry)) {
            unsafe.add(entry);
            continue;
          }
          files.add((entry, paths.resolve(rel)));
        }
      }
    }

    final dir = outDir ?? AppPaths.I.exportsDir().path;
    await Directory(dir).create(recursive: true);
    final name = _fileNameFor(treeInfos.map((t) => t.name).toList());
    // Never overwrite an earlier backup made in the same minute.
    var outPath = p.join(dir, name);
    for (var i = 2; await File(outPath).exists(); i++) {
      outPath = p.join(dir, name.replaceFirst('.$backupFileExtension', '_$i.$backupFileExtension'));
    }
    final workDir = AppPaths.I.temp.path;
    await Directory(workDir).create(recursive: true);

    final job = _ArchiveJob(
      dataJson: encodeBackupData(tables, schemaVersion: db.schemaVersion),
      files: files,
      outPath: outPath,
      workPath: p.join(workDir, 'backup_${_uuid()}.zip'),
      password: req.encrypted ? req.password : null,
      iterations: defaultKdfIterations,
      manifest: {
        'formatVersion': backupFormatVersion,
        'appVersion': backupAppVersion,
        'schemaVersion': db.schemaVersion,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'trees': [for (final t in treeInfos) t.toJson()],
        'counts': counts.toJson(),
        'includesMedia': req.includeMedia,
        'includesSettings': req.includeSettings,
      },
      preMissing: unsafe,
    );
    final (size, missing) = await _runWriteArchive(job, onProgress);
    final result = BackupResult(
      path: outPath,
      sizeBytes: size,
      encrypted: req.encrypted,
      counts: counts,
      treeNames: [for (final t in treeInfos) t.name],
      missingFiles: missing,
    );
    await system.logBackup(
      kind: 'backup',
      fileName: result.fileName,
      sizeBytes: size,
      encrypted: req.encrypted,
      summary: result.summary,
    );
    return result;
  }

  static String _fileNameFor(List<String> treeNames) {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${n.year}-${two(n.month)}-${two(n.day)}_${two(n.hour)}${two(n.minute)}';
    var slug = treeNames.length == 1 ? treeNames.first : 'Family';
    slug = slug.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    if (slug.isEmpty) slug = 'Family';
    if (slug.length > 40) slug = slug.substring(0, 40);
    return 'FamilyTales_${slug}_$stamp.$backupFileExtension';
  }

  // ============================================================== inspect

  /// Decrypts (when needed), verifies and stages a backup file. Throws
  /// [BackupPasswordRequired], [BackupWrongPassword] or
  /// [BackupFormatException] (with a detailed list of problems).
  Future<BackupInspection> inspect(
    String path, {
    String? password,
    String? displayName,
    ProgressCallback? onProgress,
  }) async {
    final file = File(path);
    if (!await file.exists()) throw BackupException('The selected file could not be read.');
    final staging = p.join(AppPaths.I.temp.path, 'restore_${_uuid()}');
    final schema = db.schemaVersion;
    final name = displayName ?? p.basename(path);
    try {
      return await _runInspect(path, password, staging, schema, name, onProgress);
    } catch (e) {
      try {
        final d = Directory(staging);
        if (await d.exists()) await d.delete(recursive: true);
      } catch (_) {}
      if (e is BackupException) rethrow;
      if (e is RemoteError) {
        throw BackupFormatException('The backup could not be read.', [e.toString()]);
      }
      rethrow;
    }
  }

  // ============================================================== restore

  /// Restores a previously [inspect]ed backup in a single transaction.
  Future<RestoreResult> restore(
    BackupInspection insp,
    RestoreRequest req, {
    ProgressCallback? onProgress,
  }) async {
    onProgress?.call(0.02, 'Reading family data…');
    final dataPath = insp.dataPath;
    final all = await _decodeDataFile(dataPath);

    final Set<String> keep;
    if (req.mode == RestoreMode.asNew) {
      if (req.treeIds.isEmpty) throw BackupException('Choose at least one tree to restore.');
      keep = req.treeIds.toSet();
    } else {
      final target = await (db.select(db.familyTrees)
            ..where((t) => t.id.equals(req.targetTreeId!) & t.deletedAt.isNull()))
          .getSingleOrNull();
      if (target == null) throw BackupException('The tree to replace no longer exists.');
      keep = {req.sourceTreeId!};
    }
    final tables = sanitizeTables(all, keepTrees: keep);
    if (tables['family_trees']!.isEmpty) {
      throw BackupException('The selected tree is not part of this backup.');
    }

    // ---- id map
    final idMap = <String, String>{};
    for (final id in entityIds(tables)) {
      idMap[id] = _uuid();
    }
    if (req.mode == RestoreMode.replace) idMap[req.sourceTreeId!] = req.targetTreeId!;
    final mapped = remapTables(tables, idMap);

    // ---- unique tree names for new trees
    if (req.mode == RestoreMode.asNew) {
      final existing = (await (db.select(db.familyTrees)..where((t) => t.deletedAt.isNull())).get())
          .map((t) => t.name.toLowerCase())
          .toSet();
      for (final t in mapped['family_trees']!) {
        final base = (t['name'] as String).trim();
        var candidate = base;
        var i = 1;
        while (existing.contains(candidate.toLowerCase())) {
          final suffix = i == 1 ? ' (restored)' : ' (restored $i)';
          final room = 120 - suffix.length;
          candidate = (base.length > room ? base.substring(0, room) : base) + suffix;
          i++;
        }
        existing.add(candidate.toLowerCase());
        t['name'] = candidate;
        t['deletedAt'] = null;
      }
    } else {
      for (final t in mapped['family_trees']!) {
        t['deletedAt'] = null;
      }
    }

    // ---- media files: new unique names under the new tree folder
    final paths = AppPaths.I;
    final copies = <(String from, String to)>[];
    var missingMedia = 0;
    for (final m in mapped['media_assets']!) {
      final treeId = m['treeId'] as String;
      final id = m['id'] as String;
      final oldFile = m['filePath'] as String?;
      final oldThumb = m['thumbPath'] as String?;
      if (oldFile != null && oldFile.isNotEmpty) {
        final ext = p.extension(oldFile).toLowerCase();
        final dest = p.join(paths.mediaDir(treeId).path, '$id${ext.isEmpty ? '.bin' : ext}');
        final staged = _stagedPath(insp.stagingDir, oldFile);
        if (staged != null && File(staged).existsSync()) {
          copies.add((staged, dest));
        } else {
          missingMedia++;
        }
        m['filePath'] = paths.relative(dest);
      }
      if (oldThumb != null && oldThumb.isNotEmpty) {
        final ext = p.extension(oldThumb).toLowerCase();
        final dest = p.join(paths.thumbDir(treeId).path, '$id${ext.isEmpty ? '.jpg' : ext}');
        final staged = _stagedPath(insp.stagingDir, oldThumb);
        if (staged != null && File(staged).existsSync()) {
          copies.add((staged, dest));
          m['thumbPath'] = paths.relative(dest);
        } else {
          m['thumbPath'] = null;
        }
      }
    }

    // ---- parse rows
    final rows = <String, List<Insertable<dynamic>>>{};
    for (final spec in backupTables) {
      rows[spec.name] = [for (final r in mapped[spec.name]!) spec.fromJson(r)];
    }

    // ---- copy files first (cleaned up again if the transaction fails)
    final written = <String>[];
    try {
      for (var i = 0; i < copies.length; i++) {
        final (from, to) = copies[i];
        await Directory(p.dirname(to)).create(recursive: true);
        await File(from).copy(to);
        written.add(to);
        onProgress?.call(0.05 + 0.6 * (i + 1) / copies.length,
            'Copying photos (${i + 1} of ${copies.length})…');
      }

      // Files of the tree being replaced (deleted after a successful commit).
      final oldFiles = <String>[];
      if (req.mode == RestoreMode.replace) {
        final old = await (db.select(db.mediaAssets)
              ..where((m) => m.treeId.equals(req.targetTreeId!)))
            .get();
        for (final m in old) {
          oldFiles.add(m.filePath);
          if (m.thumbPath != null) oldFiles.add(m.thumbPath!);
        }
      }

      onProgress?.call(0.7, 'Saving to your device…');
      await db.transaction(() async {
        if (req.mode == RestoreMode.replace) {
          await _deleteTreeContents(req.targetTreeId!);
        }
        await db.batch((b) {
          for (final spec in backupTables) {
            final list = rows[spec.name]!;
            if (list.isEmpty) continue;
            b.insertAll(_table(spec.name), list);
          }
        });
      });
      for (final rel in oldFiles) {
        try {
          final f = File(paths.resolve(rel));
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    } catch (e) {
      for (final f in written) {
        try {
          await File(f).delete();
        } catch (_) {}
      }
      if (e is BackupException) rethrow;
      throw BackupException('The backup could not be restored. Nothing was changed.',
          [e.toString()]);
    }

    final settings = <String, String>{};
    if (req.restoreSettings) {
      for (final s in tables[settingsTableKey] ?? const <Map<String, dynamic>>[]) {
        final k = s['key'] as String;
        if (restorableSettingKeys.contains(k)) settings[k] = s['value'] as String;
      }
    }
    final result = RestoreResult(
      treeIds: [for (final t in mapped['family_trees']!) t['id'] as String],
      treeNames: [for (final t in mapped['family_trees']!) t['name'] as String],
      counts: BackupCounts.of(mapped),
      settings: settings,
      missingMedia: missingMedia,
    );
    onProgress?.call(1, 'Done');
    await system.logBackup(
      kind: 'restore',
      fileName: insp.fileName,
      sizeBytes: insp.sizeBytes,
      encrypted: insp.encrypted,
      summary: '${req.mode == RestoreMode.replace ? 'Replaced' : 'Restored'}: ${result.summary}',
    );
    return result;
  }

  TableInfo<Table, dynamic> _table(String name) =>
      db.allTables.firstWhere((t) => t.actualTableName == name);

  /// Deletes every row belonging to [treeId] (including the tree row and
  /// its trash entries). Runs inside the caller's transaction.
  Future<void> _deleteTreeContents(String treeId) async {
    Future<void> run(String sql, Set<TableInfo<Table, dynamic>> tables, [int n = 1]) =>
        db.customUpdate(sql,
            variables: [for (var i = 0; i < n; i++) Variable.withString(treeId)],
            updates: tables,
            updateKind: UpdateKind.delete);
    await run(
        'DELETE FROM person_branches WHERE branch_id IN (SELECT id FROM family_branches WHERE tree_id = ?) '
        'OR person_id IN (SELECT id FROM persons WHERE tree_id = ?)',
        {db.personBranches},
        2);
    await run(
        'DELETE FROM event_persons WHERE event_id IN (SELECT id FROM family_events WHERE tree_id = ?) '
        'OR person_id IN (SELECT id FROM persons WHERE tree_id = ?)',
        {db.eventPersons},
        2);
    for (final info in <TableInfo<Table, dynamic>>[db.mediaPersons, db.mediaEvents]) {
      await run(
          'DELETE FROM ${info.actualTableName} WHERE media_id IN (SELECT id FROM media_assets WHERE tree_id = ?)',
          {info});
    }
    await run('DELETE FROM album_media WHERE album_id IN (SELECT id FROM albums WHERE tree_id = ?)',
        {db.albumMedia});
    for (final info in <TableInfo<Table, dynamic>>[
      db.storyPersons,
      db.storyEvents,
      db.storyMedia,
      db.storyTags,
    ]) {
      await run(
          'DELETE FROM ${info.actualTableName} WHERE story_id IN (SELECT id FROM stories WHERE tree_id = ?)',
          {info});
    }
    await run('DELETE FROM person_tags WHERE tag_id IN (SELECT id FROM tags WHERE tree_id = ?)',
        {db.personTags});
    await run('DELETE FROM citations WHERE source_id IN (SELECT id FROM sources WHERE tree_id = ?)',
        {db.citations});
    await run(
        'DELETE FROM person_custom_values WHERE field_id IN (SELECT id FROM custom_fields WHERE tree_id = ?)',
        {db.personCustomValues});
    for (final info in <TableInfo<Table, dynamic>>[
      db.reminders,
      db.customFields,
      db.sources,
      db.tags,
      db.stories,
      db.albums,
      db.mediaAssets,
      db.familyEvents,
      db.familyBranches,
      db.partnerships,
      db.parentChildLinks,
      db.persons,
    ]) {
      await run('DELETE FROM ${info.actualTableName} WHERE tree_id = ?', {info});
    }
    await run('DELETE FROM deletion_records WHERE tree_id = ?', {db.deletionRecords});
    await run('DELETE FROM family_trees WHERE id = ?', {db.familyTrees});
  }
}

/// Absolute staged path for a stored relative media path, or null if the
/// path is unsafe.
String? _stagedPath(String stagingDir, String rel) {
  final entry = '$backupMediaPrefix${rel.replaceAll('\\', '/')}';
  if (!isSafeMediaEntry(entry)) return null;
  return p.joinAll([stagingDir, ...entry.split('/')]);
}

// ================================================================ isolates
//
// Isolate entry points are launched from top-level functions so that the
// closures sent to the background isolate capture only plain values (never
// the service or its database connection).

Future<(int, List<String>)> _runWriteArchive(_ArchiveJob job, ProgressCallback? onProgress) =>
    runInBackground((progress) => _writeArchive(job, progress), onProgress: onProgress);

Future<BackupInspection> _runInspect(String path, String? password, String staging, int schema,
        String name, ProgressCallback? onProgress) =>
    runInBackground(
      (progress) => _inspectArchive(path, password, staging, schema, name, progress),
      onProgress: onProgress,
    );

Future<BackupTables> _decodeDataFile(String path) =>
    Isolate.run(() => decodeBackupData(File(path).readAsStringSync()));

class _ArchiveJob {
  const _ArchiveJob({
    required this.dataJson,
    required this.files,
    required this.outPath,
    required this.workPath,
    required this.password,
    required this.iterations,
    required this.manifest,
    required this.preMissing,
  });

  final String dataJson;
  final List<(String, String)> files;
  final String outPath;
  final String workPath;
  final String? password;
  final int iterations;
  final Map<String, dynamic> manifest;
  final List<String> preMissing;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Lowercase hex SHA-256 of a file, read in 1 MiB chunks.
String sha256OfFile(String path) {
  final sink = _DigestSink();
  final conv = sha256.startChunkedConversion(sink);
  final raf = File(path).openSync();
  try {
    final buf = Uint8List(1 << 20);
    while (true) {
      final n = raf.readIntoSync(buf);
      if (n <= 0) break;
      conv.add(Uint8List.sublistView(buf, 0, n));
    }
  } finally {
    raf.closeSync();
  }
  conv.close();
  return sink.value.toString();
}

Future<(int, List<String>)> _writeArchive(_ArchiveJob job, ProgressCallback progress) async {
  final encrypt = job.password != null;
  final zipPath = encrypt ? job.workPath : job.outPath;
  final zipShare = encrypt ? 0.7 : 1.0;
  final dataBytes = utf8.encode(job.dataJson);
  final hashes = <String, String>{backupDataEntry: sha256.convert(dataBytes).toString()};
  final missing = <String>[...job.preMissing];
  final seen = <String>{};
  var total = dataBytes.length;
  final existing = <(String, String, int)>[];
  for (final (entry, abs) in job.files) {
    if (!seen.add(entry)) continue;
    final f = File(abs);
    if (!f.existsSync()) {
      missing.add(entry);
      continue;
    }
    final len = f.lengthSync();
    existing.add((entry, abs, len));
    total += len;
  }
  final enc = ZipFileEncoder();
  enc.create(zipPath, level: 6);
  try {
    progress(0.02, 'Packing family data…');
    enc.addArchiveFile(ArchiveFile.bytes(backupDataEntry, dataBytes));
    var done = dataBytes.length;
    for (var i = 0; i < existing.length; i++) {
      final (entry, abs, len) = existing[i];
      hashes[entry] = sha256OfFile(abs);
      // Photos are already compressed: store them as-is.
      await enc.addFile(File(abs), entry, ZipFileEncoder.store);
      done += len;
      progress(zipShare * done / (total == 0 ? 1 : total),
          'Packing photos (${i + 1} of ${existing.length})…');
    }
    final manifest = {
      ...job.manifest,
      'format': backupFormatId,
      'missingFiles': missing,
      'files': hashes,
    };
    enc.addArchiveFile(ArchiveFile.string(
        backupManifestEntry, const JsonEncoder.withIndent('  ').convert(manifest)));
  } finally {
    await enc.close();
  }
  if (encrypt) {
    progress(zipShare, 'Encrypting…');
    try {
      await encryptBackupFile(zipPath, job.outPath, job.password!,
          iterations: job.iterations,
          onProgress: (f) => progress(zipShare + (1 - zipShare) * f, 'Encrypting…'));
    } finally {
      try {
        File(zipPath).deleteSync();
      } catch (_) {}
    }
  }
  progress(1, 'Backup complete');
  return (File(job.outPath).lengthSync(), missing);
}

Future<BackupInspection> _inspectArchive(
  String path,
  String? password,
  String staging,
  int currentSchema,
  String displayName,
  ProgressCallback progress,
) async {
  Directory(staging).createSync(recursive: true);
  final size = File(path).lengthSync();
  final encrypted = isEncryptedBackup(path);
  var zipPath = path;
  if (encrypted) {
    if (password == null || password.isEmpty) throw BackupPasswordRequired();
    progress(0.02, 'Unlocking backup…');
    zipPath = p.join(staging, '_decrypted.zip');
    await decryptBackupFile(path, zipPath, password,
        onProgress: (f) => progress(0.02 + 0.38 * f, 'Decrypting…'));
  } else {
    final raf = File(path).openSync();
    final head = raf.readSync(4);
    raf.closeSync();
    if (head.length < 4 || head[0] != 0x50 || head[1] != 0x4B) {
      throw BackupFormatException('This file is not a Family Tales backup.',
          ['The file is neither a backup archive nor an encrypted backup.']);
    }
  }
  final base = encrypted ? 0.4 : 0.02;
  final input = InputFileStream(zipPath);
  try {
    Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input, verify: true);
    } catch (e) {
      throw BackupFormatException('The backup archive is damaged.', ['ZIP: $e']);
    }
    final manifestFile = archive.find(backupManifestEntry);
    if (manifestFile == null) {
      throw BackupFormatException('This file is not a Family Tales backup.',
          ['manifest.json is missing from the archive.']);
    }
    final manifest = BackupManifest.parse(
        utf8.decode(manifestFile.readBytes() ?? Uint8List(0), allowMalformed: true),
        currentSchema: currentSchema);

    final problems = <String>[];
    final warnings = <String>[];
    final entries = manifest.files.entries.toList();
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final name = e.key;
      if (name != backupDataEntry && !isSafeMediaEntry(name)) {
        problems.add('Unsafe file path in archive: $name');
        continue;
      }
      final af = archive.find(name);
      if (af == null || !af.isFile) {
        problems.add('Missing file: $name');
        continue;
      }
      final dest = p.joinAll([staging, ...name.split('/')]);
      Directory(p.dirname(dest)).createSync(recursive: true);
      try {
        final out = OutputFileStream(dest);
        try {
          af.writeContent(out);
        } finally {
          out.closeSync();
        }
      } catch (err) {
        problems.add('Could not extract $name: $err');
        continue;
      }
      final hash = sha256OfFile(dest);
      if (hash != e.value) problems.add('Checksum mismatch (file was altered or damaged): $name');
      progress(base + (0.9 - base) * (i + 1) / entries.length, 'Verifying files…');
    }
    for (final f in archive) {
      if (!f.isFile) continue;
      if (f.name == backupManifestEntry || manifest.files.containsKey(f.name)) continue;
      warnings.add('Ignored unexpected file: ${f.name}');
    }
    if (problems.isNotEmpty) {
      throw BackupFormatException(
          'The backup failed its integrity check. It may be damaged or incomplete.', problems);
    }
    progress(0.92, 'Checking records…');
    final tables =
        decodeBackupData(File(p.join(staging, backupDataEntry)).readAsStringSync());
    final counts = BackupCounts.of(tables);
    final mc = manifest.counts;
    if (mc.people != counts.people || mc.trees != counts.trees) {
      warnings.add('The manifest counts differ from the data '
          '(${mc.people} vs ${counts.people} people).');
    }
    if (manifest.missingFiles.isNotEmpty) {
      warnings.add('${manifest.missingFiles.length} photo file(s) were already missing '
          'when this backup was created.');
    }
    final treePeople = <String, int>{};
    for (final t in tables['family_trees']!) {
      final id = t['id'] as String;
      treePeople[id] = tables['persons']!.where((x) => x['treeId'] == id).length;
    }
    progress(1, 'Ready');
    return BackupInspection(
      fileName: displayName,
      sizeBytes: size,
      encrypted: encrypted,
      manifest: manifest,
      stagingDir: staging,
      counts: counts,
      treePeople: treePeople,
      warnings: warnings,
    );
  } finally {
    input.closeSync();
    if (encrypted) {
      try {
        File(zipPath).deleteSync();
      } catch (_) {}
    }
  }
}
