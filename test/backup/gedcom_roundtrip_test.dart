import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/core/models/fuzzy_date.dart';
import 'package:family_tales/core/repositories/content_repository.dart';
import 'package:family_tales/core/repositories/family_repository.dart';
import 'package:family_tales/features/backup/export/export_data.dart';
import 'package:family_tales/features/backup/export/export_privacy.dart';
import 'package:family_tales/features/backup/gedcom/gedcom_exporter.dart';
import 'package:family_tales/features/backup/gedcom/gedcom_importer.dart';
import 'package:family_tales/features/backup/gedcom/gedcom_parser.dart';
import 'package:family_tales/features/family/domain/family_graph.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  Future<String> seed() async {
    final fam = FamilyRepository(db);
    final tree = await fam.createTree('Roundtrip');
    Future<String> person(String first, String? last,
            {String? middle,
            Gender g = Gender.unknown,
            FuzzyDate? birth,
            FuzzyDate? death,
            bool living = true,
            String? birthPlace,
            String? notes,
            String? birthName,
            String? occupation}) =>
        fam.createPerson(PersonsCompanion.insert(
          id: newId(),
          treeId: tree,
          firstName: Value(first),
          middleName: Value(middle),
          lastName: Value(last),
          gender: Value(g),
          birthDate: Value(birth?.serialize()),
          deathDate: Value(death?.serialize()),
          isLiving: Value(living),
          birthPlace: Value(birthPlace),
          notes: Value(notes),
          birthName: Value(birthName),
          occupation: Value(occupation),
        ));
    final longNote = '${'Lorem ipsum dolor sit amet, consectetur adipiscing elit. ' * 8}\n'
        'Second paragraph with an email john@@example.com and a symbol @.';
    final john = await person('John', 'Smith',
        middle: 'Paul',
        g: Gender.male,
        birth: const FuzzyDate(qualifier: DateQualifier.about, year: 1920),
        death: FuzzyDate.ymd(1990, 3, 12),
        living: false,
        birthPlace: 'Leeds, England',
        notes: longNote,
        occupation: 'Carpenter');
    final mary = await person('Mary', 'Smith',
        g: Gender.female,
        birth: const FuzzyDate(qualifier: DateQualifier.between, year: 1921, year2: 1923),
        living: false,
        birthName: 'Mary Brown');
    final anna = await person('Anna', 'Smith', g: Gender.female, birth: FuzzyDate.ymd(1950, 6));
    final tom = await person('Tom', 'Smith', g: Gender.male, birth: FuzzyDate.text('Spring, after the war'));
    final eve = await person('Eve', 'Green', g: Gender.female, birth: FuzzyDate.ymd(1951));
    await fam.addPartnership(
        a: john,
        b: mary,
        start: FuzzyDate.ymd(1948, 6, 1),
        place: 'York',
        status: PartnerStatus.divorced,
        end: FuzzyDate.ymd(1960));
    await fam.addPartnership(a: tom, b: eve, type: PartnerType.partner);
    await fam.addParent(childId: anna, parentId: john);
    await fam.addParent(childId: anna, parentId: mary, type: ParentType.adoptive);
    await fam.addParent(childId: tom, parentId: john);
    final content = ContentRepository(db);
    final src = await content.saveSource(treeId: tree, title: 'Parish register', author: 'St Mary');
    await content.addCitation(
        sourceId: src, entityType: 'person', entityId: john, fact: 'birth', detail: 'p. 12', confidence: 3);
    await content.saveEvent(
        treeId: tree,
        title: 'Graduated from Leeds',
        type: EventType.graduation,
        date: FuzzyDate.ymd(1942).serialize(),
        location: 'Leeds',
        people: {john: null});
    final field = await fam.addCustomField(tree, 'Religion', CustomFieldType.text);
    await fam.setCustomValue(john, field, 'Methodist');
    return tree;
  }

  Person byName(List<Person> ps, String first) => ps.firstWhere((p) => p.firstName == first);

  test('GEDCOM export → import keeps people, relationships and fuzzy dates', () async {
    final tree = await seed();
    final data = await TreeExportData.load(db, tree);
    final result = GedcomExporter(data).build();
    final text = result.text;
    expect(result.people, 5);
    expect(text, startsWith('0 HEAD'));
    expect(text, contains('1 SOUR FAMILY_TALES'));
    expect(text, contains('2 VERS 5.5.1'));
    expect(text, contains('2 FORM LINEAGE-LINKED'));
    expect(text, contains('1 CHAR UTF-8'));
    expect(text.trimRight(), endsWith('0 TRLR'));
    expect(text, contains('CONC'));
    expect(text, contains('CONT'));
    expect(text, contains('2 PEDI adopted'));
    for (final line in const LineSplitter().convert(text)) {
      expect(line.length, lessThanOrEqualTo(255));
    }

    final doc = GedcomParser.parseBytes(Uint8List.fromList(utf8.encode(text)));
    final plan = GedcomImporter(doc, fileName: 'roundtrip.ged').analyze();
    expect(plan.suggestedName, 'roundtrip');
    expect(plan.report.unsupported, isEmpty, reason: '${plan.report.examples}');
    final newTree = await plan.write(db, treeName: 'Imported');

    final people = await (db.select(db.persons)..where((p) => p.treeId.equals(newTree))).get();
    expect(people, hasLength(5));
    final john = byName(people, 'John');
    expect(john.middleName, 'Paul');
    expect(john.lastName, 'Smith');
    expect(john.gender, Gender.male);
    expect(john.birthDate, 'ABT:1920');
    expect(john.deathDate, 'EX:1990-03-12');
    expect(john.isLiving, isFalse);
    expect(john.birthPlace, 'Leeds, England');
    expect(john.occupation, 'Carpenter');
    final original = await (db.select(db.persons)
          ..where((p) => p.treeId.equals(tree) & p.firstName.equals('John')))
        .getSingle();
    expect(john.notes, original.notes);
    final mary = byName(people, 'Mary');
    expect(mary.birthDate, 'BET:1921|1923');
    expect(mary.birthName, 'Mary Brown');
    expect(byName(people, 'Anna').birthDate, 'EX:1950-06');
    expect(byName(people, 'Anna').isLiving, isTrue);
    expect(FuzzyDate.tryParse(byName(people, 'Tom').birthDate)!.phrase, 'Spring, after the war');

    final links = await (db.select(db.parentChildLinks)..where((l) => l.treeId.equals(newTree))).get();
    final ids = {for (final p in people) p.id: p.firstName};
    final edges = {for (final l in links) '${ids[l.parentId]}>${ids[l.childId]}:${l.type.name}'};
    expect(edges, {'John>Anna:biological', 'Mary>Anna:adoptive', 'John>Tom:biological'});

    final couples = await (db.select(db.partnerships)..where((l) => l.treeId.equals(newTree))).get();
    expect(couples, hasLength(2));
    final jm = couples.firstWhere((c) => {ids[c.personAId], ids[c.personBId]}.contains('John'));
    expect({ids[jm.personAId], ids[jm.personBId]}, {'John', 'Mary'});
    expect(jm.type, PartnerType.marriage);
    expect(jm.status, PartnerStatus.divorced);
    expect(jm.startDate, 'EX:1948-06-01');
    expect(jm.endDate, 'EX:1960');
    expect(jm.place, 'York');
    final te = couples.firstWhere((c) => c.id != jm.id);
    expect(te.type, PartnerType.partner);
    expect(te.status, PartnerStatus.current);

    final g = FamilyGraph(persons: people, parentLinks: links, partnerships: couples);
    expect(g.siblings(byName(people, 'Anna').id).single.personId, byName(people, 'Tom').id);

    final events = await (db.select(db.familyEvents)..where((e) => e.treeId.equals(newTree))).get();
    expect(events.single.type, EventType.graduation);
    expect(events.single.title, 'Graduated from Leeds');
    expect(events.single.date, 'EX:1942');
    final sources = await (db.select(db.sources)..where((s) => s.treeId.equals(newTree))).get();
    expect(sources.single.title, 'Parish register');
    expect(sources.single.author, 'St Mary');
    final cites = await (db.select(db.citations)..where((c) => c.sourceId.equals(sources.single.id))).get();
    expect(cites.single.entityId, john.id);
    expect(cites.single.fact, 'birth');
    expect(cites.single.detail, 'p. 12');
    expect(cites.single.confidence, 3);
    final values = await (db.select(db.personCustomValues)..where((v) => v.personId.equals(john.id))).get();
    expect(values.single.value, 'Methodist');
  });

  test('unsupported tags are reported and preserved in notes', () async {
    const ged = '''0 HEAD
1 SOUR OTHER_APP
1 GEDC
2 VERS 5.5.1
1 CHAR UTF-8
0 @I1@ INDI
1 NAME Ada /Lovelace/
2 _MARNM King
1 SEX F
1 BIRT
2 DATE 10 DEC 1815
2 PLAC London
2 AGE 0
1 _CUSTOM hello world
1 OBJE
2 FILE ada.jpg
1 NOTE @N1@
1 FAMC @F1@
2 PEDI adopted
1 CHAN
2 DATE 1 JAN 2000
0 @I2@ INDI
1 NAME Lord /Byron/
1 SEX M
1 DEAT Y
0 @F1@ FAM
1 HUSB @I2@
1 CHIL @I1@
0 @N1@ NOTE First line of the note
1 CONC  continues here
1 CONT and a second line
0 @X1@ _LOC
1 NAME Somewhere
0 TRLR
''';
    final doc = GedcomParser.parse(ged);
    final plan = GedcomImporter(doc).analyze();
    final r = plan.report;
    expect(r.people, 2);
    expect(r.unsupported.keys, containsAll(['INDI._CUSTOM', 'INDI.OBJE', 'INDI.BIRT.AGE', '_LOC']));
    expect(r.examples['INDI._CUSTOM']!.single, '1 _CUSTOM hello world');
    expect(r.skippedMetadata['CHAN'], 1);
    final tree = await plan.write(db, treeName: 'Ada');
    final people = await (db.select(db.persons)..where((p) => p.treeId.equals(tree))).get();
    final ada = byName(people, 'Ada');
    expect(ada.lastName, 'King');
    expect(ada.birthName, 'Ada Lovelace');
    expect(ada.birthDate, 'EX:1815-12-10');
    expect(ada.notes, contains('First line of the note continues here\nand a second line'));
    expect(ada.notes, contains(unmappedNotesHeading));
    expect(ada.notes, contains('1 _CUSTOM hello world'));
    expect(ada.notes, contains('2 FILE ada.jpg'));
    expect(ada.notes, contains('2 AGE 0'));
    expect(ada.notes, isNot(contains('CHAN')));
    expect(ada.isLiving, isFalse); // born > 110 years ago
    expect(byName(people, 'Lord').isLiving, isFalse);
    final links = await (db.select(db.parentChildLinks)..where((l) => l.treeId.equals(tree))).get();
    expect(links.single.type, ParentType.adoptive);
    final t = await (db.select(db.familyTrees)..where((x) => x.id.equals(tree))).getSingle();
    expect(t.description, contains('0 @X1@ _LOC'));
    expect(t.description, contains('1 NAME Somewhere'));
  });

  test('privacy option exports living people as "Living"', () async {
    final tree = await seed();
    final data = await TreeExportData.load(db, tree, privacy: ExportPrivacy.public);
    final result = GedcomExporter(data, privacy: ExportPrivacy.public).build();
    expect(result.livingAnonymized, 3);
    expect(result.text, contains('1 NAME Living //'));
    expect(result.text, isNot(contains('Anna')));
    expect(result.text, isNot(contains('JUN 1950')));
    expect(result.text, contains('John Paul /Smith/'));
  });
}
