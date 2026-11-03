import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/repositories/family_repository.dart';
import 'package:family_tales/core/services/app_paths.dart';
import 'package:family_tales/features/backup/backup_service.dart';
import 'package:family_tales/features/backup/export/export_data.dart';
import 'package:family_tales/features/backup/export/export_privacy.dart';
import 'package:family_tales/features/backup/export/export_service.dart';
import 'package:family_tales/features/backup/gedcom/gedcom_importer.dart';
import 'package:family_tales/features/backup/gedcom/gedcom_parser.dart';
import 'package:family_tales/features/backup/pdf/pdf_theme.dart';
import 'package:family_tales/features/backup/pdf/profile_pdf.dart';
import 'package:family_tales/features/backup/pdf/tree_pdf.dart';
import 'package:family_tales/features/family_tree/layout/tree_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/widgets.dart' as pw;

import 'seed.dart';

PdfFonts _fonts() {
  pw.Font f(String n) =>
      pw.Font.ttf(File('assets/fonts/Inter-$n.ttf').readAsBytesSync().buffer.asByteData());
  return PdfFonts(regular: f('Regular'), medium: f('Medium'), semiBold: f('SemiBold'), bold: f('Bold'));
}

void main() {
  late Directory tmp;
  late AppDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ft_export_test');
    AppPaths.initForTest(tmp);
    db = AppDatabase.memory();
  });

  tearDown(() async {
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('CSV export escapes cells and neutralises formulas', () async {
    final seed = await seedTree(db);
    await FamilyRepository(db).createPerson(PersonsCompanion.insert(
      id: newId(),
      treeId: seed.treeId,
      firstName: const Value('=HYPERLINK("x")'),
      lastName: const Value('Doe, Jr'),
    ));
    final csv = buildMembersCsv(await TreeExportData.load(db, seed.treeId));
    final lines = csv.substring(1).trim().split('\r\n');
    expect(lines.first, csvColumns.join(','));
    expect(lines, hasLength(5));
    expect(csv, contains('"\'=HYPERLINK(""x"") Doe, Jr"'));
    final paul = lines.firstWhere((l) => l.startsWith('Paul Smith'));
    expect(paul, contains('Arthur Smith; Edith Smith'));
  });

  test('JSON export applies privacy filters', () async {
    final seed = await seedTree(db);
    final fam = FamilyRepository(db);
    await fam.setPrivate(seed.grandpa, true);
    await (db.update(db.persons)..where((x) => x.id.equals(seed.child)))
        .write(const PersonsCompanion(email: Value('paul@example.com'), notes: Value('secret')));
    final tables = await BackupService(db).collectTables([seed.treeId]);
    final filtered = applyPrivacyToTables(tables, ExportPrivacy.public);
    final people = filtered['persons']!;
    expect(people, hasLength(2));
    expect(people.any((x) => x['id'] == seed.grandpa), isFalse);
    final paul = people.firstWhere((x) => x['id'] == seed.child);
    expect(paul['email'], isNull);
    expect(paul['notes'], isNull);
    expect(paul['birthDate'], isNull); // living
    // Links to the private person are gone too.
    expect(filtered['parent_child_links']!.any((l) => l['parentId'] == seed.grandpa), isFalse);
    final json = buildTreeJson(filtered, schemaVersion: 1, privacy: ExportPrivacy.public);
    expect(json, isNot(contains('paul@example.com')));
    expect(json, contains('family-tales-json'));
  });

  test('tree and profile PDFs render', () async {
    final seed = await seedTree(db);
    final data = await TreeExportData.load(db, seed.treeId);
    final fonts = _fonts();
    for (final size in TreePdfPageSize.values) {
      final r = await buildTreePdf(
          data: data, fonts: fonts, options: TreePdfOptions(pageSize: size, focusId: seed.child));
      expect(String.fromCharCodes(r.bytes.take(4)), '%PDF');
      expect(r.people, 3);
    }
    final desc = await buildTreePdf(
        data: data,
        fonts: fonts,
        options: TreePdfOptions(mode: TreeViewMode.descendants, focusId: seed.grandpa));
    expect(desc.people, greaterThanOrEqualTo(2));
    await (db.update(db.persons)..where((x) => x.id.equals(seed.grandpa))).write(PersonsCompanion(
        biography: Value(List.filled(400, 'A long and eventful life in the family history. ').join())));
    final data2 = await TreeExportData.load(db, seed.treeId);
    final profile = await buildProfilePdf(data: data2, personId: seed.grandpa, fonts: fonts);
    expect(String.fromCharCodes(profile.take(4)), '%PDF');
    final hidden = await buildProfilePdf(
        data: await TreeExportData.load(db, seed.treeId, privacy: ExportPrivacy.public),
        personId: 'missing',
        fonts: fonts);
    expect(String.fromCharCodes(hidden.take(4)), '%PDF');
  });

  test('GEDCOM import plan can be built in a background isolate', () async {
    const ged = '0 HEAD\n1 CHAR UTF-8\n0 @I1@ INDI\n1 NAME A /B/\n0 TRLR\n';
    final plan = await Isolate.run(() => GedcomImporter(GedcomParser.parse(ged)).analyze());
    expect(plan.persons.single.lastName.value, 'B');
    final id = await plan.write(db, treeName: 'Iso');
    expect(await (db.select(db.persons)..where((x) => x.treeId.equals(id))).get(), hasLength(1));
  });

  test('export service writes files and logs them', () async {
    final seed = await seedTree(db);
    final svc = ExportService(db);
    final ged = await svc.gedcom(seed.treeId, ExportPrivacy.none);
    final json = await svc.json(seed.treeId, ExportPrivacy.public);
    final csv = await svc.csv(seed.treeId, ExportPrivacy.none);
    for (final f in [ged, json, csv]) {
      expect(File(f.path).existsSync(), isTrue);
      expect(p.isWithin(tmp.path, f.path), isTrue);
    }
    expect(File(ged.path).readAsStringSync(), startsWith('0 HEAD'));
    final log = await db.select(db.backupRecords).get();
    expect(log.where((r) => r.kind == 'export'), hasLength(3));
  });
}
