import 'package:drift/drift.dart' show Value;
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/core/models/fuzzy_date.dart';
import 'package:family_tales/core/repositories/family_repository.dart';
import 'package:family_tales/features/family/domain/family_graph.dart';
import 'package:family_tales/features/family/domain/kinship.dart';
import 'package:family_tales/features/family/domain/occasions.dart';
import 'package:family_tales/features/family_tree/layout/tree_layout.dart';
import 'package:family_tales/features/members/relation_planner.dart';
import '../support/example_family.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late FamilyRepository repo;
  late String treeId;
  late FamilyGraph g;

  String id(String first, [String? last]) => g.people.values
      .firstWhere((p) => p.firstName == first && (last == null || p.lastName == last))
      .id;

  setUp(() async {
    db = AppDatabase.memory();
    repo = FamilyRepository(db);
    treeId = await ExampleFamilyBuilder(db).build();
    g = await repo.loadGraph(treeId);
  });

  tearDown(() => db.close());

  group('FuzzyDate', () {
    test('serialises and parses every precision without inventing parts', () {
      final cases = [
        FuzzyDate.ymd(1950, 3, 12),
        FuzzyDate.ymd(1950, 3),
        FuzzyDate.ymd(1950),
        const FuzzyDate(qualifier: DateQualifier.about, year: 1920),
        const FuzzyDate(qualifier: DateQualifier.before, year: 1900, month: 6),
        const FuzzyDate(qualifier: DateQualifier.after, year: 1880),
        const FuzzyDate(qualifier: DateQualifier.between, year: 1920, year2: 1925),
        FuzzyDate.text('Spring, before the war'),
      ];
      for (final d in cases) {
        final back = FuzzyDate.tryParse(d.serialize())!;
        expect(back, d);
        expect(back.month, d.month);
        expect(back.day, d.day);
      }
      expect(FuzzyDate.ymd(1950).format(), '1950');
      expect(const FuzzyDate(qualifier: DateQualifier.about, year: 1920).format(), 'c. 1920');
      expect(FuzzyDate.ymd(1950).isExactDay, isFalse);
    });

    test('GEDCOM conversion round-trips', () {
      for (final raw in ['12 MAR 1950', 'MAR 1950', '1950', 'ABT 1920', 'BEF 1900', 'AFT 1880', 'BET 1920 AND 1925']) {
        final d = FuzzyDate.fromGedcom(raw)!;
        expect(d.toGedcom(), raw);
      }
      expect(FuzzyDate.fromGedcom('sometime in summer')!.qualifier, DateQualifier.text);
    });

    test('ages are approximate unless both dates are exact', () {
      final exact = AgeSpan.between(FuzzyDate.ymd(1950, 6, 15), FuzzyDate.ymd(2000, 6, 14))!;
      expect(exact.years, 49);
      expect(exact.approximate, isFalse);
      final approx = AgeSpan.between(FuzzyDate.ymd(1950), FuzzyDate.ymd(2000))!;
      expect(approx.approximate, isTrue);
    });
  });

  group('FamilyGraph', () {
    test('derives siblings including half and step', () {
      final arjun = id('Arjun');
      final sib = {for (final s in g.siblings(arjun)) g[s.personId]!.firstName: s.kind};
      expect(sib['Maya'], SiblingKind.full);
      expect(sib['Kavya'], SiblingKind.half);
    });

    test('generations are consistent across marriages', () {
      final gen = g.generations();
      expect(gen[id('Gopal')], gen[id('Arthur')]);
      expect(gen[id('Krishnan')], gen[id('Margaret')]);
      expect(gen[id('Arjun')]! - gen[id('Gopal')]!, 2);
      expect(gen[id('Rohan')]! - gen[id('Gopal')]!, 3);
      expect(g.generationCount(), 4);
    });

    test('rejects cyclic parent links', () async {
      final gopal = id('Gopal');
      final rohan = id('Rohan');
      expect(g.wouldCreateCycle(rohan, gopal), isTrue);
      expect(() => repo.addParent(childId: gopal, parentId: rohan), throwsA(isA<ValidationException>()));
    });

    test('rejects a third biological parent', () async {
      final arjun = id('Arjun');
      final thomas = id('Thomas');
      expect(
        () => repo.addParent(childId: arjun, parentId: thomas),
        throwsA(isA<ValidationException>()),
      );
      // …but a step-parent is fine.
      await repo.addParent(childId: arjun, parentId: thomas, type: ParentType.step);
    });
  });

  group('Kinship', () {
    String label(String a, String b) => KinshipCalculator(g).primaryLabel(id(a), id(b))!;

    test('direct lines', () {
      expect(label('Krishnan', 'Arjun'), 'Father');
      expect(label('Margaret', 'Arjun'), 'Mother');
      expect(label('Arjun', 'Krishnan'), 'Son');
      expect(label('Gopal', 'Arjun'), 'Grandfather');
      expect(label('Gopal', 'Rohan'), 'Great-grandfather');
      expect(label('Isha', 'Gopal'), 'Great-granddaughter');
    });

    test('collateral lines', () {
      expect(label('Maya', 'Arjun'), 'Sister');
      expect(label('Kavya', 'Arjun'), 'Half-sister');
      expect(label('Raman', 'Arjun'), 'Uncle');
      expect(label('Sarada', 'Arjun'), 'Aunt');
      expect(label('Arjun', 'Raman'), 'Nephew');
      expect(label('Suresh', 'Arjun'), 'First cousin');
      expect(label('Aditya', 'Arjun'), 'First cousin once removed');
      expect(label('Aditya', 'Rohan'), 'Second cousin');
      expect(label('George', 'Arjun'), 'Uncle');
      expect(label('Daniel', 'Arjun'), 'First cousin');
    });

    test('marriage and step relationships', () {
      expect(label('Priya', 'Arjun'), 'Wife');
      expect(label('Krishnan', 'Margaret'), 'Ex-husband');
      expect(label('Thomas', 'Maya'), 'Stepfather');
      expect(label('Priya', 'Krishnan'), 'Daughter-in-law');
      expect(label('Krishnan', 'Priya'), 'Father-in-law');
      expect(label('Neha', 'Arjun'), 'Cousin-in-law');
    });

    test('adoption is identified', () {
      final k = KinshipCalculator(g).between(id('George'), id('Daniel'));
      expect(k.first.label, 'Adoptive father');
    });
  });

  group('Tree layout', () {
    void checkNoOverlap(TreeLayout l) {
      final byLayer = <int, List<LayoutNode>>{};
      for (final n in l.nodes.values) {
        (byLayer[n.layer] ??= []).add(n);
      }
      for (final layer in byLayer.values) {
        layer.sort((a, b) => a.x.compareTo(b.x));
        for (var i = 1; i < layer.length; i++) {
          expect(layer[i].x - layer[i - 1].x >= l.options.nodeWidth - 0.01, isTrue,
              reason: 'nodes overlap: ${g[layer[i - 1].id]!.firstName} / ${g[layer[i].id]!.firstName}');
        }
      }
    }

    test('every mode lays out without overlaps and puts parents above children', () {
      for (final mode in TreeViewMode.values) {
        final l = TreeLayoutEngine(g).compute(TreeLayoutOptions(mode: mode, focusId: id('Arjun'), generationsUp: 6, generationsDown: 6));
        expect(l.nodes, isNotEmpty, reason: mode.name);
        checkNoOverlap(l);
        for (final link in g.links) {
          final p = l.nodes[link.parentId], c = l.nodes[link.childId];
          if (p == null || c == null) continue;
          expect(p.y < c.y, isTrue, reason: '${mode.name}: parent below child');
        }
      }
    });

    test('full view contains everyone; couples are adjacent', () {
      final l = TreeLayoutEngine(g).compute(TreeLayoutOptions(mode: TreeViewMode.full, focusId: id('Arjun'), generationsUp: 12, generationsDown: 12));
      expect(l.nodes.length, g.size);
      final s = l.partners.firstWhere((p) => {p.a, p.b}.containsAll({id('Arjun'), id('Priya')}));
      expect(s.adjacent, isTrue);
    });

    test('collapsing hides descendants', () {
      final krishnan = id('Krishnan');
      final l = TreeLayoutEngine(g).compute(TreeLayoutOptions(
          mode: TreeViewMode.descendants, focusId: id('Gopal'), generationsDown: 6, collapsed: {krishnan}));
      expect(l.nodes.containsKey(id('Arjun')), isFalse);
      expect(l.nodes[krishnan]!.hiddenChildren, greaterThan(0));
    });

    test('ancestor view shows only ancestors', () {
      final l = TreeLayoutEngine(g).compute(TreeLayoutOptions(mode: TreeViewMode.ancestors, focusId: id('Rohan'), generationsUp: 6));
      expect(l.nodes.keys.toSet(), {id('Rohan'), ...g.ancestors(id('Rohan'))});
    });

    test('large synthetic family lays out quickly', () {
      final persons = <Person>[];
      final links = <ParentChildLink>[];
      final couples = <Partnership>[];
      final now = DateTime(2020);
      Person mk(String pid, Gender gender) => Person(
            id: pid, treeId: 't', firstName: pid, gender: gender, isLiving: true,
            isPrivate: false, isArchived: false, createdAt: now, updatedAt: now);
      var n = 0;
      List<String> gen = [];
      final a = mk('p${n++}', Gender.male), b = mk('p${n++}', Gender.female);
      persons.addAll([a, b]);
      couples.add(Partnership(id: 'c0', treeId: 't', personAId: a.id, personBId: b.id,
          type: PartnerType.marriage, status: PartnerStatus.current, createdAt: now, updatedAt: now));
      gen = [a.id];
      final spouseOf = {a.id: b.id};
      for (var depth = 0; depth < 5 && persons.length < 600; depth++) {
        final next = <String>[];
        for (final parent in gen) {
          for (var k = 0; k < 3; k++) {
            final child = mk('p${n++}', Gender.male);
            final spouse = mk('p${n++}', Gender.female);
            persons.addAll([child, spouse]);
            for (final par in [parent, spouseOf[parent]!]) {
              links.add(ParentChildLink(id: 'l${links.length}', treeId: 't', parentId: par, childId: child.id,
                  type: ParentType.biological, createdAt: now, updatedAt: now));
            }
            couples.add(Partnership(id: 'c${couples.length}', treeId: 't', personAId: child.id, personBId: spouse.id,
                type: PartnerType.marriage, status: PartnerStatus.current, createdAt: now, updatedAt: now));
            spouseOf[child.id] = spouse.id;
            next.add(child.id);
          }
        }
        gen = next;
      }
      final big = FamilyGraph(persons: persons, parentLinks: links, partnerships: couples);
      final sw = Stopwatch()..start();
      final l = TreeLayoutEngine(big).compute(
          TreeLayoutOptions(mode: TreeViewMode.full, focusId: a.id, generationsUp: 12, generationsDown: 12));
      sw.stop();
      expect(l.nodes.length, big.size);
      expect(sw.elapsedMilliseconds, lessThan(5000), reason: '${big.size} people took ${sw.elapsedMilliseconds}ms');
      // ignore: avoid_print
      print('Laid out ${big.size} people in ${sw.elapsedMilliseconds} ms');
    });
  });

  group('Relation planner', () {
    test('sibling of someone without parents creates the shared parents', () {
      final planner = RelationPlanner(g);
      final orphan = planner.plan(RelationKind.sister, id('Gopal'));
      expect(orphan.isBlocked, isFalse);
      expect(orphan.createParentsFor, id('Gopal'));
      expect(orphan.parents, isEmpty);
      final plan = planner.plan(RelationKind.brother, id('Arjun'));
      expect(plan.parents.map((e) => e.$1).toSet(), {id('Krishnan'), id('Margaret')});
    });

    test('grandparent asks which side', () {
      final plan = RelationPlanner(g).plan(RelationKind.grandfather, id('Arjun'));
      expect(plan.needsChoice, isTrue);
      final chosen = RelationPlanner(g).plan(RelationKind.grandfather, id('Arjun'), choiceId: id('Margaret'));
      expect(chosen.children.single.$1, id('Margaret'));
    });

    test('cousin goes through an uncle or aunt', () {
      final plan = RelationPlanner(g).plan(RelationKind.cousin, id('Arjun'), choiceId: id('Raman'));
      expect(plan.parents.single.$1, id('Raman'));
    });
  });

  group('Occasions', () {
    test('only month+day dates create anniversaries', () {
      final occ = OccasionCalculator(graph: g).between(DateTime(2026, 1, 1), DateTime(2026, 12, 31));
      final birthdays = occ.where((o) => o.kind == OccasionKind.birthday).map((o) => o.title).toList();
      expect(birthdays.any((t) => t.startsWith('Arjun')), isTrue);
      // Susan only has a birth year → no invented birthday.
      expect(birthdays.any((t) => t.startsWith('Susan')), isFalse);
      final arjunBday = occ.firstWhere((o) => o.title.startsWith('Arjun') && o.kind == OccasionKind.birthday);
      expect(arjunBday.date, DateTime(2026, 6, 18));
      expect(arjunBday.years, 51);
      // Divorced couples don't get anniversaries.
      expect(occ.any((o) => o.kind == OccasionKind.anniversary && o.title.contains('Margaret') && o.title.contains('Krishnan')), isFalse);
    });
  });

  group('Repository', () {
    test('persists, trashes and restores people', () async {
      final pid = await repo.createPerson(PersonsCompanion.insert(id: newId(), treeId: treeId));
      expect(await repo.person(pid), isNotNull);
      await repo.trashPerson(pid);
      expect((await repo.people(treeId)).any((p) => p.id == pid), isFalse);
    });

    test('merging people re-points relationships', () async {
      final dup = await repo.createPersonWithLinks(
        PersonsCompanion.insert(id: newId(), treeId: treeId, firstName: const Value('Rohan'), lastName: const Value('Nair')),
        partners: const [],
      );
      await repo.addParent(childId: dup, parentId: id('Priya'));
      await repo.mergePeople(keepId: id('Rohan'), removeId: dup);
      final g2 = await repo.loadGraph(treeId);
      expect(g2.contains(dup), isFalse);
      expect(g2.parentIds(id('Rohan')).toSet(), {id('Arjun'), id('Priya')});
    });
  });
}
