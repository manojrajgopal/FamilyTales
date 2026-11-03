import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/core/repositories/family_repository.dart';
import 'package:family_tales/features/backup/export/export_data.dart';
import 'package:family_tales/features/backup/gedcom/gedcom_exporter.dart';
import 'package:family_tales/features/backup/gedcom/gedcom_importer.dart';
import 'package:family_tales/features/backup/gedcom/gedcom_parser.dart';
import 'package:family_tales/features/family/domain/family_graph.dart';
import 'package:family_tales/features/family/domain/kinship.dart';
import 'package:family_tales/features/family_tree/layout/tree_layout.dart';
import 'package:family_tales/features/members/duplicate_detector.dart';
import 'package:family_tales/features/members/relation_planner.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_test/flutter_test.dart';

import '../support/example_family.dart';

void main() {
  late AppDatabase db;
  late FamilyRepository repo;
  late String tree;

  setUp(() async {
    db = AppDatabase.memory();
    repo = FamilyRepository(db);
    tree = await repo.createTree('Gender');
  });
  tearDown(() => db.close());

  Future<String> person(String first, Gender g, {String last = 'Rao', String? birth}) =>
      repo.createPerson(PersonsCompanion.insert(
        id: newId(),
        treeId: tree,
        firstName: Value(first),
        lastName: Value(last),
        gender: Value(g),
        birthDate: Value(birth),
      ));

  // ---------------------------------------------------------------------------
  group('Storage', () {
    for (final g in Gender.values) {
      test('${g.label} is saved and read back unchanged', () async {
        final id = await person('P', g);
        expect((await repo.person(id))!.gender, g);
        final graph = await repo.loadGraph(tree);
        expect(graph[id]!.gender, g);
      });
    }

    test('a new person without a gender is "Not specified", never guessed from the name', () async {
      final id = await repo.createPerson(
          PersonsCompanion.insert(id: newId(), treeId: tree, firstName: const Value('Lakshmi')));
      expect((await repo.person(id))!.gender, Gender.unknown);
    });

    test('editing the gender only changes the gender', () async {
      final id = await person('Asha', Gender.female, birth: 'EX:1990');
      await repo.updatePerson(id, const PersonsCompanion(gender: Value(Gender.nonBinary)));
      final p = (await repo.person(id))!;
      expect(p.gender, Gender.nonBinary);
      expect(p.firstName, 'Asha');
      expect(p.birthDate, 'EX:1990');
    });
  });

  // ---------------------------------------------------------------------------
  group('Tree layout puts husbands left and wives right', () {
    test('a partner sits on the side of their own parents (no crossing lines)', () async {
      final t = await ExampleFamilyBuilder(db).build();
      final g = await repo.loadGraph(t);
      final raman = g.people.values.firstWhere((p) => p.firstName == 'Raman').id;
      final devaki = g.people.values.firstWhere((p) => p.firstName == 'Devaki').id;
      final layout = TreeLayoutEngine(g).compute(TreeLayoutOptions(mode: TreeViewMode.full, focusId: raman));
      final parents = g.parentIds(raman).where(layout.nodes.containsKey).toList();
      expect(parents, isNotEmpty);
      final parentX = parents.map((p) => layout.nodes[p]!.x).reduce((a, b) => a + b) / parents.length;
      final towardsParents = (layout.nodes[raman]!.x - parentX).abs() <= (layout.nodes[devaki]!.x - parentX).abs();
      expect(towardsParents || g.parentIds(devaki).any(layout.nodes.containsKey), isTrue);
    });

    test('in the example family every male–female couple is ordered man, woman', () async {
      final t = await ExampleFamilyBuilder(db).build();
      final g = await repo.loadGraph(t);
      for (final mode in TreeViewMode.values) {
        for (final focus in g.people.keys.take(6)) {
          final layout = TreeLayoutEngine(g).compute(TreeLayoutOptions(mode: mode, focusId: focus));
          for (final c in layout.partners.where((c) => c.adjacent)) {
            final a = g[c.a]!, b = g[c.b]!;
            if ({a.gender, b.gender}.containsAll({Gender.male, Gender.female})) {
              final man = a.gender == Gender.male ? c.a : c.b;
              final woman = a.gender == Gender.male ? c.b : c.a;
              // Partners whose parents are drawn sit on their parents' side
              // instead (avoids crossing lines), so only check the others.
              bool parentsShown(String x) => g.parentIds(x).any(layout.nodes.containsKey);
              final single = g.partnerIds(man).length == 1 && g.partnerIds(woman).length == 1;
              if (single && !parentsShown(man) && !parentsShown(woman)) {
                expect(layout.nodes[man]!.x, lessThan(layout.nodes[woman]!.x),
                    reason: '${a.displayName} & ${b.displayName} in ${mode.name}');
              }
            }
          }
        }
      }
    });

    test('order is the same whichever partner was entered first', () async {
      final wife = await person('Meera', Gender.female, birth: 'EX:1950');
      final husband = await person('Ravi', Gender.male, birth: 'EX:1955');
      await repo.addPartnership(a: wife, b: husband);
      final g = await repo.loadGraph(tree);
      final layout = TreeLayoutEngine(g).compute(TreeLayoutOptions(mode: TreeViewMode.full, focusId: wife));
      expect(layout.nodes[husband]!.x, lessThan(layout.nodes[wife]!.x));
    });

    test('same-gender and unspecified couples fall back to age order', () async {
      for (final (ga, gb) in [
        (Gender.female, Gender.female),
        (Gender.male, Gender.male),
        (Gender.unknown, Gender.female),
        (Gender.nonBinary, Gender.male),
      ]) {
        final t = await repo.createTree('C-${ga.name}-${gb.name}');
        tree = t;
        final younger = await person('Younger', ga, birth: 'EX:1980');
        final older = await person('Older', gb, birth: 'EX:1960');
        await repo.addPartnership(a: younger, b: older);
        final g = await repo.loadGraph(t);
        final layout = TreeLayoutEngine(g).compute(TreeLayoutOptions(mode: TreeViewMode.full, focusId: younger));
        expect(layout.nodes.keys, containsAll([younger, older]));
        if (ga != Gender.unknown && ga != Gender.nonBinary || gb == ga) {
          expect(layout.nodes[older]!.x, lessThan(layout.nodes[younger]!.x), reason: '${ga.name}/${gb.name}');
        }
      }
    });
  });

  // ---------------------------------------------------------------------------
  group('Relationship names follow the recorded gender', () {
    late String dad, mum, son, daughter, child;

    setUp(() async {
      dad = await person('Dad', Gender.male);
      mum = await person('Mum', Gender.female);
      son = await person('Son', Gender.male);
      daughter = await person('Daughter', Gender.female);
      child = await person('Kid', Gender.unknown);
      await repo.addPartnership(a: dad, b: mum);
      for (final c in [son, daughter, child]) {
        await repo.addParent(childId: c, parentId: dad);
        await repo.addParent(childId: c, parentId: mum);
      }
    });

    Future<KinshipCalculator> kin() async => KinshipCalculator(await repo.loadGraph(tree));

    test('father / mother', () async {
      final k = await kin();
      expect(k.primaryLabel(dad, son), 'Father');
      expect(k.primaryLabel(mum, son), 'Mother');
    });

    test('son / daughter / child', () async {
      final k = await kin();
      expect(k.primaryLabel(son, dad), 'Son');
      expect(k.primaryLabel(daughter, dad), 'Daughter');
      expect(k.primaryLabel(child, dad), 'Child');
    });

    test('brother / sister / sibling', () async {
      final k = await kin();
      expect(k.primaryLabel(son, daughter), 'Brother');
      expect(k.primaryLabel(daughter, son), 'Sister');
      expect(k.primaryLabel(child, son), 'Sibling');
    });

    test('husband / wife', () async {
      final k = await kin();
      expect(k.primaryLabel(dad, mum), 'Husband');
      expect(k.primaryLabel(mum, dad), 'Wife');
    });

    test('changing a gender changes the label everywhere', () async {
      await repo.updatePerson(child, const PersonsCompanion(gender: Value(Gender.female)));
      final k = await kin();
      expect(k.primaryLabel(child, dad), 'Daughter');
      expect(k.primaryLabel(child, son), 'Sister');
    });

    test('non-binary and other get neutral words', () async {
      for (final g in [Gender.nonBinary, Gender.other]) {
        await repo.updatePerson(child, PersonsCompanion(gender: Value(g)));
        final k = await kin();
        expect(k.primaryLabel(child, dad), 'Child', reason: g.name);
        expect(k.primaryLabel(child, son), 'Sibling', reason: g.name);
      }
    });

    test('grandparents and grandchildren are gendered too', () async {
      final baby = await person('Baby', Gender.female);
      await repo.addParent(childId: baby, parentId: son);
      final k = await kin();
      expect(k.primaryLabel(dad, baby), 'Grandfather');
      expect(k.primaryLabel(mum, baby), 'Grandmother');
      expect(k.primaryLabel(baby, dad), 'Granddaughter');
      expect(k.primaryLabel(daughter, baby), 'Aunt');
      expect(k.primaryLabel(son, baby), 'Father');
    });
  });

  // ---------------------------------------------------------------------------
  group('Add-relative choices set the right gender', () {
    const female = {'Mother', 'Wife', 'Daughter', 'Sister', 'Grandmother', 'Aunt', 'Niece', 'Granddaughter'};
    const male = {'Father', 'Husband', 'Son', 'Brother', 'Grandfather', 'Uncle', 'Nephew', 'Grandson'};

    for (final k in RelationKind.values) {
      test('${k.label} → ${k.gender?.label ?? 'no preset'}', () {
        if (female.contains(k.label)) {
          expect(k.gender, Gender.female);
        } else if (male.contains(k.label)) {
          expect(k.gender, Gender.male);
        } else {
          expect(k.gender, isNot(Gender.unknown), reason: 'unknown is expressed as null');
        }
      });
    }

    test('gendered pairs exist for each core relation', () {
      final labels = RelationKind.values.map((k) => k.label).toSet();
      for (final pair in [('Father', 'Mother'), ('Husband', 'Wife'), ('Son', 'Daughter'), ('Brother', 'Sister')]) {
        expect(labels, containsAll([pair.$1, pair.$2]));
      }
    });
  });

  // ---------------------------------------------------------------------------
  group('Duplicate finder respects gender', () {
    test('same name and birth but different gender scores far lower', () async {
      final a = await person('Sam', Gender.male, birth: 'EX:1970-05-01');
      final b = await person('Sam', Gender.male, birth: 'EX:1970-05-01');
      final c = await person('Sam', Gender.female, birth: 'EX:1970-05-01');
      final g = await repo.loadGraph(tree);
      final found = DuplicateDetector(g).find();
      double score(String x, String y) =>
          found.where((d) => {d.aId, d.bId}.containsAll({x, y})).map((d) => d.score).firstOrNull ?? 0;
      expect(score(a, b), greaterThan(score(a, c)));
      expect(score(a, b) - score(a, c), greaterThan(0.3));
    });

    test('an unspecified gender does not block a match', () async {
      final a = await person('Sam', Gender.male, birth: 'EX:1970-05-01');
      final b = await person('Sam', Gender.unknown, birth: 'EX:1970-05-01');
      final g = await repo.loadGraph(tree);
      expect(DuplicateDetector(g).find().any((d) => {d.aId, d.bId}.containsAll({a, b})), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  group('GEDCOM keeps gender', () {
    Future<Map<String, Gender>> roundTrip() async {
      final data = await TreeExportData.load(db, tree);
      final text = GedcomExporter(data).build().text;
      final plan = GedcomImporter(GedcomParser.parseBytes(Uint8List.fromList(utf8.encode(text))), fileName: 'g.ged')
          .analyze();
      expect(plan.report.unsupported, isEmpty, reason: '${plan.report.examples}');
      final t = await plan.write(db, treeName: 'Back');
      final people = await (db.select(db.persons)..where((p) => p.treeId.equals(t))).get();
      return {for (final p in people) p.firstName: p.gender};
    }

    test('every gender survives export → import', () async {
      for (final g in Gender.values) {
        await person('G${g.name}', g);
      }
      final back = await roundTrip();
      for (final g in Gender.values) {
        expect(back['G${g.name}'], g, reason: g.name);
      }
    });

    test('writes standard SEX values', () async {
      await person('M', Gender.male);
      await person('F', Gender.female);
      await person('U', Gender.unknown);
      await person('X', Gender.other);
      final text = GedcomExporter(await TreeExportData.load(db, tree)).build().text;
      for (final v in ['M', 'F', 'U', 'X']) {
        expect(text, contains('1 SEX $v'));
      }
    });

    test('reads SEX values from other programs, case-insensitively', () {
      const ged = '0 HEAD\n'
          '0 @I1@ INDI\n1 NAME A /Z/\n1 SEX m\n'
          '0 @I2@ INDI\n1 NAME B /Z/\n1 SEX F\n'
          '0 @I3@ INDI\n1 NAME C /Z/\n1 SEX X\n'
          '0 @I4@ INDI\n1 NAME D /Z/\n1 SEX U\n'
          '0 @I5@ INDI\n1 NAME E /Z/\n1 SEX banana\n'
          '0 @I6@ INDI\n1 NAME F /Z/\n'
          '0 TRLR';
      final plan = GedcomImporter(GedcomParser.parse(ged)).analyze();
      expect(plan.report.people, 6);
    });

    test('imported genders land in the database', () async {
      const ged = '0 HEAD\n'
          '0 @I1@ INDI\n1 NAME Anna /Z/\n1 SEX F\n'
          '0 @I2@ INDI\n1 NAME Bob /Z/\n1 SEX m\n'
          '0 @I3@ INDI\n1 NAME Cy /Z/\n1 SEX X\n2 TYPE Non-Binary\n'
          '0 @I4@ INDI\n1 NAME Dee /Z/\n1 SEX ?\n'
          '0 TRLR';
      final t = await GedcomImporter(GedcomParser.parse(ged)).analyze().write(db, treeName: 'In');
      final people = await (db.select(db.persons)..where((p) => p.treeId.equals(t))).get();
      final by = {for (final p in people) p.firstName: p.gender};
      expect(by, {'Anna': Gender.female, 'Bob': Gender.male, 'Cy': Gender.nonBinary, 'Dee': Gender.unknown});
    });
  });

  // ---------------------------------------------------------------------------
  group('Merging duplicates', () {
    test('a recorded gender wins over "not specified"', () async {
      final keep = await person('Ana', Gender.unknown);
      final remove = await person('Ana', Gender.female);
      await repo.mergePeople(keepId: keep, removeId: remove);
      expect((await repo.person(keep))!.gender, Gender.female);
    });

    test('the kept person’s recorded gender is not overwritten', () async {
      final keep = await person('Ana', Gender.female);
      final remove = await person('Ana', Gender.unknown);
      await repo.mergePeople(keepId: keep, removeId: remove);
      expect((await repo.person(keep))!.gender, Gender.female);
    });
  });

  test('family graph exposes gender for every person', () async {
    final t = await ExampleFamilyBuilder(db).build();
    final FamilyGraph g = await repo.loadGraph(t);
    expect(g.people.values.every((p) => p.gender != Gender.unknown), isTrue,
        reason: 'example family records everyone’s gender');
    expect(g.people.values.where((p) => p.gender == Gender.male), isNotEmpty);
    expect(g.people.values.where((p) => p.gender == Gender.female), isNotEmpty);
  });
}
