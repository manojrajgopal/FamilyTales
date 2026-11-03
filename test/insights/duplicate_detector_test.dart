import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/features/members/duplicate_detector.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  group('string similarity', () {
    test('Jaro–Winkler', () {
      expect(jaroWinkler('martha', 'martha'), 1);
      expect(jaroWinkler('martha', 'marhta'), closeTo(0.961, 0.001));
      expect(jaroWinkler('dwayne', 'duane'), closeTo(0.84, 0.001));
      expect(jaroWinkler('', 'abc'), 0);
      expect(jaroWinkler('abc', 'xyz'), 0);
    });

    test('Soundex', () {
      expect(soundex('robert'), 'r163');
      expect(soundex('rupert'), 'r163');
      expect(soundex('smith'), 's530');
      expect(soundex('smyth'), 's530');
      expect(soundex('ashcraft'), 'a261');
      expect(soundex('tymczak'), 't522');
      expect(soundex('pfister'), 'p236');
    });

    test('pair keys are order independent', () {
      expect(pairKey('b', 'a'), pairKey('a', 'b'));
    });
  });

  group('detection', () {
    final people = <Person>[
      person('dad', first: 'Ramesh', last: 'Smith', gender: Gender.male, birth: 'EX:1920'),
      person('mum', first: 'Lata', last: 'Smith', gender: Gender.female, birth: 'EX:1925'),
      // Same child entered twice.
      person('john1', first: 'John', last: 'Smith', gender: Gender.male, birth: 'EX:1950-03-12', birthPlace: 'Pune'),
      person('john2', first: 'Jon', last: 'Smith', gender: Gender.male, birth: 'EX:1950', birthPlace: 'Pune, India'),
      // Married name vs. maiden name.
      person('mary1', first: 'Mary', last: 'Smith', gender: Gender.female, birth: 'EX:1922'),
      person('mary2', first: 'Mary', last: 'Jones', birthName: 'Mary Smith', gender: Gender.female, birth: 'EX:1922'),
      // Same name, different generations.
      person('old', first: 'Peter', last: 'Brown', gender: Gender.male, birth: 'EX:1890'),
      person('young', first: 'Peter', last: 'Brown', gender: Gender.male, birth: 'EX:1960'),
      // Same name, different gender.
      person('alex1', first: 'Alex', last: 'Kumar', gender: Gender.male, birth: 'EX:1980'),
      person('alex2', first: 'Alex', last: 'Kumar', gender: Gender.female, birth: 'EX:1980'),
      // Partners who happen to share a name.
      person('sam1', first: 'Sam', last: 'Lee', birth: 'EX:1970'),
      person('sam2', first: 'Sam', last: 'Lee', birth: 'EX:1970'),
      // Parent and child with the same name and no dates.
      person('tom1', first: 'Tom', last: 'Gray', gender: Gender.male),
      person('tom2', first: 'Tom', last: 'Gray', gender: Gender.male),
      // Siblings with different names.
      person('anil', first: 'Anil', last: 'Smith', gender: Gender.male, birth: 'EX:1952'),
      person('amit', first: 'Amit', last: 'Smith', gender: Gender.male, birth: 'EX:1952'),
    ];
    final graph = graphOf(
      people,
      links: [
        link('dad', 'john1'), link('mum', 'john1'),
        link('dad', 'john2'),
        link('dad', 'anil'), link('mum', 'anil'),
        link('dad', 'amit'), link('mum', 'amit'),
        link('tom1', 'tom2'),
      ],
      couples: [couple('dad', 'mum'), couple('sam1', 'sam2')],
    );
    final detector = DuplicateDetector(graph);
    final found = detector.find();
    final byKey = {for (final c in found) c.key: c};

    test('finds the same child entered twice', () {
      final c = byKey[pairKey('john1', 'john2')];
      expect(c, isNotNull);
      expect(c!.score, greaterThan(0.7));
      expect(c.reasons, contains('Very similar names'));
      expect(c.reasons, contains('Both born in 1950'));
      expect(c.reasons, contains('Both born in Pune'));
      expect(c.reasons.any((r) => r.startsWith('Shared parent')), isTrue);
    });

    test('matches a maiden name against a married name', () {
      final c = byKey[pairKey('mary1', 'mary2')];
      expect(c, isNotNull);
      expect(c!.reasons, contains('Birth name matches'));
      expect(c.reasons, contains('Both born in 1922'));
    });

    test('ignores people with distant birth years, other gender or direct links', () {
      expect(byKey.containsKey(pairKey('old', 'young')), isFalse);
      expect(byKey.containsKey(pairKey('alex1', 'alex2')), isFalse);
      expect(byKey.containsKey(pairKey('sam1', 'sam2')), isFalse);
      expect(byKey.containsKey(pairKey('tom1', 'tom2')), isFalse);
      expect(byKey.containsKey(pairKey('anil', 'amit')), isFalse);
      expect(byKey.containsKey(pairKey('dad', 'mum')), isFalse);
    });

    test('results are sorted by score and respect the threshold', () {
      for (var i = 1; i < found.length; i++) {
        expect(found[i - 1].score, greaterThanOrEqualTo(found[i].score));
      }
      expect(found.every((c) => c.score >= detector.threshold), isTrue);
    });

    test('dismissed pairs are skipped', () {
      final again = DuplicateDetector(graph).find(dismissed: {pairKey('john2', 'john1')});
      expect(again.any((c) => c.key == pairKey('john1', 'john2')), isFalse);
      expect(again.any((c) => c.key == pairKey('mary1', 'mary2')), isTrue);
    });

    test('background detection gives the same answer', () async {
      final bg = await findDuplicatesInBackground(graph);
      expect(bg.map((c) => c.key).toList(), found.map((c) => c.key).toList());
    });
  });

  test('blocking avoids comparing every pair in large trees', () {
    const syllables = ['ka', 'ri', 'mo', 'te', 'su', 'lan', 'dor', 'vi', 'ne', 'pa', 'go', 'hel', 'ber', 'ston', 'ward', 'field'];
    const givens = ['Aarav', 'Bina', 'Carlos', 'Dina', 'Elif', 'Femi', 'Gita', 'Hugo', 'Ines', 'Jun',
      'Kiran', 'Lena', 'Mateo', 'Nora', 'Omar', 'Priya', 'Quinn', 'Rosa', 'Sven', 'Tara'];
    final people = <Person>[
      for (var i = 0; i < 2000; i++)
        person(
          'p$i',
          first: givens[i % givens.length],
          last: '${syllables[i % 16]}${syllables[(i ~/ 16) % 16]}${syllables[(i * 7 ~/ 5) % 16]}',
          birth: 'EX:${1850 + (i * 37) % 170}',
        ),
    ];
    final detector = DuplicateDetector(graphOf(people));
    final sw = Stopwatch()..start();
    detector.find();
    sw.stop();
    const allPairs = 2000 * 1999 ~/ 2;
    expect(detector.candidatePairs().length, lessThan(allPairs ~/ 20));
    expect(detector.comparisons, lessThan(allPairs ~/ 20));
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
  });
}
