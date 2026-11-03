import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:family_tales/app/providers.dart';
import 'package:family_tales/app/settings.dart';
import 'package:family_tales/app/theme/app_theme.dart';
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/core/repositories/family_repository.dart';
import 'package:family_tales/core/services/app_paths.dart';
import 'package:family_tales/core/widgets/widgets.dart';
import 'package:family_tales/features/family_tree/family_tree_screen.dart';
import 'package:family_tales/features/family_tree/layout/tree_layout.dart';
import 'package:family_tales/features/family_tree/widgets/tree_controls.dart';
import 'package:family_tales/features/family_tree/widgets/tree_node.dart';
import 'package:family_tales/features/family_tree/widgets/tree_painter.dart';
import 'package:family_tales/features/members/widgets/person_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/example_family.dart';

late AppDatabase _db;
late FamilyRepository _repo;
late String _tree;
late Map<String, String> _ids;

String _id(String first) => _ids[first]!;

AppPrefs _prefs({bool showGender = true}) =>
    AppPrefs(onboardingDone: true, activeTreeId: _tree, showGender: showGender);

Widget _wrap(Widget child, {bool dark = false, bool showGender = true}) => ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(_db),
        initialPrefsProvider.overrideWithValue(_prefs(showGender: showGender)),
      ],
      child: MaterialApp(theme: AppTheme.build(dark: dark, accent: AccentChoice.mint), home: child),
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

Future<String> _add(String first, Gender g) => _repo.createPerson(PersonsCompanion.insert(
      id: newId(),
      treeId: _tree,
      firstName: Value(first),
      lastName: const Value('Nair'),
      gender: Value(g),
    ));

Future<Person> _person(String id) async => (await _repo.person(id))!;

/// WCAG relative-luminance contrast ratio.
double _contrast(Color a, Color b) {
  double lum(Color c) {
    double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  }

  final la = lum(a), lb = lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

double _distance(Color a, Color b) =>
    math.sqrt(math.pow(a.r - b.r, 2) + math.pow(a.g - b.g, 2) + math.pow(a.b - b.b, 2));

/// Tree cards that are colour-coded by gender.
int _tabs() => find
    .byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('gender-'))
    .evaluate()
    .length;

/// The outline colour of a colour-coded tree card.
Color? _outline(WidgetTester tester, Gender g) {
  final f = find.byKey(ValueKey('gender-${g.name}'));
  if (f.evaluate().isEmpty) return null;
  final c = tester.widget<AnimatedContainer>(f.first);
  return ((c.foregroundDecoration! as BoxDecoration).border! as Border).top.color;
}

void main() {
  setUpAll(() {
    AppPaths.initForTest(Directory.systemTemp.createTempSync('ft_gender'));
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() async {
    _db = AppDatabase.memory();
    _repo = FamilyRepository(_db);
    _tree = await ExampleFamilyBuilder(_db).build();
    _ids = {for (final p in await _db.select(_db.persons).get()) p.firstName: p.id};
  });

  tearDown(() => _db.close());

  // ---------------------------------------------------------------------------
  group('GenderStyle (colour + symbol rules)', () {
    for (final dark in [false, true]) {
      final theme = dark ? 'dark' : 'light';

      test('every recorded gender has a style, "not specified" has none ($theme)', () {
        for (final g in Gender.values) {
          final s = GenderStyle.of(g, dark: dark);
          if (g == Gender.unknown) {
            expect(s, isNull);
          } else {
            expect(s, isNotNull, reason: g.name);
            expect(s!.gender, g);
            expect(s.label, g.label);
          }
        }
      });

      test('all gender colours are clearly different from each other ($theme)', () {
        final styles = [for (final g in GenderStyle.shown) GenderStyle.of(g, dark: dark)!];
        for (var i = 0; i < styles.length; i++) {
          for (var j = i + 1; j < styles.length; j++) {
            expect(_distance(styles[i].color, styles[j].color), greaterThan(0.25),
                reason: '${styles[i].label} vs ${styles[j].label}');
          }
        }
      });

      test('male and female are far apart (blue vs pink) ($theme)', () {
        final m = GenderStyle.of(Gender.male, dark: dark)!.color;
        final f = GenderStyle.of(Gender.female, dark: dark)!.color;
        expect(m.b, greaterThan(m.r), reason: 'male is blue');
        expect(f.r, greaterThan(f.b), reason: 'female is pink/red');
        expect(_distance(m, f), greaterThan(0.6));
      });

      test('symbols are readable on their badge ($theme)', () {
        for (final g in GenderStyle.shown) {
          final s = GenderStyle.of(g, dark: dark)!;
          expect(_contrast(s.color, s.onColor), greaterThanOrEqualTo(4.5), reason: g.name);
        }
      });

      test('badges stand out from the card background ($theme)', () {
        final colors = dark ? FTColors.dark(AccentChoice.mint) : FTColors.light(AccentChoice.mint);
        for (final g in GenderStyle.shown) {
          final s = GenderStyle.of(g, dark: dark)!;
          expect(_contrast(s.color, colors.cardMid), greaterThanOrEqualTo(3), reason: g.name);
        }
      });

      test('gender colours never look like any accent colour ($theme)', () {
        for (final accent in AccentChoice.values) {
          final colors = dark ? FTColors.dark(accent) : FTColors.light(accent);
          for (final g in [Gender.male, Gender.female]) {
            final s = GenderStyle.of(g, dark: dark)!;
            expect(_distance(s.color, colors.accent), greaterThan(0.12), reason: '${g.name} vs ${accent.name}');
          }
        }
      });
    }

    test('male and female use different symbols', () {
      final m = GenderStyle.of(Gender.male, dark: false)!;
      final f = GenderStyle.of(Gender.female, dark: false)!;
      expect(m.icon, isNot(f.icon));
      expect(m.icon, AppIcons.male);
      expect(f.icon, AppIcons.female);
    });

    test('legend order is male, female, non-binary, other and excludes unknown', () {
      expect(GenderStyle.shown, [Gender.male, Gender.female, Gender.nonBinary, Gender.other]);
      expect(GenderStyle.shown, isNot(contains(Gender.unknown)));
    });
  });

  // ---------------------------------------------------------------------------
  group('Show gender preference', () {
    test('is on by default', () {
      expect(const AppPrefs().showGender, isTrue);
      expect(AppPrefs.fromMap(const {}).showGender, isTrue);
    });

    test('round-trips when switched off', () {
      final p = const AppPrefs().copyWith(showGender: false);
      expect(p.toMap()['showGender'], 'false');
      expect(AppPrefs.fromMap(p.toMap()).showGender, isFalse);
    });

    test('copyWith keeps it when other fields change', () {
      final p = const AppPrefs().copyWith(showGender: false).copyWith(fullScreen: false);
      expect(p.showGender, isFalse);
    });

    test('a corrupt stored value falls back to on', () {
      for (final raw in ['', 'yes', 'TRUE', '1', 'null']) {
        expect(AppPrefs.fromMap({'showGender': raw}).showGender, isTrue, reason: raw);
      }
    });
  });

  // ---------------------------------------------------------------------------
  group('Tree card (TreeNodeCard)', () {
    Future<void> pumpCard(WidgetTester tester, Person p,
        {bool dark = false, bool compact = false, bool showGender = true, bool selected = false}) async {
      final opts = TreeLayoutOptions(mode: compact ? TreeViewMode.compact : TreeViewMode.full);
      await tester.pumpWidget(_wrap(
        dark: dark,
        Scaffold(
          body: Center(
            child: TreeNodeCard(
              person: p,
              node: LayoutNode(p.id, 0),
              options: opts,
              imagePath: null,
              selected: selected,
              dimmed: false,
              collapsed: false,
              onTap: () {},
              onExpandChildren: () {},
              onRevealParents: () {},
              showGender: showGender,
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 400));
    }

    for (final dark in [false, true]) {
      for (final compact in [false, true]) {
        final label = '${dark ? 'dark' : 'light'}, ${compact ? 'compact' : 'full'}';
        for (final g in Gender.values) {
          testWidgets('${g.label}: coloured outline only when recorded, no symbol ($label)', (tester) async {
            final p = await tester.runAsync(() async => _person(await _add('P${g.name}', g)));
            await pumpCard(tester, p!, dark: dark, compact: compact);
            final known = g != Gender.unknown;
            expect(find.byType(GenderBadge), findsNothing, reason: 'colour only, no symbol');
            expect(_tabs(), known ? 1 : 0);
            if (known) expect(_outline(tester, g), GenderStyle.of(g, dark: dark)!.color);
            // Only the border is coloured: the card background is the normal one.
            final box = tester.widget<AnimatedContainer>(find
                .descendant(of: find.byType(TreeNodeCard), matching: find.byType(AnimatedContainer))
                .first);
            final colors = dark ? FTColors.dark(AccentChoice.mint) : FTColors.light(AccentChoice.mint);
            expect((box.decoration! as BoxDecoration).gradient, colors.cardGradient);
            expect(tester.takeException(), isNull);
            await _done(tester);
          });
        }
      }
    }

    testWidgets('screen readers hear the gender', (tester) async {
      final p = await tester.runAsync(() => _person(_id('Lakshmi')));
      await pumpCard(tester, p!);
      expect(find.bySemanticsLabel(RegExp(r'^Lakshmi Nair, Female')), findsOneWidget);
      await _done(tester);
    });

    testWidgets('screen readers hear nothing invented for "not specified"', (tester) async {
      final p = await tester.runAsync(() async => _person(await _add('Kiran', Gender.unknown)));
      await pumpCard(tester, p!);
      expect(find.bySemanticsLabel(RegExp('Male|Female')), findsNothing);
      await _done(tester);
    });

    testWidgets('turning the preference off removes every gender cue', (tester) async {
      final p = await tester.runAsync(() => _person(_id('Gopal')));
      await pumpCard(tester, p!, showGender: false);
      expect(find.byType(GenderBadge), findsNothing);
      expect(_tabs(), 0);
      expect(_outline(tester, Gender.male), isNull);
      await _done(tester);
    });

    testWidgets('selection highlight still wins over the gender border', (tester) async {
      final p = await tester.runAsync(() => _person(_id('Gopal')));
      await pumpCard(tester, p!, selected: true);
      // Selected: accent outline; the gender wash stays on the card.
      expect(_outline(tester, Gender.male), isNot(GenderStyle.of(Gender.male, dark: false)!.color));
      expect(_tabs(), 1);
      expect(tester.takeException(), isNull);
      await _done(tester);
    });

    testWidgets('long names do not overflow on a coloured card', (tester) async {
      final p = await tester.runAsync(() async =>
          _person(await _add('Venkatalakshmi Ananthapadmanabhan Subramaniam', Gender.female)));
      for (final compact in [false, true]) {
        await pumpCard(tester, p!, compact: compact);
        expect(tester.takeException(), isNull);
      }
      await _done(tester);
    });
  });

  // ---------------------------------------------------------------------------
  group('Family tree screen', () {
    Future<void> openTree(WidgetTester tester, String focus,
        {bool dark = false, bool showGender = true}) async {
      _phone(tester);
      await tester.pumpWidget(_wrap(FamilyTreeScreen(focusId: _id(focus)), dark: dark, showGender: showGender));
      await _settle(tester);
    }

    Future<Map<String, Gender>> gendersOnScreen(WidgetTester tester) async {
      final out = <String, Gender>{};
      for (final e in find.byType(TreeNodeCard).evaluate()) {
        final w = e.widget as TreeNodeCard;
        out[w.person.id] = w.person.gender;
      }
      return out;
    }

    for (final dark in [false, true]) {
      testWidgets('every man and woman on screen is colour-coded (${dark ? 'dark' : 'light'})', (tester) async {
        await openTree(tester, 'Arjun', dark: dark);
        final shown = await gendersOnScreen(tester);
        expect(shown, isNotEmpty);
        final known = shown.values.where((g) => g != Gender.unknown).length;
        expect(_tabs(), known);
        expect(shown.values, contains(Gender.male));
        expect(shown.values, contains(Gender.female));
        expect(tester.takeException(), isNull);
        await _done(tester);
      });
    }

    testWidgets('no gender key and no gender symbols on the tree, only colour', (tester) async {
      await openTree(tester, 'Arjun');
      expect(find.byKey(const ValueKey('gender-legend')), findsNothing);
      expect(find.byType(GenderBadge), findsNothing);
      for (final t in ['Male', 'Female']) {
        expect(find.text(t), findsNothing, reason: 'no "$t" label floating over the tree');
      }
      expect(_tabs(), greaterThan(0));
      await _done(tester);
    });

    testWidgets('men and women get different outline colours', (tester) async {
      await openTree(tester, 'Arjun');
      final m = _outline(tester, Gender.male), f = _outline(tester, Gender.female);
      expect(m, GenderStyle.of(Gender.male, dark: false)!.color);
      expect(f, GenderStyle.of(Gender.female, dark: false)!.color);
      expect(m, isNot(f));
      await _done(tester);
    });

    testWidgets('a non-binary relative gets their own colour', (tester) async {
      await tester.runAsync(() async {
        final id = await _add('Ari', Gender.nonBinary);
        await _repo.addParent(childId: id, parentId: _id('Arjun'));
      });
      await openTree(tester, 'Arjun');
      expect(_outline(tester, Gender.nonBinary), GenderStyle.of(Gender.nonBinary, dark: false)!.color);
      await _done(tester);
    });

    testWidgets('a tree of only unspecified genders stays uncoloured', (tester) async {
      await tester.runAsync(() async {
        _tree = await _repo.createTree('Blank');
        final a = await _add('One', Gender.unknown);
        final b = await _add('Two', Gender.unknown);
        await _repo.addParent(childId: b, parentId: a);
        _ids = {'One': a, 'Two': b};
      });
      await openTree(tester, 'One');
      expect(find.byType(TreeNodeCard), findsNWidgets(2));
      expect(_tabs(), 0);
      await _done(tester);
    });

    testWidgets('with the preference off there are no colours', (tester) async {
      await openTree(tester, 'Arjun', showGender: false);
      expect(find.byType(GenderBadge), findsNothing);
      expect(_tabs(), 0);
      await _done(tester);
    });

    testWidgets('changing someone’s gender recolours their card', (tester) async {
      await openTree(tester, 'Isha');
      TreeNodeCard card() => tester.widget<TreeNodeCard>(find.byWidgetPredicate(
          (w) => w is TreeNodeCard && w.person.id == _id('Isha')));
      expect(card().person.gender, Gender.female);
      await tester.runAsync(() async {
        await _repo.updatePerson(_id('Isha'), const PersonsCompanion(gender: Value(Gender.other)));
      });
      await _settle(tester);
      expect(card().person.gender, Gender.other);
      expect(_outline(tester, Gender.other), GenderStyle.of(Gender.other, dark: false)!.color);
      await _done(tester);
    });

    testWidgets('the layout sheet switch hides and restores gender colours', (tester) async {
      await openTree(tester, 'Arjun');
      final before = _tabs();
      expect(before, greaterThan(0));

      await tester.tap(find.byTooltip('Change layout'));
      await _settle(tester);
      expect(find.text('Show gender'), findsOneWidget);
      expect(find.text('No colour: not specified'), findsOneWidget);
      final row = find.text('Show gender');
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(row);
      await _settle(tester);

      final ctx = tester.element(find.byType(FamilyTreeScreen));
      expect(ProviderScope.containerOf(ctx).read(settingsProvider).showGender, isFalse);
      expect(_tabs(), 0);

      await tester.tap(find.text('Show gender'));
      await _settle(tester);
      expect(ProviderScope.containerOf(ctx).read(settingsProvider).showGender, isTrue);
      expect(_tabs(), before);
      await _done(tester);
    });

    for (final mode in TreeViewMode.values) {
      testWidgets('colours appear in the ${mode.label} layout', (tester) async {
        _phone(tester);
        await tester.pumpWidget(ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(_db),
            initialPrefsProvider.overrideWithValue(_prefs().copyWith(treeMode: mode)),
          ],
          child: MaterialApp(
            theme: AppTheme.build(dark: false, accent: AccentChoice.mint),
            home: FamilyTreeScreen(focusId: _id('Arjun')),
          ),
        ));
        await _settle(tester);
        expect(_tabs(), greaterThan(0), reason: mode.name);
        expect(_tabs(), find.byType(TreeNodeCard).evaluate().length,
            reason: 'everyone in the example family has a recorded gender');
        expect(tester.takeException(), isNull);
        await _done(tester);
      });
    }

    testWidgets('a small phone with large text shows coloured cards without errors', (tester) async {
      await tester.runAsync(() async {
        for (final g in [Gender.nonBinary, Gender.other]) {
          final id = await _add('X${g.name}', g);
          await _repo.addParent(childId: id, parentId: _id('Arjun'));
        }
      });
      _phone(tester, width: 640, height: 1136, dpr: 2);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(_db),
          initialPrefsProvider.overrideWithValue(_prefs()),
        ],
        child: MediaQuery(
          data: const MediaQueryData(size: Size(320, 568), textScaler: TextScaler.linear(1.6)),
          child: MaterialApp(
            theme: AppTheme.build(dark: false, accent: AccentChoice.mint),
            home: FamilyTreeScreen(focusId: _id('Arjun')),
          ),
        ),
      ));
      await _settle(tester);
      expect(_tabs(), greaterThan(0));
      expect(tester.takeException(), isNull);
      await _done(tester);
    });
  });

  // ---------------------------------------------------------------------------
  group('Selected person panel', () {
    Future<void> selectIn(WidgetTester tester, String first, {bool dark = false}) async {
      _phone(tester);
      await tester.pumpWidget(_wrap(FamilyTreeScreen(focusId: _id(first)), dark: dark));
      await _settle(tester);
      final card = find.byWidgetPredicate((w) => w is TreeNodeCard && w.person.id == _id(first));
      await tester.tap(card, warnIfMissed: false);
      await _settle(tester);
    }

    Finder inPanel(Finder f) => find.descendant(of: find.byType(SelectedPersonPanel), matching: f);

    for (final dark in [false, true]) {
      testWidgets('shows "Male" for a man (${dark ? 'dark' : 'light'})', (tester) async {
        await selectIn(tester, 'Gopal', dark: dark);
        expect(find.byType(SelectedPersonPanel), findsOneWidget);
        expect(inPanel(find.textContaining('Male')), findsOneWidget);
        expect(inPanel(find.textContaining('Female')), findsNothing);
        expect(inPanel(find.byType(GenderBadge)), findsNothing, reason: 'text only, no symbol');
        await _done(tester);
      });

      testWidgets('shows "Female" for a woman (${dark ? 'dark' : 'light'})', (tester) async {
        await selectIn(tester, 'Lakshmi', dark: dark);
        expect(inPanel(find.textContaining('Female')), findsOneWidget);
        expect(inPanel(find.byType(GenderBadge)), findsNothing, reason: 'text only, no symbol');
        await _done(tester);
      });
    }

    testWidgets('shows no gender for someone whose gender is not specified', (tester) async {
      await tester.runAsync(() async {
        final id = await _add('Kiran', Gender.unknown);
        await _repo.addParent(childId: id, parentId: _id('Arjun'));
        _ids['Kiran'] = id;
      });
      await selectIn(tester, 'Kiran');
      expect(find.byType(SelectedPersonPanel), findsOneWidget);
      expect(inPanel(find.textContaining(RegExp('Male|Female|Not specified'))), findsNothing);
      expect(inPanel(find.byType(GenderBadge)), findsNothing);
      await _done(tester);
    });

    testWidgets('keeps the relationship text after the gender', (tester) async {
      await selectIn(tester, 'Isha');
      final rich = tester.widgetList<Text>(inPanel(find.byType(Text))).map((t) => t.textSpan?.toPlainText() ?? t.data ?? '');
      expect(rich.any((s) => s.contains('Female · ') && s.contains('Daughter of')), isTrue, reason: rich.join(' | '));
      await _done(tester);
    });
  });

  // ---------------------------------------------------------------------------
  group('Avatars elsewhere in the app', () {
    testWidgets('PersonAvatar draws a badge only for a recorded gender', (tester) async {
      for (final g in Gender.values) {
        await tester.pumpWidget(_wrap(Scaffold(body: Center(child: PersonAvatar(name: 'Asha Nair', gender: g)))));
        await tester.pump();
        expect(find.byType(GenderBadge), g == Gender.unknown ? findsNothing : findsOneWidget, reason: g.name);
      }
      await tester.pumpWidget(_wrap(const Scaffold(body: Center(child: PersonAvatar(name: 'Asha Nair')))));
      await tester.pump();
      expect(find.byType(GenderBadge), findsNothing);
      await _done(tester);
    });

    testWidgets('avatar semantics include the gender', (tester) async {
      await tester.pumpWidget(
          _wrap(const Scaffold(body: Center(child: PersonAvatar(name: 'Asha Nair', gender: Gender.female)))));
      await tester.pump();
      expect(find.bySemanticsLabel('Photo of Asha Nair, Female'), findsOneWidget);
      await _done(tester);
    });

    for (final size in [24.0, 44.0, 64.0, 128.0]) {
      testWidgets('badge scales sensibly at ${size.toInt()} dp', (tester) async {
        await tester.pumpWidget(
            _wrap(Scaffold(body: Center(child: PersonAvatar(name: 'A', size: size, gender: Gender.male)))));
        await tester.pump();
        final b = tester.getSize(find.byType(GenderBadge));
        expect(b.width, inInclusiveRange(14, 34));
        expect(b.width, lessThan(size * 0.6 + 14));
        expect(tester.takeException(), isNull);
        await _done(tester);
      });
    }

    testWidgets('member list rows show the badge and respect the preference', (tester) async {
      final p = await tester.runAsync(() => _person(_id('Gopal')));
      for (final on in [true, false]) {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(_wrap(showGender: on, Scaffold(body: PersonTile(person: p!))));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(GenderBadge), on ? findsOneWidget : findsNothing, reason: 'showGender=$on');
      }
      await _done(tester);
    });

    testWidgets('PersonAvatarFor stays plain unless asked (small avatars, chips)', (tester) async {
      final p = await tester.runAsync(() => _person(_id('Gopal')));
      await tester.pumpWidget(_wrap(Scaffold(body: Center(child: PersonAvatarFor(p!, size: 28)))));
      await tester.pump();
      expect(find.byType(GenderBadge), findsNothing);
      await tester.pumpWidget(_wrap(Scaffold(body: Center(child: PersonAvatarFor(p, size: 28, showGender: true)))));
      await tester.pump();
      expect(find.byType(GenderBadge), findsOneWidget);
      await _done(tester);
    });
  });

  // ---------------------------------------------------------------------------
  group('Connector lines take the parent’s colour', () {
    final male = GenderStyle.of(Gender.male, dark: false)!.color;
    final female = GenderStyle.of(Gender.female, dark: false)!.color;
    const neutral = Color(0xFF999999), accent = Color(0xFF00AA88);

    Future<TreeLayout> layoutOf(String focus) async {
      final g = await _repo.loadGraph(_tree);
      return TreeLayoutEngine(g).compute(TreeLayoutOptions(mode: TreeViewMode.full, focusId: _ids[focus]));
    }

    TreeConnectorPainter painter(TreeLayout layout, Map<String, Color> colors, {Set<String> highlight = const {}}) =>
        TreeConnectorPainter(
          layout: layout,
          line: neutral,
          accent: accent,
          background: Colors.white,
          highlight: highlight,
          personColors: colors,
        );

    Future<void> pumpPainter(WidgetTester tester, TreeConnectorPainter p) async {
      await tester.pumpWidget(Center(
        child: SizedBox(
          width: p.layout.size.width,
          height: p.layout.size.height,
          child: CustomPaint(key: const ValueKey('lines'), painter: p),
        ),
      ));
    }

    Finder lines() => find.byKey(const ValueKey('lines'));

    /// ARGB values of every line colour the painter used.
    Set<int> drawn(TreeConnectorPainter p) {
      final rec = _Recorder();
      p.paint(rec, p.layout.size);
      return {for (final e in rec.paths) e.$2.toARGB32()};
    }

    final m = male.toARGB32(), f = female.toARGB32(), n = neutral.toARGB32();

    Future<(String, String, String)> family(WidgetTester tester, {bool partners = true}) async {
      final ids = await tester.runAsync(() async {
        _tree = await _repo.createTree('Lines');
        final dad = await _add('Dad', Gender.male);
        final mum = await _add('Mum', Gender.female);
        final kid = await _add('Kid', Gender.unknown);
        if (partners) await _repo.addPartnership(a: dad, b: mum);
        await _repo.addParent(childId: kid, parentId: dad);
        await _repo.addParent(childId: kid, parentId: mum);
        _ids = {'Dad': dad, 'Mum': mum, 'Kid': kid};
        return (dad, mum, kid);
      });
      return ids!;
    }

    testWidgets('a couple: husband’s half blue, wife’s half pink', (tester) async {
      final (dad, mum, _) = await family(tester);
      final layout = (await tester.runAsync(() => layoutOf('Kid')))!;
      await pumpPainter(tester, painter(layout, {dad: male, mum: female}));
      expect(lines(), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(drawn(painter(layout, {dad: male, mum: female})), containsAll([m, f, n]));
    });

    testWidgets('parents who are not partners: each line in their own colour', (tester) async {
      final (dad, mum, _) = await family(tester, partners: false);
      final layout = (await tester.runAsync(() => layoutOf('Kid')))!;
      expect(layout.families.where((f) => f.parents.length == 1), hasLength(2));
      expect(drawn(painter(layout, {dad: male, mum: female})), containsAll([m, f, n]));
    });

    testWidgets('no colours given: every line stays neutral', (tester) async {
      await family(tester);
      final layout = (await tester.runAsync(() => layoutOf('Kid')))!;
      final used = drawn(painter(layout, const {}));
      expect(used, contains(n));
      expect(used, isNot(contains(m)));
      expect(used, isNot(contains(f)));
    });

    testWidgets('only the parent with a recorded gender is coloured', (tester) async {
      final (dad, _, _) = await family(tester);
      final layout = (await tester.runAsync(() => layoutOf('Kid')))!;
      final used = drawn(painter(layout, {dad: male}));
      expect(used, contains(m));
      expect(used, isNot(contains(f)));
    });

    testWidgets('the selected lineage highlight still wins on the couple line', (tester) async {
      final (dad, mum, kid) = await family(tester);
      final layout = (await tester.runAsync(() => layoutOf('Kid')))!;
      final rec = _Recorder();
      painter(layout, {dad: male, mum: female}, highlight: {dad, mum, kid}).paint(rec, layout.size);
      final couple = layout.partners.single;
      bool onCoupleLine(Path p) => (p.getBounds().top - couple.from.dy).abs() < 1 && p.getBounds().height < 1;
      final coupleColours = {for (final e in rec.paths) if (onCoupleLine(e.$1)) e.$2.toARGB32()};
      expect(coupleColours, contains(accent.toARGB32()));
      expect(coupleColours, isNot(contains(m)), reason: 'selection colour is not covered by gender colour');
    });

    testWidgets('the shared line below the meeting point stays neutral', (tester) async {
      final (dad, mum, _) = await family(tester, partners: false);
      final layout = (await tester.runAsync(() => layoutOf('Kid')))!;
      final rec = _Recorder();
      painter(layout, {dad: male, mum: female}).paint(rec, layout.size);
      final childTop = layout.families.first.children.single.top;
      for (final (path, color) in rec.paths) {
        if (color.toARGB32() == m || color.toARGB32() == f) {
          // Coloured parts end at the bus, never on the drop into the child.
          expect(path.getBounds().bottom, lessThan(childTop.dy - 4), reason: '$color');
        }
      }
      expect(rec.paths.any((e) => e.$2.toARGB32() == n && e.$1.getBounds().bottom >= childTop.dy - 1), isTrue);
    });

    test('repaints when colours change, not when they are equal', () {
      final layout = TreeLayout(const TreeLayoutOptions(mode: TreeViewMode.full), {}, [], [], Size.zero);
      final a = painter(layout, {'x': male});
      expect(a.shouldRepaint(painter(layout, {'x': male})), isFalse);
      expect(a.shouldRepaint(painter(layout, {'x': female})), isTrue);
      expect(a.shouldRepaint(painter(layout, const {})), isTrue);
    });

    Map<String, Color> screenColors(WidgetTester tester) => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((c) => c.painter)
        .whereType<TreeConnectorPainter>()
        .single
        .personColors;

    testWidgets('the tree screen colours lines for recorded genders only', (tester) async {
      await tester.runAsync(() async {
        final id = await _add('Kiran', Gender.unknown);
        await _repo.addParent(childId: id, parentId: _id('Arjun'));
        _ids['Kiran'] = id;
      });
      _phone(tester);
      await tester.pumpWidget(_wrap(FamilyTreeScreen(focusId: _id('Arjun'))));
      await _settle(tester);
      final colors = screenColors(tester);
      expect(colors[_id('Arjun')], male);
      expect(colors[_id('Priya')], female);
      expect(colors.containsKey(_id('Kiran')), isFalse);
      await _done(tester);
    });

    testWidgets('line colours match the card borders in dark mode', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_wrap(FamilyTreeScreen(focusId: _id('Arjun')), dark: true));
      await _settle(tester);
      expect(screenColors(tester)[_id('Arjun')], GenderStyle.of(Gender.male, dark: true)!.color);
      expect(_outline(tester, Gender.male), GenderStyle.of(Gender.male, dark: true)!.color);
      await _done(tester);
    });

    testWidgets('with “Show gender” off the lines are not coloured', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_wrap(FamilyTreeScreen(focusId: _id('Arjun')), showGender: false));
      await _settle(tester);
      expect(screenColors(tester), isEmpty);
      await _done(tester);
    });
  });
}

/// Records the paths drawn by a painter with their stroke colours.
class _Recorder implements Canvas {
  final paths = <(Path, Color)>[];

  @override
  void drawPath(Path path, Paint paint) => paths.add((path, paint.color));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
