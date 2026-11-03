import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/features/branches/branch_logic.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  // Paternal side: ggf & ggm → gf; gf & gm → f
  // Maternal side: mggm → mgm; mgf & mgm → m
  // f & m → home; home has a sibling "sis".
  final people = [
    person('ggf', first: 'Arjun', last: 'Rao', gender: Gender.male),
    person('ggm', first: 'Bela', last: 'Rao', gender: Gender.female),
    person('gf', first: 'Chetan', last: 'Rao', gender: Gender.male),
    person('gm', first: 'Devi', last: 'Kulkarni', gender: Gender.female),
    person('f', first: 'Eshan', last: 'Rao', gender: Gender.male),
    person('mggm', first: 'Farah', last: 'Iyer', gender: Gender.female),
    person('mgf', first: 'Gopal', last: 'Menon', gender: Gender.male),
    person('mgm', first: 'Hema', last: 'Menon', gender: Gender.female),
    person('m', first: 'Indira', last: 'Rao', gender: Gender.female),
    person('home', first: 'Jaya', last: 'Rao', gender: Gender.female),
    person('sis', first: 'Kavya', last: 'Rao', gender: Gender.female),
    person('friend', first: 'Leo', last: 'Fernandes'),
  ];
  final links = [
    link('ggf', 'gf'), link('ggm', 'gf'),
    link('gf', 'f'), link('gm', 'f'),
    link('mggm', 'mgm'),
    link('mgf', 'm'), link('mgm', 'm'),
    link('f', 'home'), link('m', 'home'),
    link('f', 'sis'), link('m', 'sis'),
  ];
  final couples = [couple('ggf', 'ggm'), couple('gf', 'gm'), couple('mgf', 'mgm'), couple('f', 'm')];
  final g = graphOf(people, links: links, couples: couples);

  group('branchMembers', () {
    test('root, descendants and their partners plus explicit members', () {
      final b = branch('b1', 'Rao line', root: 'gf');
      final explicit = [
        const PersonBranch(personId: 'friend', branchId: 'b1'),
        const PersonBranch(personId: 'mgf', branchId: 'other'), // other branch
        const PersonBranch(personId: 'trashed', branchId: 'b1'), // not in graph
      ];
      expect(branchMembers(b, g, explicit), {'gf', 'gm', 'f', 'm', 'home', 'sis', 'friend'});
    });

    test('without a root only explicit members count', () {
      final b = branch('b2', 'Friends');
      expect(branchMembers(b, g, const [PersonBranch(personId: 'friend', branchId: 'b2')]), {'friend'});
      expect(branchMembers(b, g, const []), isEmpty);
    });

    test('unknown root contributes nothing', () {
      expect(branchMembers(branch('b3', 'Ghost', root: 'missing'), g, const []), isEmpty);
    });

    test('orderedMembers puts the root first then older generations', () {
      final members = branchMembers(branch('b1', 'Rao line', root: 'gf'), g, const []);
      final ordered = orderedMembers(members, g, rootId: 'gf');
      expect(ordered.first, 'gf');
      expect(ordered.indexOf('f'), lessThan(ordered.indexOf('home')));
    });
  });

  group('ancestors', () {
    test('father and mother are found by gender', () {
      expect(parentWithGender(g, 'home', Gender.male), 'f');
      expect(parentWithGender(g, 'home', Gender.female), 'm');
    });

    test('topmost ancestor follows the preferred line', () {
      expect(topmostAncestor(g, 'f', Gender.male), 'ggf');
      expect(topmostAncestor(g, 'm', Gender.female), 'mggm');
      expect(topmostAncestor(g, 'ggf', Gender.male), 'ggf');
    });
  });

  group('suggestions', () {
    test('paternal, maternal and root lines', () {
      final s = suggestBranches(g, homePersonId: 'home');
      final byName = {for (final x in s) x.name: x};
      expect(byName['Paternal line']?.rootId, 'ggf');
      expect(byName['Paternal line']?.kind, SuggestionKind.paternal);
      expect(byName['Maternal line']?.rootId, 'mggm');
      // Root lines whose roots are already suggested are not repeated.
      expect(s.where((x) => x.rootId == 'ggf').length, 1);
      expect(s.where((x) => x.rootId == 'mggm').length, 1);
      // Other root couples become "{Surname} line".
      expect(byName['Kulkarni line']?.rootId, 'gm');
      expect(byName['Menon line']?.rootId, 'mgf');
      // ggf line: ggf, ggm, gf, gm, f, m, home, sis
      expect(byName['Paternal line']?.memberCount, 8);
    });

    test('existing branches hide matching suggestions', () {
      final s = suggestBranches(
        g,
        homePersonId: 'home',
        existing: [
          branch('x', 'Anything', root: 'ggf'),
          branch('y', 'maternal LINE'),
        ],
      );
      final names = s.map((x) => x.name).toList();
      expect(names, isNot(contains('Paternal line')));
      expect(names, isNot(contains('Maternal line')));
      expect(names, contains('Kulkarni line'));
    });

    test('no parents means no paternal or maternal suggestion', () {
      final s = suggestBranches(g, homePersonId: 'ggf');
      expect(s.any((x) => x.kind != SuggestionKind.rootLine), isFalse);
      expect(s.map((x) => x.rootId), contains('ggf'));
    });

    test('empty graph gives no suggestions', () {
      expect(suggestBranches(graphOf(const []), homePersonId: null), isEmpty);
    });
  });
}
