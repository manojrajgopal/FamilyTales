import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/core/repositories/family_repository.dart';
import 'package:family_tales/core/services/app_paths.dart';
import 'package:family_tales/features/backup/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'seed.dart';

void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ft_backup_test');
    AppPaths.initForTest(tmp);
    db = AppDatabase.memory();
  });

  tearDown(() async {
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('backup → restore as new tree remaps every id and copies media', () async {
    final seed = await seedTree(db);
    final service = BackupService(db);
    final out = p.join(tmp.path, 'out');
    final progress = <double>[];
    final res = await service.createBackup(BackupRequest(treeIds: [seed.treeId]),
        outDir: out, onProgress: (f, _) => progress.add(f));
    expect(File(res.path).existsSync(), isTrue);
    expect(progress, isNotEmpty);
    expect(res.path.endsWith('.ftbackup'), isTrue);
    expect(res.counts.people, 3);
    expect(res.counts.relationships, 3);
    expect(res.counts.photos, 1);
    expect(res.missingFiles, isEmpty);

    final insp = await service.inspect(res.path, onProgress: (f, _) => progress.add(f));
    expect(insp.encrypted, isFalse);
    expect(insp.manifest.trees.single.name, 'Smith family');
    expect(insp.counts.people, 3);
    expect(insp.treePeople[seed.treeId], 3);

    final restored = await service.restore(insp, RestoreRequest.asNew(treeIds: [seed.treeId]));
    await insp.dispose();
    final newTree = restored.treeIds.single;
    expect(newTree, isNot(seed.treeId));
    expect(restored.treeNames.single, 'Smith family (restored)');

    final people = await (db.select(db.persons)..where((x) => x.treeId.equals(newTree))).get();
    expect(people, hasLength(3));
    final oldIds = (await (db.select(db.persons)..where((x) => x.treeId.equals(seed.treeId))).get())
        .map((x) => x.id)
        .toSet();
    for (final x in people) {
      expect(oldIds.contains(x.id), isFalse);
    }
    final arthur = people.firstWhere((x) => x.firstName == 'Arthur');
    expect(arthur.birthDate, 'ABT:1920');
    final paul = people.firstWhere((x) => x.firstName == 'Paul');

    final tree = await (db.select(db.familyTrees)..where((t) => t.id.equals(newTree))).getSingle();
    expect(tree.homePersonId, paul.id);

    final links = await (db.select(db.parentChildLinks)..where((x) => x.treeId.equals(newTree))).get();
    expect(links, hasLength(2));
    expect(links.every((l) => l.childId == paul.id), isTrue);
    expect(links.map((l) => l.type).toSet(), {ParentType.biological, ParentType.adoptive});
    final partners = await (db.select(db.partnerships)..where((x) => x.treeId.equals(newTree))).get();
    expect(partners.single.startDate, 'EX:1948-06');

    final media = await (db.select(db.mediaAssets)..where((x) => x.treeId.equals(newTree))).get();
    expect(media, hasLength(1));
    expect(media.single.id, isNot(seed.mediaId));
    expect(arthur.profileMediaId, media.single.id);
    final copied = File(AppPaths.I.resolve(media.single.filePath));
    expect(copied.readAsBytesSync(), seed.fileBytes);
    expect(p.isWithin(AppPaths.I.mediaDir(newTree).path, copied.path), isTrue);
    expect(File(AppPaths.I.resolve(media.single.thumbPath!)).existsSync(), isTrue);

    final mp = await (db.select(db.mediaPersons)..where((x) => x.mediaId.equals(media.single.id))).get();
    expect(mp.single.personId, arthur.id);

    final cits = await (db.select(db.citations).join([
      innerJoin(db.sources, db.sources.id.equalsExp(db.citations.sourceId)),
    ])
          ..where(db.sources.treeId.equals(newTree)))
        .map((r) => r.readTable(db.citations))
        .get();
    expect(cits, hasLength(2));
    final ev = await (db.select(db.familyEvents)..where((x) => x.treeId.equals(newTree))).getSingle();
    expect(cits.map((c) => c.entityId).toSet(), {paul.id, ev.id});
    final rem = await (db.select(db.reminders)..where((x) => x.treeId.equals(newTree))).getSingle();
    expect(rem.personId, paul.id);
    final values = await (db.select(db.personCustomValues)..where((x) => x.personId.equals(arthur.id))).get();
    expect(values.single.value, 'Anglican');

    // Original tree untouched.
    expect(await (db.select(db.persons)..where((x) => x.treeId.equals(seed.treeId))).get(), hasLength(3));

    final history = await db.select(db.backupRecords).get();
    expect(history.map((h) => h.kind).toSet(), {'backup', 'restore'});
  });

  test('restore replacing an existing tree swaps its contents', () async {
    final seed = await seedTree(db);
    final service = BackupService(db);
    final res = await service.createBackup(BackupRequest(treeIds: [seed.treeId], includeMedia: false),
        outDir: p.join(tmp.path, 'out'));

    // Modify the live tree after the backup.
    await FamilyRepository(db).createPerson(
        PersonsCompanion.insert(id: newId(), treeId: seed.treeId, firstName: const Value('Extra')));
    expect(await (db.select(db.persons)..where((x) => x.treeId.equals(seed.treeId))).get(), hasLength(4));

    final insp = await service.inspect(res.path);
    final r = await service.restore(
        insp, RestoreRequest.replace(sourceTreeId: seed.treeId, targetTreeId: seed.treeId));
    await insp.dispose();
    expect(r.treeIds.single, seed.treeId);
    final people = await (db.select(db.persons)..where((x) => x.treeId.equals(seed.treeId))).get();
    expect(people, hasLength(3));
    expect(people.any((x) => x.firstName == 'Extra'), isFalse);
    expect(await db.select(db.familyTrees).get(), hasLength(1));
    // Media excluded → the profile photo reference is cleared.
    expect(people.firstWhere((x) => x.firstName == 'Arthur').profileMediaId, isNull);
  });

  test('tampered archive is rejected with a detailed report', () async {
    final seed = await seedTree(db);
    final service = BackupService(db);
    final res = await service.createBackup(BackupRequest(treeIds: [seed.treeId]),
        outDir: p.join(tmp.path, 'out'));
    final bytes = File(res.path).readAsBytesSync();
    // Corrupt a byte inside the stored (uncompressed) photo payload.
    final idx = bytes.length ~/ 2;
    bytes[idx] = bytes[idx] ^ 0xFF;
    final bad = File(p.join(tmp.path, 'bad.ftbackup'))..writeAsBytesSync(bytes);
    await expectLater(service.inspect(bad.path), throwsA(isA<BackupFormatException>()));
  });

  test('non-backup files are rejected', () async {
    final f = File(p.join(tmp.path, 'x.ftbackup'))..writeAsStringSync('hello world');
    await expectLater(BackupService(db).inspect(f.path), throwsA(isA<BackupFormatException>()));
  });
}
