import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:family_tales/app/providers.dart';
import 'package:family_tales/app/settings.dart';
import 'package:family_tales/app/theme/app_theme.dart';
import 'package:family_tales/app/theme/tokens.dart';
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/repositories/family_repository.dart';
import 'package:family_tales/core/services/app_paths.dart';
import 'package:family_tales/features/family/domain/family_graph.dart';
import 'package:family_tales/features/family_tree/family_tree_screen.dart';
import 'package:family_tales/features/family_tree/layout/tree_layout.dart';
import 'package:family_tales/features/family_tree/widgets/tree_controls.dart';
import 'package:family_tales/features/family_tree/widgets/tree_node.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/layout_harness.dart';

late AppDatabase _db;
late FamilyRepository _repo;

/// Screens to check: name, physical size, device pixel ratio.
const _screens = [
  ('small Android phone', Size(720, 1280), 2.0),
  ('large Android phone', Size(1440, 3120), 3.5),
  ('iPhone', Size(1170, 2532), 3.0),
  ('tablet', Size(2048, 2732), 2.0),
  ('phone in landscape', Size(2400, 1080), 2.625),
];

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 120));
  }
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _open(WidgetTester tester, String tree, {Size size = const Size(1080, 2400), double dpr = 2.625, String? focus}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(_db),
      initialPrefsProvider.overrideWithValue(
          AppPrefs(onboardingDone: true, activeTreeId: tree, treeMode: TreeViewMode.full, treeGenerations: 12)),
    ],
    child: MaterialApp(theme: AppTheme.build(dark: false, accent: AccentChoice.mint), home: FamilyTreeScreen(focusId: focus)),
  ));
  await _settle(tester);
}

Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _tool(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

double _scale(WidgetTester tester) =>
    tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!.value.entry(0, 0);

Rect _screen(WidgetTester tester) => Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;

/// On-screen rectangles of every tree card that is built.
Map<String, Rect> _cards(WidgetTester tester) => {
      for (final e in find.byType(TreeNodeCard).evaluate())
        (e.widget as TreeNodeCard).person.id: tester.getRect(find.byWidget(e.widget)),
    };

Future<(String, FamilyGraph)> _save(FamilyGraph g, String name) async {
  final tree = await saveFamily(_repo, g, name);
  return (tree, await _repo.loadGraph(tree));
}

void main() {
  setUpAll(() {
    AppPaths.initForTest(Directory.systemTemp.createTempSync('ft_canvas'));
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() {
    _db = AppDatabase.memory();
    _repo = FamilyRepository(_db);
  });

  tearDown(() => _db.close());

  group('Fit to screen on different devices', () {
    for (final (name, size, dpr) in _screens) {
      testWidgets('$name: every card ends up on screen and readable when zoomed', (tester) async {
        final (tree, g) = (await tester.runAsync(() => _save(randomFamily(5, size: 45), 'Fit')))!;
        await _open(tester, tree, size: size, dpr: dpr);
        expect(tester.takeException(), isNull);

        await _tool(tester, 'Fit whole tree to screen');
        final screen = _screen(tester).inflate(1);
        final cards = _cards(tester);
        expect(cards.keys.toSet(), g.people.keys.toSet(), reason: 'everyone is in view after fitting');
        for (final MapEntry(key: id, value: r) in cards.entries) {
          expect(screen.contains(r.topLeft) && screen.contains(r.bottomRight), isTrue, reason: '${g[id]!.firstName} at $r');
        }
        // ...and none is hidden under the floating zoom toolbar.
        final bar = tester.getRect(find.byType(TreeToolbar));
        for (final MapEntry(key: id, value: r) in cards.entries) {
          expect(r.deflate(1).overlaps(bar), isFalse, reason: '${g[id]!.firstName} under the toolbar');
        }
        // Cards never overlap on screen.
        final rects = cards.values.toList();
        for (var i = 0; i < rects.length; i++) {
          for (var j = i + 1; j < rects.length; j++) {
            final o = rects[i].deflate(0.5).intersect(rects[j].deflate(0.5));
            expect(o.width > 0 && o.height > 0, isFalse, reason: 'overlapping cards');
          }
        }

        // Zoom in and out around the centre, then reset.
        final fit = _scale(tester);
        await _tool(tester, 'Zoom in');
        expect(_scale(tester), closeTo(fit * 1.3, 0.01));
        await _tool(tester, 'Zoom out');
        expect(_scale(tester), closeTo(fit, 0.01));
        await _tool(tester, 'Zoom out');
        expect(_scale(tester), lessThan(fit));
        await _tool(tester, 'Reset position');
        expect(tester.takeException(), isNull);
        await _done(tester);
      });
    }

    testWidgets('a 300-person tree fits completely, below the usual zoom limit', (tester) async {
      final (tree, g) = (await tester.runAsync(() => _save(randomFamily(9, size: 300), 'Big')))!;
      await _open(tester, tree);
      await _tool(tester, 'Fit whole tree to screen');
      expect(_scale(tester), lessThan(0.12));
      final screen = _screen(tester).inflate(1);
      final cards = _cards(tester);
      expect(cards.length, g.size);
      for (final r in cards.values) {
        expect(screen.contains(r.topLeft) && screen.contains(r.bottomRight), isTrue);
      }
      expect(tester.takeException(), isNull);
      await _done(tester);
    });

    testWidgets('when zoomed in only nearby cards are built (large trees stay fast)', (tester) async {
      final (tree, g) = (await tester.runAsync(() => _save(randomFamily(9, size: 300), 'Big')))!;
      await _open(tester, tree, focus: g.people.keys.first);
      await _tool(tester, 'Fit whole tree to screen');
      for (var i = 0; i < 8; i++) {
        await _tool(tester, 'Zoom in');
      }
      expect(find.byType(TreeNodeCard).evaluate().length, lessThan(g.size ~/ 3));
      await _done(tester);
    });
  });

  group('The tree reorganises itself after changes', () {
    testWidgets('adding relatives keeps the selected person still on screen', (tester) async {
      final (tree, g) = (await tester.runAsync(() => _save(randomFamily(2, size: 40), 'Edit')))!;
      // Someone in the middle generation with a parent.
      final who = g.people.keys.firstWhere((id) => g.parentIds(id).isNotEmpty && g.childIds(id).isNotEmpty);
      await _open(tester, tree, focus: who);
      await tester.tap(find.byWidgetPredicate((w) => w is TreeNodeCard && w.person.id == who), warnIfMissed: false);
      await tester.pump(const Duration(seconds: 1));
      final before = _cards(tester)[who]!;

      // A grandparent, a sibling and a child: the layout changes around them.
      final parent = g.parentIds(who).first;
      // Single statements: a repository transaction would wait on the
      // screen's live queries, which run on the test's fake clock.
      Future<int> link(String p, String c) => _db.into(_db.parentChildLinks).insert(
          ParentChildLinksCompanion.insert(id: 'l$p$c', treeId: tree, parentId: p, childId: c));
      Future<void> write(Future<Object?> Function() f) async {
        await tester.runAsync(f);
        await _settle(tester);
      }

      await write(() => _repo.createPerson(PersonsCompanion.insert(id: 'gp1', treeId: tree)));
      if (g.parentIds(parent).isEmpty) await write(() => link('gp1', parent));
      await write(() => _repo.createPerson(PersonsCompanion.insert(id: 'sib1', treeId: tree)));
      await write(() => link(parent, 'sib1'));
      await write(() => _repo.createPerson(PersonsCompanion.insert(id: 'kid1', treeId: tree)));
      await write(() => link(who, 'kid1'));
      final cards = _cards(tester);
      expect(cards, contains('kid1'));
      expect(cards[who]!.center.dx, closeTo(before.center.dx, 1));
      expect(cards[who]!.center.dy, closeTo(before.center.dy, 1));
      // Everyone, the new sibling included, is placed in the tree.
      await _tool(tester, 'Fit whole tree to screen');
      expect(_cards(tester).keys, containsAll(['gp1', 'sib1', 'kid1', ...g.people.keys]));
      expect(tester.takeException(), isNull);
      await _done(tester);
    });

    testWidgets('removing people and relationships never leaves broken cards', (tester) async {
      final (tree, g) = (await tester.runAsync(() => _save(randomFamily(4, size: 40), 'Remove')))!;
      await _open(tester, tree);
      final victims = g.people.keys.skip(10).take(5).toList();
      for (final id in victims) {
        // What moving to the trash does to the person row (one statement; see above).
        await tester.runAsync(() => (_db.update(_db.persons)..where((x) => x.id.equals(id)))
            .write(PersonsCompanion(deletedAt: Value(DateTime.now()))));
        await _settle(tester);
        final shown = _cards(tester).keys.toSet();
        expect(shown.intersection(victims.take(victims.indexOf(id) + 1).toSet()), isEmpty);
        expect(tester.takeException(), isNull);
      }
      await _done(tester);
    });

    testWidgets('switching to another family tree frames the new tree', (tester) async {
      final (first, _) = (await tester.runAsync(() => _save(randomFamily(1, size: 30), 'First')))!;
      final (second, g2) = (await tester.runAsync(() => _save(randomFamily(6, size: 150, idPrefix: 'q'), 'Second')))!;
      await _open(tester, first);
      for (var i = 0; i < 4; i++) {
        await _tool(tester, 'Zoom in');
      }
      final container = ProviderScope.containerOf(tester.element(find.byType(FamilyTreeScreen)));
      await tester.runAsync(() => container.read(settingsProvider.notifier).update((p) => p.copyWith(activeTreeId: second)));
      await _settle(tester);
      final cards = _cards(tester);
      expect(cards.keys.toSet().difference(g2.people.keys.toSet()), isEmpty, reason: 'only the new tree is shown');
      expect(cards, isNotEmpty);
      final screen = _screen(tester);
      expect(cards.values.any(screen.overlaps), isTrue, reason: 'the new tree is in view');
      await _done(tester);
    });
  });
}
