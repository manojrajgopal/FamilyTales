import 'dart:io';

import 'package:family_tales/app/app.dart';
import 'package:family_tales/app/providers.dart';
import 'package:family_tales/app/router.dart';
import 'package:family_tales/app/settings.dart';
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/core/models/fuzzy_date.dart';
import 'package:family_tales/core/repositories/content_repository.dart';
import 'package:family_tales/core/repositories/family_repository.dart';
import 'package:family_tales/core/services/app_paths.dart';
import 'package:family_tales/features/backup/backup_service.dart';
import 'package:family_tales/features/family/domain/kinship.dart';
import 'package:family_tales/core/widgets/gender_style.dart';
import 'package:family_tales/features/family_tree/widgets/tree_node.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// End-to-end flow on a real device/emulator, using an isolated encrypted
/// database file so the user's own data is never touched:
///
///  1 launch → 2 create tree (onboarding UI) → 3–6 add person, parents,
///  spouse, children → 7–8 open the tree and verify connections →
///  9 edit a member (form UI) → 10 add an event → 11 add a photo →
///  12 create a story → 13 export an encrypted backup → 14 "restart"
///  (close and reopen the database) → 15 restore the backup → 16 verify.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late File dbFile;
  const key = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

  setUpAll(() async {
    final docs = await getTemporaryDirectory();
    root = Directory(p.join(docs.path, 'ft_integration_${DateTime.now().millisecondsSinceEpoch}'));
    await root.create(recursive: true);
    AppPaths.initForTest(root);
    dbFile = File(p.join(root.path, 'family_tales.db'));
  });

  Future<void> settle(WidgetTester tester, [int frames = 12]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  Finder fields() => find.byType(TextFormField).hitTestable();

  Future<void> tapLabel(WidgetTester tester, String label) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester, 4);
    var f = find.bySemanticsLabel(label).hitTestable();
    if (f.evaluate().isEmpty) f = find.text(label).hitTestable();
    if (f.evaluate().isEmpty) {
      final visible = find.byType(Text).hitTestable().evaluate().map((e) => (e.widget as Text).data).whereType<String>();
      // ignore: avoid_print
      print('Visible texts when looking for "$label": ${visible.join(' | ')}');
    }
    expect(f, findsWidgets, reason: 'no control labelled "$label"');
    await tester.tap(f.first);
    await settle(tester);
  }

  testWidgets('complete offline family history flow', (tester) async {
    // ------------------------------------------------------------ 1. launch
    var db = AppDatabase.open(dbFile, key: key);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        initialPrefsProvider.overrideWithValue(const AppPrefs()),
      ],
      child: const FamilyTalesApp(),
    ));
    await settle(tester, 20);

    // --------------------------------------- 2–6. onboarding creates family
    await tapLabel(tester, 'Get started');
    await tapLabel(tester, 'Continue'); // introduction
    await tester.enterText(fields().first, 'Integration Family');
    await tapLabel(tester, 'Continue');
    await tester.enterText(fields().at(0), 'Asha');
    await tester.enterText(fields().at(1), 'Menon');
    await tapLabel(tester, 'Continue');
    for (final o in ['Add father', 'Add mother', 'Add spouse', 'Add children']) {
      await tapLabel(tester, o);
    }
    for (final (label, name) in [
      ('Father’s name', 'Ravi Menon'),
      ('Mother’s name', 'Lata Menon'),
      ('Spouse’s name', 'Kiran Rao'),
      ('Child 1', 'Dev Menon'),
    ]) {
      final f = find.widgetWithText(TextFormField, label);
      await tester.ensureVisible(f);
      await settle(tester, 2);
      await tester.enterText(f, name);
      await settle(tester, 2);
    }
    await tapLabel(tester, 'Continue');
    await tapLabel(tester, 'Create my family tree');
    await settle(tester, 30);
    expect(find.text('Welcome back,'), findsOneWidget);

    final family = FamilyRepository(db);
    final trees = await family.allTrees();
    expect(trees.single.name, 'Integration Family');
    final treeId = trees.single.id;
    var g = await family.loadGraph(treeId);
    expect(g.size, 5);
    String id(String first) => g.people.values.firstWhere((x) => x.firstName == first).id;

    // ------------------------------------------- 7–8. tree & connections
    await tapLabel(tester, 'Tree');
    await settle(tester, 20);
    expect(find.byType(TreeNodeCard), findsNWidgets(5));
    final kin = KinshipCalculator(g);
    expect(kin.primaryLabel(id('Ravi'), id('Asha')), 'Father');
    expect(kin.primaryLabel(id('Lata'), id('Asha')), 'Mother');
    expect(kin.primaryLabel(id('Dev'), id('Asha')), 'Child'); // gender not recorded
    expect(kin.primaryLabel(id('Ravi'), id('Dev')), 'Grandfather');
    expect(kin.primaryLabel(id('Kiran'), id('Ravi')), 'Child-in-law');
    // Gender is visible on the real device as colour only: one coloured card
    // per recorded gender, nothing for unrecorded ones, no symbols or key.
    for (final gg in Gender.values.where((x) => x != Gender.unknown)) {
      final n = g.people.values.where((p) => p.gender == gg).length;
      expect(find.byKey(ValueKey('gender-${gg.name}')), findsNWidgets(n), reason: gg.name);
    }
    expect(find.byType(GenderBadge), findsNothing);

    // --------------------------------------------- 9. edit member via form
    final ctx = tester.element(find.byType(TreeNodeCard).first);
    GoRouter.of(ctx).push(Routes.personEdit(id('Asha')));
    await settle(tester, 20);
    await tapLabel(tester, 'More details');
    final occupation = find.widgetWithText(TextFormField, 'Occupation');
    await tester.ensureVisible(occupation);
    await settle(tester, 2);
    await tester.enterText(occupation, 'Architect');
    await settle(tester);
    await tapLabel(tester, 'Save changes');
    await settle(tester, 20);
    expect((await family.person(id('Asha')))!.occupation, 'Architect');

    // ---------------------------------------- 10–12. event, photo, story
    final content = ContentRepository(db);
    final eventId = await content.saveEvent(
      treeId: treeId,
      title: 'Asha graduates',
      type: EventType.graduation,
      date: FuzzyDate.ymd(2010, 5, 20).serialize(),
      people: {id('Asha'): 'Graduate'},
    );
    final png = File(p.join(root.path, 'photo.png'))
      ..writeAsBytesSync(img.encodePng(img.Image(width: 64, height: 48)..clear(img.ColorRgb8(134, 216, 202))));
    final mediaId = await content.importMedia(png, treeId: treeId, personIds: [id('Asha')], eventIds: [eventId]);
    await family.setProfilePhoto(id('Asha'), mediaId);
    await content.saveStory(treeId: treeId, title: 'Our first home', body: '**Ravi** built it in 1985.', personIds: [id('Ravi')]);

    // ----------------------------------------- 13. encrypted backup export
    final backupDir = Directory(p.join(root.path, 'out'))..createSync();
    final backup = await BackupService(db).createBackup(
      BackupRequest(treeIds: [treeId], password: 'correct horse'),
      outDir: backupDir.path,
    );
    expect(backup.encrypted, isTrue);
    expect(File(backup.path).existsSync(), isTrue);

    // ------------------------------------------------ 14. restart the app
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await db.close();
    db = AppDatabase.open(dbFile, key: key);
    g = await FamilyRepository(db).loadGraph(treeId);
    expect(g.size, 5, reason: 'data must persist across restarts');
    expect(g[id('Asha')]!.occupation, 'Architect');

    // ------------------------------------------ 15. restore as a new tree
    final service = BackupService(db);
    await expectLater(service.inspect(backup.path, password: 'wrong password'), throwsA(isA<Exception>()));
    final insp = await service.inspect(backup.path, password: 'correct horse');
    expect(insp.counts.people, 5);
    final restored = await service.restore(insp, RestoreRequest.asNew(treeIds: [treeId]));
    await insp.dispose();

    // ---------------------------------------------------- 16. verify data
    final newTree = restored.treeIds.single;
    expect(newTree, isNot(treeId));
    final g2 = await FamilyRepository(db).loadGraph(newTree);
    expect(g2.size, 5);
    expect(g2.links.length, g.links.length);
    expect(g2.couples.length, g.couples.length);
    final asha2 = g2.people.values.firstWhere((x) => x.firstName == 'Asha');
    expect(asha2.occupation, 'Architect');
    expect(asha2.profileMediaId, isNotNull);
    final media = await (db.select(db.mediaAssets)..where((m) => m.treeId.equals(newTree))).get();
    expect(media, hasLength(1));
    expect(File(AppPaths.I.resolve(media.single.filePath)).existsSync(), isTrue);
    final stories = await (db.select(db.stories)..where((s) => s.treeId.equals(newTree))).get();
    expect(stories.single.title, 'Our first home');
    final events = await (db.select(db.familyEvents)..where((e) => e.treeId.equals(newTree))).get();
    expect(events.single.title, 'Asha graduates');

    await db.close();
  });
}
