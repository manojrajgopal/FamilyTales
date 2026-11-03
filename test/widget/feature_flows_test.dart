import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:family_tales/app/providers.dart';
import 'package:family_tales/app/router.dart';
import 'package:family_tales/app/settings.dart';
import 'package:family_tales/app/theme/app_theme.dart';
import 'package:family_tales/app/theme/tokens.dart';
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/repositories/family_repository.dart';
import 'package:family_tales/core/services/app_paths.dart';
import 'package:family_tales/features/family_tree/family_tree_screen.dart';
import 'package:family_tales/features/family_tree/widgets/tree_node.dart';
import 'package:family_tales/features/members/person_form_screen.dart';
import 'package:family_tales/features/members/relation_planner.dart';
import 'package:family_tales/features/onboarding/onboarding_flow.dart';
import 'package:family_tales/features/settings/appearance_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/example_family.dart';

late AppDatabase _db;
late String _tree;

String _id(String first) => _ids[first]!;
late Map<String, String> _ids;

Widget _wrap(Widget child, {bool dark = false, AppPrefs? prefs}) => ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(_db),
        initialPrefsProvider
            .overrideWithValue(prefs ?? AppPrefs(onboardingDone: true, activeTreeId: _tree)),
      ],
      child: MaterialApp(theme: AppTheme.build(dark: dark, accent: AccentChoice.mint), home: child),
    );

/// A minimal router so the form's pop/pushReplacement navigation works.
Widget _routed(String location) => ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(_db),
        initialPrefsProvider.overrideWithValue(AppPrefs(onboardingDone: true, activeTreeId: _tree)),
      ],
      child: MaterialApp.router(
        theme: AppTheme.build(dark: false, accent: AccentChoice.mint),
        routerConfig: GoRouter(initialLocation: location, routes: [
          GoRoute(
            path: '/new',
            builder: (_, s) => PersonFormScreen(
              relation: s.uri.queryParameters['relation'],
              anchorId: s.uri.queryParameters['anchor'],
            ),
          ),
          GoRoute(path: '/person/:id', builder: (_, s) => Text('profile ${s.pathParameters['id']}')),
        ]),
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 120));
  }
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void _phone(WidgetTester tester, {double width = 1080, double height = 2400, double dpr = 2.625}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
}

Future<void> _tapText(WidgetTester tester, String text) async {
  final f = find.text(text);
  await tester.ensureVisible(f.first);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(f.first);
  await _settle(tester);
}

void main() {
  setUpAll(() {
    AppPaths.initForTest(Directory.systemTemp.createTempSync('ft_flows'));
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() async {
    _db = AppDatabase.memory();
    _tree = await ExampleFamilyBuilder(_db).build();
    _ids = {for (final p in await _db.select(_db.persons).get()) p.firstName: p.id};
  });

  tearDown(() => _db.close());

  group('Adding a sibling to someone without parents', () {
    testWidgets('creates the named shared parents and links both children', (tester) async {
      _phone(tester);
      final gopal = _id('Gopal');
      await tester.pumpWidget(_routed('/new?relation=${RelationKind.sister.name}&anchor=$gopal'));
      await _settle(tester);

      expect(find.text('Add sister'), findsOneWidget);
      expect(find.text('Their parents'), findsOneWidget);
      expect(find.textContaining('One more step first'), findsNothing);

      await tester.enterText(find.widgetWithText(TextFormField, 'Father’s name'), 'Kesavan Nair');
      await tester.enterText(find.widgetWithText(TextFormField, 'Mother’s name'), 'Parvathi');
      await tester.enterText(find.widgetWithText(TextFormField, 'First name'), 'Janaki');
      await _tapText(tester, 'Save');

      final g = await tester.runAsync(() => FamilyRepository(_db).loadGraph(_tree));
      final janaki = g!.people.values.firstWhere((p) => p.firstName == 'Janaki');
      final kesavan = g.people.values.firstWhere((p) => p.firstName == 'Kesavan');
      final parvathi = g.people.values.firstWhere((p) => p.firstName == 'Parvathi');
      expect(kesavan.lastName, 'Nair');
      expect(parvathi.lastName, 'Nair', reason: 'single-word names take the family name');
      expect(g.parentIds(gopal).toSet(), {kesavan.id, parvathi.id});
      expect(g.parentIds(janaki.id).toSet(), {kesavan.id, parvathi.id});
      expect(g.partnerIds(kesavan.id), contains(parvathi.id));
      expect(g.siblings(gopal).map((s) => s.personId), contains(janaki.id));
      expect(find.text('profile ${janaki.id}'), findsOneWidget);
      await _done(tester);
    });

    testWidgets('with no parent names adds a single "Unknown parent"', (tester) async {
      _phone(tester);
      final gopal = _id('Gopal');
      await tester.pumpWidget(_routed('/new?relation=${RelationKind.brother.name}&anchor=$gopal'));
      await _settle(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'First name'), 'Madhavan');
      await _tapText(tester, 'Save');

      final g = await tester.runAsync(() => FamilyRepository(_db).loadGraph(_tree));
      final madhavan = g!.people.values.firstWhere((p) => p.firstName == 'Madhavan');
      final parents = g.parentIds(madhavan.id);
      expect(parents, hasLength(1));
      expect(g[parents.single]!.firstName, 'Unknown parent');
      expect(g.parentIds(gopal), parents);
      expect(madhavan.gender.name, 'male');
      await _done(tester);
    });

    testWidgets('an existing person can be connected as the sibling too', (tester) async {
      _phone(tester);
      final gopal = _id('Gopal');
      await tester.pumpWidget(_routed('/new?relation=${RelationKind.sibling.name}&anchor=$gopal'));
      await _settle(tester);
      expect(find.text('Already in tree'), findsOneWidget);
      await _done(tester);
    });

    testWidgets('saving twice quickly does not create duplicates', (tester) async {
      _phone(tester);
      final before = (await tester.runAsync(() => _db.select(_db.persons).get()))!.length;
      await tester.pumpWidget(_routed('/new'));
      await _settle(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'First name'), 'Once');
      final save = find.text('Save');
      await tester.ensureVisible(save);
      await tester.pump();
      await tester.tap(save);
      await tester.tap(save, warnIfMissed: false);
      await _settle(tester);
      final after = (await tester.runAsync(() => _db.select(_db.persons).get()))!;
      expect(after.map((p) => p.firstName).where((n) => !_ids.containsKey(n)).toList(), ['Once']);
      expect(after.length, before + 1);
      expect(after.where((p) => p.firstName == 'Once'), hasLength(1));
      await _done(tester);
    });
  });

  group('Family tree selection panel', () {
    Future<void> select(WidgetTester tester, String first) async {
      final card = find.ancestor(of: find.textContaining(first), matching: find.byType(TreeNodeCard));
      expect(card, findsWidgets, reason: '$first is not on screen');
      await tester.tap(card.first, warnIfMissed: false);
      await _settle(tester);
    }

    for (final dark in [false, true]) {
      testWidgets('only offers jumps to relatives that exist (${dark ? 'dark' : 'light'})', (tester) async {
        _phone(tester);
        await tester.pumpWidget(_wrap(FamilyTreeScreen(focusId: _id('Gopal')), dark: dark));
        await _settle(tester);

        await select(tester, 'Gopal');
        expect(find.text('Gopal Nair'), findsWidgets);
        expect(find.text('Parents'), findsNothing, reason: 'Gopal has no parents');
        expect(find.text('Children'), findsOneWidget);
        expect(find.text('Partners'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _done(tester);
      });
    }

    testWidgets('a childless, single person shows no Children/Partners chips', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_wrap(FamilyTreeScreen(focusId: _id('Isha'))));
      await _settle(tester);
      await select(tester, 'Isha');
      expect(find.text('Parents'), findsOneWidget);
      expect(find.text('Children'), findsNothing);
      expect(find.text('Partners'), findsNothing);
      await _done(tester);
    });

    testWidgets('panel sits just above the bottom of the screen', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_wrap(FamilyTreeScreen(focusId: _id('Gopal'))));
      await _settle(tester);
      await select(tester, 'Gopal');
      final panelBottom = tester.getBottomLeft(find.byTooltip('Clear selection')).dy;
      final screenH = tester.view.physicalSize.height / tester.view.devicePixelRatio;
      // Within the last ~110 dp: the card is docked at the bottom, not floating mid-screen.
      expect(screenH - panelBottom, lessThan(110));
      await _done(tester);
    });
  });

  group('Generation filter', () {
    testWidgets('shows real generation counts and changes what is drawn', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_wrap(FamilyTreeScreen(focusId: _id('Arjun'))));
      await _settle(tester);

      final button = find.byTooltip('Generations shown');
      expect(button, findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'Filter generations, \d+ shown')), findsOneWidget);
      final allNodes = find.byType(TreeNodeCard).evaluate().length;

      await tester.tap(button);
      await _settle(tester);
      expect(find.textContaining(RegExp(r'This part of the tree has \d+ generations')), findsOneWidget);
      expect(find.text('All generations'), findsOneWidget);
      expect(find.text('12'), findsNothing, reason: 'no hard-coded 1…12 options any more');

      await tester.tap(find.text('1 up & down'));
      await _settle(tester);
      expect(find.bySemanticsLabel(RegExp('Filter generations, 3 shown')), findsOneWidget);

      // "All" restores every generation.
      await tester.tap(button);
      await _settle(tester);
      await tester.tap(find.text('All generations'));
      await _settle(tester);
      expect(find.byType(TreeNodeCard).evaluate().length, greaterThanOrEqualTo(allNodes));
      await _done(tester);
    });
  });

  group('Onboarding', () {
    testWidgets('offers no sample or example data', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_wrap(const OnboardingFlow(), prefs: const AppPrefs()));
      await _settle(tester);
      expect(find.textContaining(RegExp('example', caseSensitive: false)), findsNothing);
      expect(find.textContaining(RegExp('sample', caseSensitive: false)), findsNothing);
      await _done(tester);
    });
  });

  group('Appearance', () {
    testWidgets('full screen can be switched off and is saved', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_wrap(const AppearanceSettingsScreen()));
      await _settle(tester);
      final row = find.text('Full screen');
      await tester.ensureVisible(row);
      await tester.pump();
      expect(find.text('System default'), findsWidgets);
      await tester.tap(row);
      await _settle(tester);
      final ctx = tester.element(find.byType(AppearanceSettingsScreen));
      expect(ProviderScope.containerOf(ctx).read(settingsProvider).fullScreen, isFalse);
      await _done(tester);
    });
  });

  test('routes used by the form exist', () {
    expect(Routes.person('x'), '/person/x');
  });
}
