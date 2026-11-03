import 'package:drift/drift.dart' show Value;
import 'package:family_tales/app/settings.dart';
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/core/repositories/family_repository.dart';
import 'package:family_tales/features/family/domain/family_graph.dart';
import 'package:family_tales/features/family_tree/layout/tree_layout.dart';
import 'package:family_tales/features/family_tree/widgets/tree_controls.dart';
import 'package:family_tales/features/members/relation_planner.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';

import '../support/example_family.dart';

void main() {
  late AppDatabase db;
  late FamilyRepository repo;
  late String treeId;
  late FamilyGraph g;

  String id(String first) => g.people.values.firstWhere((p) => p.firstName == first).id;

  setUp(() async {
    db = AppDatabase.memory();
    repo = FamilyRepository(db);
    treeId = await ExampleFamilyBuilder(db).build();
    g = await repo.loadGraph(treeId);
  });

  tearDown(() => db.close());

  group('RelationPlanner – every relation for every person', () {
    test('never throws and never links a person to themselves', () {
      final planner = RelationPlanner(g);
      for (final anchor in g.people.keys) {
        for (final kind in RelationKind.values) {
          final plan = planner.plan(kind, anchor);
          final choices = plan.choices.isEmpty ? <String?>[null] : plan.choices;
          for (final choice in choices) {
            final p = planner.plan(kind, anchor, choiceId: choice);
            // The new person is never its own parent/child/partner.
            expect(p.parents.where((e) => e.$1 == anchor && kind.group == 'Parents'), isEmpty);
            if (!p.isBlocked && !p.needsChoice) {
              final edges = p.parents.length + p.children.length + p.partners.length;
              expect(edges > 0 || p.createParentsFor != null, isTrue,
                  reason: '${kind.name} of ${g[anchor]!.displayName} produced no connection');
            }
          }
        }
      }
    });

    test('parent kinds make the anchor their child with the right type', () {
      final planner = RelationPlanner(g);
      final a = id('Arjun');
      expect(planner.plan(RelationKind.father, a).children, [(a, ParentType.biological)]);
      expect(planner.plan(RelationKind.stepParent, a).children, [(a, ParentType.step)]);
      expect(planner.plan(RelationKind.adoptiveParent, a).children, [(a, ParentType.adoptive)]);
      expect(planner.plan(RelationKind.fosterParent, a).children, [(a, ParentType.foster)]);
      expect(planner.plan(RelationKind.guardian, a).children, [(a, ParentType.guardian)]);
    });

    test('partners connect to the anchor only', () {
      final plan = RelationPlanner(g).plan(RelationKind.wife, id('Arjun'));
      expect(plan.partners, [id('Arjun')]);
      expect(plan.parents, isEmpty);
      expect(plan.children, isEmpty);
    });

    test('children can take the chosen co-parent', () {
      final a = id('Arjun');
      final planner = RelationPlanner(g);
      final partner = g.partnerIds(a).first;
      final plan = planner.plan(RelationKind.son, a, coParentId: partner);
      expect(plan.parents.map((e) => e.$1), [a, partner]);
      expect(plan.coParentChoices, contains(partner));
      // A co-parent equal to the anchor is ignored.
      expect(planner.plan(RelationKind.son, a, coParentId: a).parents, [(a, ParentType.biological)]);
      // A step-child's other parent is their biological parent.
      expect(planner.plan(RelationKind.stepChild, a, coParentId: partner).parents,
          [(a, ParentType.step), (partner, ParentType.biological)]);
    });

    test('siblings share all of the anchor’s parents', () {
      final a = id('Arjun');
      final plan = RelationPlanner(g).plan(RelationKind.sibling, a);
      expect(plan.parents.map((e) => e.$1).toSet(), g.kinParents(a).toSet());
      expect(plan.createParentsFor, isNull);
    });

    test('a sibling of someone with no parents is allowed (shared parents created)', () {
      final gopal = id('Gopal');
      expect(g.parentIds(gopal), isEmpty);
      for (final k in [RelationKind.brother, RelationKind.sister, RelationKind.sibling]) {
        final plan = RelationPlanner(g).plan(k, gopal);
        expect(plan.isBlocked, isFalse);
        expect(plan.createParentsFor, gopal);
      }
    });

    test('grandparents need parents first; grandchildren need children first', () {
      final planner = RelationPlanner(g);
      expect(planner.plan(RelationKind.grandfather, id('Gopal')).isBlocked, isTrue);
      expect(planner.plan(RelationKind.grandchild, id('Isha')).isBlocked, isTrue);
      expect(planner.plan(RelationKind.nephew, id('Gopal')).isBlocked, isTrue);
    });

    test('grandparent asks which side when there are two parents', () {
      final a = id('Arjun');
      final planner = RelationPlanner(g);
      final plan = planner.plan(RelationKind.grandmother, a);
      if (g.parentIds(a, lineageOnly: true).length > 1) {
        expect(plan.needsChoice, isTrue);
        final chosen = plan.choices.first;
        expect(planner.plan(RelationKind.grandmother, a, choiceId: chosen).children,
            [(chosen, ParentType.biological)]);
      }
    });
  });

  group('Shared parent creation (repository level)', () {
    test('linking a new sibling through a newly created parent makes them siblings', () async {
      final gopal = id('Gopal');
      final parent = await repo.createPerson(
          PersonsCompanion.insert(id: 'p-new', treeId: treeId, firstName: const Value('Unknown parent')));
      final sister = await repo.createPerson(
          PersonsCompanion.insert(id: 's-new', treeId: treeId, firstName: const Value('Janaki')));
      await repo.addParent(childId: gopal, parentId: parent);
      await repo.addParent(childId: sister, parentId: parent);
      final g2 = await repo.loadGraph(treeId);
      expect(g2.siblings(gopal).map((s) => s.personId), contains(sister));
      expect(g2.siblings(sister).map((s) => s.personId), contains(gopal));
    });
  });

  group('Generation filter depth', () {
    test('matches the data around the focus person', () {
      final gens = g.generations();
      for (final focus in g.people.keys) {
        final d = generationDepth(g, focus);
        expect(d.up, greaterThanOrEqualTo(0));
        expect(d.down, greaterThanOrEqualTo(0));
        expect(d.total, d.up + d.down + 1);
        expect(d.total, lessThanOrEqualTo(g.generationCount()));
        // Someone exactly `up` generations above exists in the component.
        final comp = g.components().firstWhere((c) => c.contains(focus));
        expect(comp.any((x) => gens[x] == gens[focus]! - d.up), isTrue);
        expect(comp.any((x) => gens[x] == gens[focus]! + d.down), isTrue);
      }
    });

    test('an unknown focus or empty tree gives zero depth', () {
      expect(generationDepth(g, 'missing').total, 0);
      expect(generationDepth(FamilyGraph.empty(), 'x').max, 0);
    });

    test('limiting generations shrinks the layout and "all" shows everyone', () {
      final focus = id('Arjun');
      final d = generationDepth(g, focus);
      expect(d.max, greaterThan(1));
      final engine = TreeLayoutEngine(g);
      final gens = g.generations();
      int shown(int n) => {
            for (final x in engine
                .compute(TreeLayoutOptions(
                    mode: TreeViewMode.full, focusId: focus, generationsUp: n, generationsDown: n))
                .nodes
                .keys)
              gens[x]
          }.length;
      expect(shown(1), lessThanOrEqualTo(3));
      expect(shown(99), d.total);
      for (final mode in TreeViewMode.values) {
        final all = engine.compute(
            TreeLayoutOptions(mode: mode, focusId: focus, generationsUp: 99, generationsDown: 99));
        final one = engine.compute(
            TreeLayoutOptions(mode: mode, focusId: focus, generationsUp: 1, generationsDown: 1));
        expect(one.nodes.length, lessThanOrEqualTo(all.nodes.length), reason: mode.name);
      }
    });

    test('partners are drawn further apart than before (visible couple line)', () {
      const o = TreeLayoutOptions(mode: TreeViewMode.full);
      expect(o.partnerGap, greaterThanOrEqualTo(40));
      const c = TreeLayoutOptions(mode: TreeViewMode.compact);
      expect(c.partnerGap, greaterThanOrEqualTo(24));
    });
  });

  group('AppPrefs', () {
    test('defaults: system theme and full screen', () {
      const p = AppPrefs();
      expect(p.themeMode, ThemeMode.system);
      expect(p.fullScreen, isTrue);
    });

    test('round-trips through its stored map', () {
      final p = const AppPrefs().copyWith(themeMode: ThemeMode.light, fullScreen: false, reduceMotion: true);
      final back = AppPrefs.fromMap(p.toMap());
      expect(back.themeMode, ThemeMode.light);
      expect(back.fullScreen, isFalse);
      expect(back.reduceMotion, isTrue);
      expect(back.toMap(), p.toMap());
    });

    test('old installs that stored dark mode move to system default once', () {
      final legacy = Map.of(const AppPrefs().copyWith(themeMode: ThemeMode.dark).toMap())..remove('themeDefaultV2');
      expect(AppPrefs.fromMap(legacy).themeMode, ThemeMode.system);
      final chosen = const AppPrefs().copyWith(themeMode: ThemeMode.dark).toMap();
      expect(AppPrefs.fromMap(chosen).themeMode, ThemeMode.dark);
    });

    test('garbage values fall back to defaults instead of crashing', () {
      final p = AppPrefs.fromMap({'themeMode': 'purple', 'fullScreen': 'maybe', 'treeGenerations': 'x', 'themeDefaultV2': 'true'});
      expect(p.themeMode, ThemeMode.system);
      expect(p.fullScreen, isTrue);
      expect(p.treeGenerations, 3);
    });
  });
}
