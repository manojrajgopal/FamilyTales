import 'package:drift/drift.dart' show Value;
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/core/models/fuzzy_date.dart';
import 'package:family_tales/core/repositories/family_repository.dart';
import 'package:family_tales/core/repositories/system_repository.dart';
import 'package:family_tales/features/family/domain/family_graph.dart';
import 'package:family_tales/features/family/domain/kinship.dart';
import 'package:family_tales/app/settings.dart';
import 'package:family_tales/core/repositories/content_repository.dart';
import 'package:family_tales/features/calendar/notification_planner.dart';
import 'package:family_tales/features/family/domain/occasions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:family_tales/features/backup/gedcom/gedcom_parser.dart';
import 'package:family_tales/features/backup/gedcom/gedcom_importer.dart';

void main() {
  late AppDatabase db;
  late FamilyRepository repo;
  late String tree;

  setUp(() async {
    db = AppDatabase.memory();
    repo = FamilyRepository(db);
    tree = await repo.createTree('T');
  });
  tearDown(() => db.close());

  Future<String> person(String first,
          {Gender g = Gender.unknown, String? birth, String? death, bool living = true, String? email}) =>
      repo.createPerson(PersonsCompanion.insert(
        id: newId(),
        treeId: tree,
        firstName: Value(first),
        gender: Value(g),
        birthDate: Value(birth),
        deathDate: Value(death),
        isLiving: Value(living),
        email: Value(email),
      ));

  test('regression: GEDCOM FROM..TO range parsed as text', () {
    final d = FuzzyDate.fromGedcom('FROM 1900 TO 1910')!;
    expect(d.qualifier, DateQualifier.between);
  });

  test('regression: born May 1950, died 1950 (month unknown) is rejected', () async {
    await expectLater(
        person('Baby', birth: 'EX:1950-05', death: 'EX:1950', living: false), completes);
  });

  test('regression: deceased without death date gets age as of today', () async {
    final id = await person('Old', birth: 'EX:1950', living: false);
    final g = await repo.loadGraph(tree);
    expect(g[id]!.age, isNull);
  });

  test('regression: trashed person hides edges from cycle check; restore creates a loop', () async {
    final a = await person('A');
    final p = await person('P');
    final c = await person('C');
    await repo.addParent(childId: p, parentId: a);
    await repo.addParent(childId: c, parentId: p);
    await repo.trashPerson(p);
    // C is A's grandchild; making C A's parent must be rejected.
    await expectLater(repo.addParent(childId: a, parentId: c), throwsA(isA<ValidationException>()));
    final rec = (await db.select(db.deletionRecords).get()).single;
    await SystemRepository(db).restore(rec.id);
    final g = await repo.loadGraph(tree);
    expect(g.ancestors(a).contains(a), isFalse);
  });

  test('regression: mergePeople drops the removed person\'s email', () async {
    final keep = await person('John');
    final remove = await person('John', email: 'j@example.com');
    await repo.mergePeople(keepId: keep, removeId: remove);
    final k = await repo.person(keep);
    expect(k!.email, 'j@example.com');
  });

  test('regression: spouse of a gender-unknown uncle labelled Sister-in-law', () async {
    final gp = await person('GP', g: Gender.male);
    final u = await person('U');
    final par = await person('Par', g: Gender.male);
    final n = await person('N', g: Gender.male);
    final s = await person('S', g: Gender.female);
    await repo.addParent(childId: u, parentId: gp);
    await repo.addParent(childId: par, parentId: gp);
    await repo.addParent(childId: n, parentId: par);
    await repo.addPartnership(a: u, b: s);
    final g = await repo.loadGraph(tree);
    final k = KinshipCalculator(g);
    expect(k.primaryLabel(s, n), isNot('Sister-in-law'));
  });

  test('regression: merge re-points through a foster link and creates a loop', () async {
    final k = await person('John');
    final x = await person('X');
    final r = await person('John');
    await repo.addParent(childId: x, parentId: k, type: ParentType.foster);
    await repo.addParent(childId: r, parentId: x);
    await expectLater(repo.mergePeople(keepId: k, removeId: r), throwsA(isA<ValidationException>()));
    final g = await repo.loadGraph(tree);
    expect(g.ancestors(k), isNot(contains(k)));
  });

  test('regression: merge silently deletes links to a trashed relative', () async {
    final par = await person('Par');
    final k = await person('John');
    final r = await person('John');
    await repo.addParent(childId: r, parentId: par);
    await repo.trashPerson(par);
    await repo.mergePeople(keepId: k, removeId: r);
    final rec = (await db.select(db.deletionRecords).get()).single;
    await SystemRepository(db).restore(rec.id);
    final g = await repo.loadGraph(tree);
    expect(g.parentIds(k), contains(par));
  });

  test('regression: GEDCOM import accepts ancestor loops', () {
    const ged = '0 HEAD\n0 @I1@ INDI\n1 NAME A /X/\n0 @I2@ INDI\n1 NAME B /X/\n'
        '0 @F1@ FAM\n1 HUSB @I1@\n1 CHIL @I2@\n0 @F2@ FAM\n1 HUSB @I2@\n1 CHIL @I1@\n0 TRLR';
    final plan = GedcomImporter(GedcomParser.parse(ged)).analyze();
    expect(plan.parentLinks.length, lessThan(2));
  });

  test('regression: impossible day 31 FEB accepted', () {
    final d = FuzzyDate.fromGedcom('31 FEB 1900')!;
    expect(d.qualifier, DateQualifier.text);
  });

  test('regression: open-ended BET round trip', () {
    const d = FuzzyDate(qualifier: DateQualifier.between, year: 1920);
    final ged = d.toGedcom();
    final back = FuzzyDate.fromGedcom(ged);
    expect(ged, 'AFT 1920');
    expect(back?.qualifier, DateQualifier.after);
    expect(back?.year, 1920);
  });

  test('regression: a trashed biological parent still counts towards the limit of two', () async {
    final child = await person('Child');
    final p1 = await person('P1');
    final p2 = await person('P2');
    final p3 = await person('P3');
    await repo.addParent(childId: child, parentId: p1);
    await repo.addParent(childId: child, parentId: p2);
    await repo.trashPerson(p2);
    await expectLater(repo.addParent(childId: child, parentId: p3), throwsA(isA<ValidationException>()));
  });

  test('regression: merging two people with four different birth parents is refused', () async {
    final a = await person('Sam');
    final b = await person('Sam');
    for (final x in [a, b]) {
      await repo.addParent(childId: x, parentId: await person('F$x'));
      await repo.addParent(childId: x, parentId: await person('M$x'));
    }
    await expectLater(repo.mergePeople(keepId: a, removeId: b), throwsA(isA<ValidationException>()));
    expect(await repo.person(b), isNotNull, reason: 'nothing is changed when a merge is refused');
  });

  test('regression: merge keeps every optional field and leaves empty notes null', () async {
    final keep = await person('Ann');
    final remove = await repo.createPerson(PersonsCompanion.insert(
      id: newId(),
      treeId: tree,
      firstName: const Value('Ann'),
      fullName: const Value('Ann Mary Lee'),
      pronouns: const Value('she/her'),
      nationality: const Value('Indian'),
      languages: const Value('Malayalam'),
      interests: const Value('Music'),
      achievements: const Value('Award'),
      phone: const Value('123'),
      address: const Value('Kochi'),
      causeOfDeath: const Value('—'),
      burialPlace: const Value('Kochi'),
      birthNotes: const Value('Home birth'),
      isPrivate: const Value(true),
    ));
    await repo.mergePeople(keepId: keep, removeId: remove);
    final k = (await repo.person(keep))!;
    expect(k.fullName, 'Ann Mary Lee');
    expect(k.pronouns, 'she/her');
    expect(k.nationality, 'Indian');
    expect(k.languages, 'Malayalam');
    expect(k.interests, 'Music');
    expect(k.achievements, 'Award');
    expect(k.phone, '123');
    expect(k.address, 'Kochi');
    expect(k.burialPlace, 'Kochi');
    expect(k.birthNotes, 'Home birth');
    expect(k.isPrivate, isTrue);
    expect(k.notes, isNull);
  });

  test('regression: a death date really before the birth is still rejected', () async {
    await expectLater(person('X', birth: 'EX:1950-05-10', death: 'EX:1950-05-02', living: false),
        throwsA(isA<ValidationException>()));
    await expectLater(person('Y', birth: 'EX:1950', death: 'EX:1949', living: false),
        throwsA(isA<ValidationException>()));
    await expectLater(person('Z', birth: 'EX:1950-05-10', death: 'EX:1950-05', living: false), completes);
  });

  test('regression: stored dates with impossible parts never roll over', () {
    expect(FuzzyDate.tryParse('EX:1900-02-31')!.day, isNull);
    expect(FuzzyDate.tryParse('EX:1900-13-01')!.month, isNull);
    expect(FuzzyDate.tryParse('EX:2000-02-29')!.day, 29, reason: '2000 is a leap year');
    expect(FuzzyDate.tryParse('EX:1900-02-29')!.day, isNull, reason: '1900 is not');
    expect(() => FuzzyDate.tryParse('EX:1900-13-01')!.toGedcom(), returnsNormally);
  });

  test('regression: merging trees with the same tag keeps one tag and its links', () async {
    final other = await repo.createTree('Other');
    final a = await person('A');
    final b = await repo.createPerson(PersonsCompanion.insert(id: newId(), treeId: other, firstName: const Value('B')));
    await repo.tagPeople([a], await repo.ensureTag(tree, 'Military'));
    await repo.tagPeople([b], await repo.ensureTag(other, 'military'));
    await repo.mergeTrees(sourceId: other, targetId: tree);
    final tags = await repo.watchTags(tree).first;
    expect(tags.where((t) => t.name.toLowerCase() == 'military'), hasLength(1));
    // Typing the tag again must not crash on duplicates.
    final id = await repo.ensureTag(tree, 'MILITARY');
    expect(id, tags.single.id);
    final links = await db.select(db.personTags).get();
    expect(links.map((l) => l.personId).toSet(), {a, b});
  });

  test('regression: merging people moves a branch root to the kept person', () async {
    final keep = await person('Grandpa');
    final remove = await person('Grandpa');
    final branch = await repo.createBranch(tree, 'Paternal line', rootPersonId: remove);
    await repo.mergePeople(keepId: keep, removeId: remove);
    final b = await (db.select(db.familyBranches)..where((x) => x.id.equals(branch))).getSingle();
    expect(b.rootPersonId, keep);
  });

  test('regression: merge refuses to make someone the partner of their own parent', () async {
    final father = await person('Father');
    final son = await person('Son');
    await repo.addParent(childId: son, parentId: father);
    final dup = await person('Son');
    await repo.addPartnership(a: dup, b: father);
    await expectLater(repo.mergePeople(keepId: son, removeId: dup), throwsA(isA<ValidationException>()));
  });

  test('regression: merge refuses to make a partner also a parent', () async {
    final a = await person('A');
    final wife = await person('Wife');
    await repo.addPartnership(a: a, b: wife);
    final dup = await person('A');
    await repo.addParent(childId: wife, parentId: dup);
    await expectLater(repo.mergePeople(keepId: a, removeId: dup), throwsA(isA<ValidationException>()));
  });

  test('regression: a trashed parent is named in the two-parents message', () async {
    final child = await person('Child');
    final p1 = await person('P1');
    final p2 = await person('P2');
    await repo.addParent(childId: child, parentId: p1);
    await repo.addParent(childId: child, parentId: p2);
    await repo.trashPerson(p2);
    await expectLater(
      repo.addParent(childId: child, parentId: await person('P3')),
      throwsA(predicate((e) => e.toString().contains('Trash'))),
    );
  });

  test('regression: a yearly reminder for a future event starts in the event’s year', () async {
    final content = ContentRepository(db);
    final next = DateTime.now().year + 1;
    await content.saveEvent(
      treeId: tree,
      title: 'Reunion',
      type: EventType.familyReunion,
      date: FuzzyDate.ymd(next, 8, 15).serialize(),
      remind: true,
    );
    final events = await content.watchEvents(tree).first;
    final calc = OccasionCalculator(graph: await repo.loadGraph(tree), events: events);
    final found = calc
        .between(DateTime(next - 1), DateTime(next + 2, 12, 31))
        .where((o) => o.kind == OccasionKind.event)
        .map((o) => o.date.year)
        .toList();
    expect(found, [next, next + 1, next + 2]);
  });

  test('regression: notifications are planned for every tree, not only the open one', () async {
    final now = DateTime.now();
    final soon = now.add(const Duration(days: 10));
    Future<OccasionCalculator> calcFor(String name) async {
      final t = await repo.createTree(name);
      await repo.createPerson(PersonsCompanion.insert(
        id: newId(),
        treeId: t,
        firstName: Value(name),
        birthDate: Value(FuzzyDate.ymd(1990, soon.month, soon.day).serialize()),
      ));
      return OccasionCalculator(graph: await repo.loadGraph(t));
    }

    final a = await calcFor('Asha');
    final b = await calcFor('Bala');
    const prefs = AppPrefs();
    final plan = NotificationPlanner.planAll(calculators: [a, b], prefs: prefs, now: now);
    final titles = plan.map((n) => n.title).join(' ');
    expect(titles, contains('Asha'));
    expect(titles, contains('Bala'));
    expect(plan.map((n) => n.id).toSet(), hasLength(plan.length), reason: 'ids must be unique');
  });
}
