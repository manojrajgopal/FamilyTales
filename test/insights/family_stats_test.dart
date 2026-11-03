import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/features/family/domain/family_graph.dart';
import 'package:family_tales/features/family/domain/occasions.dart';
import 'package:family_tales/features/reports/family_stats.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  // Three generations:
  //   g1 (1920–1990) & g2 (c.1925), married 10 May 1948
  //   ├─ p1 (1950) & w1 (20 May 1952) → c1 (1980), c2 (1982)
  //   └─ p2 (1955) & h2 (?)           → c3 (15 Jul 2003)
  final people = [
    person('g1', first: 'George', last: 'Rao', gender: Gender.male, birth: 'EX:1920',
        birthPlace: 'Pune', living: false, death: 'EX:1990'),
    person('g2', first: 'Gita', last: 'Rao', gender: Gender.female, birth: 'ABT:1925', birthPlace: 'pune '),
    person('p1', first: 'Paul', last: 'Rao', gender: Gender.male, birth: 'EX:1950', birthPlace: 'Mumbai'),
    person('w1', first: 'Wendy', last: 'Rao', gender: Gender.female, birth: 'EX:1952-05-20', birthPlace: 'Pune'),
    person('p2', first: 'Priya', last: 'Shah', gender: Gender.female, birth: 'EX:1955'),
    person('h2', first: 'Hari', last: 'Shah', gender: Gender.male),
    person('c1', first: 'Chris', last: 'Rao', birth: 'EX:1980'),
    person('c2', first: 'Cara', last: 'Rao', gender: Gender.female, birth: 'EX:1982'),
    person('c3', first: 'Chandra', last: 'Shah', gender: Gender.nonBinary, birth: 'EX:2003-07-15',
        createdAt: DateTime(2024, 6, 1)),
  ];
  final links = [
    link('g1', 'p1'), link('g2', 'p1'), link('g1', 'p2'), link('g2', 'p2'),
    link('p1', 'c1'), link('w1', 'c1'), link('p1', 'c2'), link('w1', 'c2'),
    link('p2', 'c3'), link('h2', 'c3'),
  ];
  final couples = [
    couple('g1', 'g2', start: 'EX:1948-05-10'),
    couple('p1', 'w1'),
    couple('p2', 'h2'),
  ];
  final events = [
    event('e1', 'Wedding of George & Gita', type: EventType.marriage, location: 'PUNE'),
    event('e2', 'Wedding of Paul & Wendy', type: EventType.marriage, location: 'Goa'),
    event('e3', 'Graduation', type: EventType.graduation, location: 'Mumbai'),
  ];
  final graph = graphOf(people, links: links, couples: couples);
  final now = DateTime(2023, 4, 1);
  final stats = FamilyStats.compute(
    graph: graph,
    events: events,
    media: [media('m1'), media('m2'), media('d1', kind: MediaKind.document)],
    stories: [story('s1', 'Childhood'), story('s2', 'Moving north')],
    now: now,
  );

  test('counts members, generations, living and deceased', () {
    expect(stats.isEmpty, isFalse);
    expect(stats.totalMembers, 9);
    expect(stats.generationCount, 3);
    expect(stats.living, 8);
    expect(stats.deceased, 1);
    expect(stats.couples, 3);
  });

  test('parent statistics and average children per couple', () {
    expect(stats.peopleWithChildren, 6);
    expect(stats.parentChildLinks, 10);
    expect(stats.parentCouples, 3);
    expect(stats.averageChildrenPerCouple, closeTo(5 / 3, 1e-9));
  });

  test('average is omitted with a single parent couple', () {
    final small = FamilyStats.compute(
      graph: graphOf(
        [person('a', first: 'A'), person('b', first: 'B'), person('c', first: 'C')],
        links: [link('a', 'c'), link('b', 'c')],
      ),
    );
    expect(small.parentCouples, 1);
    expect(small.averageChildrenPerCouple, isNull);
  });

  test('earliest birth and most recently added', () {
    expect(stats.earliestBirth?.person.id, 'g1');
    expect(stats.earliestBirth?.year, 1920);
    expect(stats.mostRecentlyAdded?.id, 'c3');
  });

  test('top locations are case-insensitive and ranked', () {
    expect(stats.topLocations.first.label, 'Pune');
    // g1, g2 ("pune "), w1 and event e1 ("PUNE").
    expect(stats.topLocations.first.count, 4);
    expect(stats.topLocations[1].label, 'Mumbai');
    expect(stats.topLocations[1].count, 2);
    expect(stats.topLocations.length, 3);
  });

  test('events by type, photos and stories', () {
    expect(stats.totalEvents, 3);
    expect(stats.eventCounts.first, (EventType.marriage, 2));
    expect(stats.eventCounts.last, (EventType.graduation, 1));
    expect(stats.photos, 2);
    expect(stats.documents, 1);
    expect(stats.stories, 2);
  });

  test('people per generation and births per decade', () {
    expect(stats.peoplePerGeneration, [2, 4, 3]);
    expect(stats.knownBirthYears, 8);
    final decades = {for (final d in stats.birthsPerDecade) d.decade: d.count};
    expect(stats.birthsPerDecade.first.decade, 1920);
    expect(stats.birthsPerDecade.last.decade, 2000);
    expect(stats.birthsPerDecade.length, 9); // gaps filled with zero
    expect(decades[1920], 2);
    expect(decades[1930], 0);
    expect(decades[1950], 3);
    expect(decades[1980], 2);
    expect(decades[2000], 1);
    expect(stats.birthsPerDecade.first.label, '1920s');
  });

  test('gender distribution', () {
    expect(stats.genders[Gender.male], 3);
    expect(stats.genders[Gender.female], 4);
    expect(stats.genders[Gender.nonBinary], 1);
    expect(stats.genders[Gender.unknown], 1);
    expect(stats.specifiedGenders, 8);
  });

  test('upcoming milestones highlight round numbers', () {
    final m = stats.milestones;
    expect(m.map((x) => x.occasion.kind), [
      OccasionKind.anniversary, // 10 May: 75 years
      OccasionKind.birthday, // 20 May: Wendy turns 71
      OccasionKind.birthday, // 15 Jul: Chandra turns 20
    ]);
    expect(m[0].years, 75);
    expect(m[0].isRound, isTrue);
    expect(m[0].headline, '75th anniversary');
    expect(m[1].years, 71);
    expect(m[1].isRound, isFalse);
    expect(m[2].isRound, isTrue);
    expect(m[2].headline, '20th birthday');
  });

  test('oldest recorded generation', () {
    expect(stats.oldestGeneration, ['g1', 'g2']);
  });

  test('empty tree', () {
    final s = FamilyStats.compute(graph: FamilyGraph.empty());
    expect(s.isEmpty, isTrue);
    expect(s.generationCount, 0);
    expect(s.averageChildrenPerCouple, isNull);
    expect(s.earliestBirth, isNull);
    expect(s.mostRecentlyAdded, isNull);
    expect(s.birthsPerDecade, isEmpty);
    expect(s.peoplePerGeneration, isEmpty);
    expect(s.topLocations, isEmpty);
    expect(s.milestones, isEmpty);
    expect(s.oldestGeneration, isEmpty);
  });

  test('ordinals', () {
    expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111, 112].map(ordinal).toList(),
        ['1st', '2nd', '3rd', '4th', '11th', '12th', '13th', '21st', '22nd', '23rd', '101st', '111th', '112th']);
  });

  test('round milestone rules', () {
    expect(isRoundMilestone(OccasionKind.birthday, 50), isTrue);
    expect(isRoundMilestone(OccasionKind.birthday, 75), isTrue);
    expect(isRoundMilestone(OccasionKind.birthday, 71), isFalse);
    expect(isRoundMilestone(OccasionKind.birthday, 5), isFalse);
    expect(isRoundMilestone(OccasionKind.anniversary, 25), isTrue);
    expect(isRoundMilestone(OccasionKind.anniversary, 1), isTrue);
    expect(isRoundMilestone(OccasionKind.anniversary, 7), isFalse);
    expect(isRoundMilestone(OccasionKind.memorial, 10), isTrue);
    expect(isRoundMilestone(OccasionKind.memorial, 20), isFalse);
    expect(isRoundMilestone(OccasionKind.birthday, null), isFalse);
  });
}
