import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/features/search/search_engine.dart';
import 'package:family_tales/features/search/text_normalize.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  final graph = graphOf([
    person('ana',
        first: 'Ana',
        middle: 'María',
        last: 'Núñez',
        nickname: 'Nana',
        birthName: 'Ortega',
        birth: 'EX:1950-04-02',
        birthPlace: 'São Paulo'),
    person('rob',
        first: 'Robert',
        last: 'Smith',
        nickname: 'Bob',
        birth: 'EX:1948',
        living: false,
        death: 'EX:2001-02-03',
        deathPlace: 'London'),
    person('rita', first: 'Roberta', last: 'Jones', birth: 'ABT:1960', birthPlace: 'london'),
  ]);
  final engine = SearchEngine(
    graph: graph,
    events: [
      event('wed', 'Wedding in Lisbon', type: EventType.marriage, date: 'EX:1972-06-10', location: 'Lisbon'),
      event('move', 'Moved to Brazil', type: EventType.migration, location: 'Sao Paulo'),
    ],
    stories: [
      story('voy', 'The long voyage',
          body: '# Chapter one\nGrandma **sailed** from Lisbon with two trunks and a violin. '
              'The crossing took three weeks.'),
    ],
    branches: [branch('pat', 'Paternal line', description: 'Smith family')],
    sources: [source('bc', 'Birth certificate', author: 'Registry office')],
  );

  List<String> people(String q) => engine.search(q).people.map((p) => p.person.id).toList();

  group('text folding', () {
    test('is accent-insensitive and length preserving', () {
      const s = 'Ana María Núñez ÉLODIE';
      expect(foldText(s), 'ana maria nunez elodie');
      expect(foldText(s).length, s.length);
    });

    test('normalizeKey collapses punctuation and spaces', () {
      expect(normalizeKey('  São   Paulo, '), 'sao paulo');
      expect(normalizeKey(null), '');
    });

    test('matchRanges finds and merges matches', () {
      expect(matchRanges('Ana María Núñez', ['maria']), [(4, 9)]);
      expect(matchRanges('Annabel', ['an', 'nab']), [(0, 5)]);
      expect(matchRanges('Smith', const []), isEmpty);
    });
  });

  group('people', () {
    test('match names ignoring case and accents', () {
      expect(people('nunez'), ['ana']);
      expect(people('MARIA'), ['ana']);
      expect(people('ana núñez'), ['ana']);
    });

    test('every word must match', () {
      expect(people('ana smith'), isEmpty);
    });

    test('match birth name and nickname with the reason', () {
      final byBirth = engine.search('ortega').people.single;
      expect(byBirth.person.id, 'ana');
      expect(byBirth.field, PersonMatchField.birthName);
      final byNick = engine.search('bob').people.single;
      expect(byNick.person.id, 'rob');
      expect(byNick.field, PersonMatchField.nickname);
    });

    test('four-digit queries match birth and death years', () {
      final born = engine.search('1950').people.single;
      expect(born.person.id, 'ana');
      expect(born.field, PersonMatchField.birthYear);
      final died = engine.search('2001').people.single;
      expect(died.person.id, 'rob');
      expect(died.field, PersonMatchField.deathYear);
      expect(people('1960'), ['rita']); // approximate year
    });

    test('prefix matches rank and are sorted', () {
      expect(people('rob'), ['rob', 'rita']);
    });
  });

  test('places group birth/death places and event locations', () {
    final r = engine.search('sao paulo');
    final place = r.places.single;
    expect(place.place, 'São Paulo');
    expect(place.bornHere, ['ana']);
    expect(place.eventIds, ['move']);

    final london = engine.search('london').places.single;
    expect(london.diedHere, ['rob']);
    expect(london.bornHere, ['rita']);
    expect(london.personIds, {'rob', 'rita'});
  });

  test('events match title, location and type', () {
    expect(engine.search('wedding').events.single.event.id, 'wed');
    expect(engine.search('marriage').events.single.event.id, 'wed');
    expect(engine.search('lisbon').events.map((e) => e.event.id), ['wed']);
    expect(engine.search('1972').events.single.event.id, 'wed');
  });

  test('stories match titles and bodies with a clean snippet', () {
    final title = engine.search('voyage').stories.single;
    expect(title.snippet, isNull);
    final body = engine.search('sailed').stories.single;
    expect(body.story.id, 'voy');
    expect(body.snippet, contains('sailed'));
    expect(body.snippet, isNot(contains('**')));
    expect(body.snippet, isNot(contains('#')));
  });

  test('branches and sources', () {
    expect(engine.search('paternal').branches.single.branch.id, 'pat');
    expect(engine.search('certificate').sources.single.source.id, 'bc');
    expect(engine.search('registry').sources.single.source.id, 'bc');
  });

  test('empty query returns nothing', () {
    final r = engine.search('   ');
    expect(r.isEmpty, isTrue);
    expect(r.total, 0);
  });

  test('totals add up across sections', () {
    final r = engine.search('lisbon');
    expect(r.total, r.people.length + r.places.length + r.events.length + r.stories.length);
    expect(r.places.single.place, 'Lisbon');
    expect(r.stories.single.story.id, 'voy');
  });

  test('snippet adds ellipses when trimmed', () {
    final filler = 'word ' * 40;
    final text = '${filler}needle $filler';
    final s = SearchEngine.snippet(text, ['needle'])!;
    expect(s.startsWith('…'), isTrue);
    expect(s.endsWith('…'), isTrue);
    expect(s, contains('needle'));
  });
}
