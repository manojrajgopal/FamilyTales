import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:family_tales/app/navigation/app_shell.dart';
import 'package:family_tales/app/providers.dart';
import 'package:family_tales/app/settings.dart';
import 'package:family_tales/app/theme/app_theme.dart';
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/fuzzy_date.dart';
import 'package:family_tales/core/services/app_paths.dart';
import 'package:family_tales/core/widgets/widgets.dart';
import 'package:family_tales/features/calendar/calendar_screen.dart';
import 'package:family_tales/features/dashboard/dashboard_screen.dart';
import 'package:family_tales/features/family_tree/family_tree_screen.dart';
import 'package:family_tales/features/family_tree/widgets/tree_node.dart';
import 'package:family_tales/features/members/members_screen.dart';
import 'package:family_tales/features/members/person_form_screen.dart';
import 'package:family_tales/features/members/person_profile_screen.dart';
import '../support/example_family.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory database seeded with the example family. Seeding happens in
/// the normal (real-async) test zone; widgets then read it under FakeAsync.
late AppDatabase _db;
late String _tree;
late String _arjunId;

Future<(AppDatabase, String)> _seed(WidgetTester tester) async => (_db, _tree);

Widget _app(AppDatabase db, String treeId, Widget child) => ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        initialPrefsProvider.overrideWithValue(AppPrefs(onboardingDone: true, activeTreeId: treeId)),
      ],
      child: MaterialApp(
        theme: AppTheme.build(dark: true, accent: AccentChoice.mint),
        home: child,
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  // Let drift streams deliver (real async), then let animations finish.
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 120));
  }
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _dispose(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(() {
    AppPaths.initForTest(Directory.systemTemp.createTempSync('ft_widget'));
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() async {
    _db = AppDatabase.memory();
    _tree = await ExampleFamilyBuilder(_db).build();
    _arjunId = (await (_db.select(_db.persons)..where((p) => p.firstName.equals('Arjun'))).getSingle()).id;
  });

  tearDown(() => _db.close());

  testWidgets('design system widgets render and respond', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(dark: true, accent: AccentChoice.mint),
      home: Scaffold(
        body: Column(
          children: [
            FTCard(onTap: () => taps++, child: const Text('Card')),
            FTButton(label: 'Primary', onTap: () => taps++),
            FTIconButton(icon: AppIcons.bell, tooltip: 'Bell', onTap: () => taps++),
            const StripedProgress(value: 0.7, label: 'Work in progress'),
            const AvatarStack(people: [('Ann Lee', null), ('Bo Kim', null), ('Cy Day', null)], total: 23),
          ],
        ),
      ),
    ));
    await tester.tap(find.text('Card'));
    await tester.tap(find.text('Primary'));
    await tester.tap(find.byTooltip('Bell'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(taps, 3);
    expect(find.text('70%'), findsOneWidget);
    expect(find.text('20+'), findsOneWidget);
  });

  testWidgets('dashboard shows live statistics from the database', (tester) async {
    final (db, tree) = await _seed(tester);
    await tester.pumpWidget(_app(db, tree, const DashboardScreen()));
    await _settle(tester);
    expect(find.text('24'), findsWidgets); // members
    expect(find.text('family members'), findsOneWidget);
    expect(find.text('Generations'), findsOneWidget);
    expect(find.text('Quick actions'), findsOneWidget);
    expect(find.textContaining('Arjun'), findsWidgets);
    await _dispose(tester, db);
  });

  testWidgets('members list filters by search text', (tester) async {
    final (db, tree) = await _seed(tester);
    await tester.pumpWidget(_app(db, tree, const MembersScreen()));
    await _settle(tester);
    expect(find.text('Family members'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Kavya');
    await _settle(tester);
    expect(find.text('Kavya Nair'), findsOneWidget);
    expect(find.text('Gopal Nair'), findsNothing);
    await _dispose(tester, db);
  });

  testWidgets('profile shows derived family relationships', (tester) async {
    final (db, tree) = await _seed(tester);
    await tester.pumpWidget(_app(db, tree, PersonProfileScreen(personId: _arjunId)));
    await _settle(tester);
    expect(find.text('Arjun Nair'), findsWidgets);
    await tester.scrollUntilVisible(find.text('Siblings'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Kavya Nair'), findsOneWidget); // half-sister, derived
    expect(find.textContaining('Half-sibling'), findsOneWidget);
    await _dispose(tester, db);
  });

  testWidgets('family tree renders nodes from the database', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    final (db, tree) = await _seed(tester);
    await tester.pumpWidget(_app(db, tree, const FamilyTreeScreen()));
    await _settle(tester);
    expect(find.byType(TreeNodeCard), findsWidgets);
    expect(find.byTooltip('Zoom in'), findsOneWidget);
    expect(find.byTooltip('Fit whole tree to screen'), findsOneWidget);
    // Selecting a person reveals the navigation panel.
    await tester.tap(find.text('Arjun Nair').first);
    await _settle(tester);
    expect(find.text('Parents'), findsOneWidget);
    expect(find.text('Home person', findRichText: true), findsNothing);
    await _dispose(tester, db);
  });

  testWidgets('add member form validates the name', (tester) async {
    final (db, tree) = await _seed(tester);
    await tester.pumpWidget(_app(db, tree, const PersonFormScreen()));
    await _settle(tester);
    // Only the essentials are shown until "More details" is opened.
    expect(find.text('First name'), findsOneWidget);
    expect(find.text('Occupation'), findsNothing);
    await tester.tap(find.text('More details'));
    await _settle(tester);
    expect(find.text('Occupation'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await _settle(tester);
    expect(find.text('Enter a first or last name'), findsOneWidget);
    await _dispose(tester, db);
  });

  testWidgets('calendar shows the month grid with weekday headers', (tester) async {
    final (db, tree) = await _seed(tester);
    await tester.pumpWidget(_app(db, tree, const CalendarScreen()));
    await _settle(tester);
    for (final d in ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN']) {
      expect(find.text(d), findsOneWidget);
    }
    await _dispose(tester, db);
  });

  testWidgets('layouts adapt: small phone and tablet', (tester) async {
    for (final size in [const Size(320, 640), const Size(1024, 1366)]) {
      tester.view.physicalSize = size * 2;
      tester.view.devicePixelRatio = 2;
      final (db, tree) = await _seed(tester);
      await tester.pumpWidget(_app(db, tree, const DashboardScreen()));
      await _settle(tester);
      await _dispose(tester, db);
    }
    tester.view.reset();
  });

  test('bottom navigation reserves space for gesture bar', () {
    expect(AppShell.navHeight, greaterThan(56));
    expect(FuzzyDate.ymd(2000).format(), '2000');
  });
}
