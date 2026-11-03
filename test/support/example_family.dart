import 'package:drift/drift.dart';

import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/core/models/fuzzy_date.dart';
import 'package:family_tales/core/repositories/content_repository.dart';
import 'package:family_tales/core/repositories/family_repository.dart';

/// Test fixture: builds a self-contained example tree (flagged `isExample`).
/// The app itself ships no sample data.
///
/// The family deliberately includes complex structures: remarriage after a
/// divorce, half-siblings, a step-parent, an adopted child, approximate and
/// year-only dates, and five generations.
class ExampleFamilyBuilder {
  ExampleFamilyBuilder(this.db)
      : family = FamilyRepository(db),
        content = ContentRepository(db);

  final AppDatabase db;
  final FamilyRepository family;
  final ContentRepository content;

  Future<String> build() async {
    return db.transaction(() async {
      final tree = await family.createTree(
        'Example · Nair & Wilson family',
        description: 'A sample family to explore. Delete it any time from Family trees.',
        isExample: true,
      );

      Future<String> p(
        String first,
        String last,
        Gender g, {
        String? birth,
        String? death,
        String? birthPlace,
        String? deathPlace,
        String? birthName,
        String? occupation,
        String? bio,
        String? nickname,
      }) =>
          family.createPerson(PersonsCompanion.insert(
            id: newId(),
            treeId: tree,
            firstName: Value(first),
            lastName: Value(last),
            gender: Value(g),
            birthName: Value(birthName),
            nickname: Value(nickname),
            birthDate: Value(birth),
            birthPlace: Value(birthPlace),
            isLiving: Value(death == null),
            deathDate: Value(death == 'unknown' ? null : death),
            deathPlace: Value(deathPlace),
            occupation: Value(occupation),
            biography: Value(bio),
          ));

      String ex(int y, [int? m, int? d]) => FuzzyDate.ymd(y, m, d).serialize();
      String abt(int y) => FuzzyDate(qualifier: DateQualifier.about, year: y).serialize();

      // Generation 1
      final gopal = await p('Gopal', 'Nair', Gender.male,
          birth: abt(1912), death: ex(1988, 7, 14), birthPlace: 'Palakkad, Kerala',
          deathPlace: 'Kochi, Kerala', occupation: 'Schoolteacher',
          bio: 'Taught mathematics for forty years and kept the family’s first written records.');
      final lakshmi = await p('Lakshmi', 'Nair', Gender.female,
          birthName: 'Menon', birth: ex(1918), death: ex(2001, 2, 3), birthPlace: 'Thrissur, Kerala',
          bio: 'Known for her garden, her stories and her legendary payasam.');
      final arthur = await p('Arthur', 'Wilson', Gender.male,
          birth: ex(1920, 5, 2), death: ex(1995, 11, 20), birthPlace: 'Leeds, England',
          occupation: 'Railway engineer');
      final edith = await p('Edith', 'Wilson', Gender.female,
          birthName: 'Clarke', birth: FuzzyDate(qualifier: DateQualifier.before, year: 1925).serialize(),
          death: ex(2010), birthPlace: 'York, England');

      // Generation 2
      final raman = await p('Raman', 'Nair', Gender.male,
          birth: ex(1940, 1, 12), death: ex(2015, 9, 1), birthPlace: 'Palakkad, Kerala', occupation: 'Doctor');
      final devaki = await p('Devaki', 'Nair', Gender.female, birth: ex(1945, 6), death: ex(2020));
      final sarada = await p('Sarada', 'Pillai', Gender.female,
          birthName: 'Nair', birth: ex(1944, 8, 21), birthPlace: 'Palakkad, Kerala', occupation: 'Botanist');
      final krishnan = await p('Krishnan', 'Nair', Gender.male,
          birth: ex(1948, 3, 30), birthPlace: 'Kochi, Kerala', occupation: 'Architect', nickname: 'Kittu');
      final margaret = await p('Margaret', 'Reed', Gender.female,
          birthName: 'Wilson', birth: ex(1948, 12, 4), birthPlace: 'Leeds, England', occupation: 'Journalist');
      final george = await p('George', 'Wilson', Gender.male,
          birth: ex(1951, 4, 9), death: ex(2019, 1, 15), birthPlace: 'Leeds, England');
      final susan = await p('Susan', 'Wilson', Gender.female, birth: ex(1953));
      final leela = await p('Leela', 'Nair', Gender.female, birth: ex(1960, 10, 2), occupation: 'Musician');
      final thomas = await p('Thomas', 'Reed', Gender.male, birth: abt(1946), occupation: 'Photographer');

      // Generation 3
      final suresh = await p('Suresh', 'Nair', Gender.male, birth: ex(1968, 2, 14), occupation: 'Engineer');
      final neha = await p('Neha', 'Nair', Gender.female, birth: ex(1970, 7, 7));
      final anita = await p('Anita', 'Nair', Gender.female, birth: ex(1971, 11, 23));
      final arjun = await p('Arjun', 'Nair', Gender.male,
          birth: ex(1975, 6, 18), birthPlace: 'Bengaluru, India', occupation: 'Software architect',
          bio: 'Started this family tree to keep our stories for the next generation.');
      final priya = await p('Priya', 'Nair', Gender.female, birthName: 'Iyer', birth: ex(1977, 9, 5));
      final maya = await p('Maya', 'Nair', Gender.female, birth: ex(1978, 1, 30), occupation: 'Doctor');
      final kavya = await p('Kavya', 'Nair', Gender.female, birth: ex(1994, 4, 11));
      final daniel = await p('Daniel', 'Wilson', Gender.male, birth: ex(1985));

      // Generation 4
      final aditya = await p('Aditya', 'Nair', Gender.male, birth: ex(1998, 12, 1));
      final rohan = await p('Rohan', 'Nair', Gender.male, birth: ex(2005, 3, 22));
      final isha = await p('Isha', 'Nair', Gender.female, birth: ex(2009, 11, 8));

      Future<void> kids(List<String> parents, List<String> children, [ParentType t = ParentType.biological]) async {
        for (final c in children) {
          for (final par in parents) {
            await family.addParent(childId: c, parentId: par, type: t);
          }
        }
      }

      await family.addPartnership(a: gopal, b: lakshmi, start: FuzzyDate.ymd(1938, 5, 16), place: 'Guruvayur, Kerala');
      await family.addPartnership(a: arthur, b: edith, start: FuzzyDate.ymd(1946));
      await family.addPartnership(a: raman, b: devaki, start: FuzzyDate.ymd(1966, 1, 22));
      await family.addPartnership(
          a: krishnan, b: margaret, status: PartnerStatus.divorced, start: FuzzyDate.ymd(1973, 8, 11), end: FuzzyDate.ymd(1989));
      await family.addPartnership(a: krishnan, b: leela, start: FuzzyDate.ymd(1992, 2, 9));
      await family.addPartnership(a: margaret, b: thomas, start: FuzzyDate.ymd(1995, 6, 3));
      await family.addPartnership(a: george, b: susan, start: FuzzyDate.ymd(1979));
      await family.addPartnership(a: suresh, b: neha, start: FuzzyDate.ymd(1996, 11, 28));
      await family.addPartnership(a: arjun, b: priya, start: FuzzyDate.ymd(2002, 12, 12), place: 'Chennai, India');

      await kids([gopal, lakshmi], [raman, sarada, krishnan]);
      await kids([arthur, edith], [margaret, george]);
      await kids([raman, devaki], [suresh, anita]);
      await kids([krishnan, margaret], [arjun, maya]);
      await kids([krishnan, leela], [kavya]);
      await kids([thomas], [maya], ParentType.step);
      await kids([george, susan], [daniel], ParentType.adoptive);
      await kids([suresh, neha], [aditya]);
      await kids([arjun, priya], [rohan, isha]);

      await family.updateTree(tree, homePersonId: arjun);

      await content.saveEvent(
        treeId: tree,
        title: 'Wilson family moves to Kochi',
        type: EventType.migration,
        date: FuzzyDate(qualifier: DateQualifier.about, year: 1965).serialize(),
        location: 'Kochi, Kerala',
        description: 'Arthur took a post with the railways and the family sailed from Southampton.',
        people: {arthur: null, edith: null, margaret: null, george: null},
      );
      await content.saveEvent(
        treeId: tree,
        title: 'Arjun graduates',
        type: EventType.graduation,
        date: FuzzyDate.ymd(1997, 5, 30).serialize(),
        location: 'IISc, Bengaluru',
        people: {arjun: 'Graduate'},
      );
      await content.saveEvent(
        treeId: tree,
        title: 'Nair family reunion',
        type: EventType.familyReunion,
        date: FuzzyDate.ymd(2018, 12, 26).serialize(),
        location: 'Palakkad, Kerala',
        description: 'Four generations together for the first time.',
        remind: true,
        people: {
          for (final x in [sarada, krishnan, margaret, leela, suresh, neha, anita, arjun, priya, maya, kavya, aditya, rohan, isha])
            x: null
        },
      );
      await content.saveStory(
        treeId: tree,
        title: 'How Gopal and Lakshmi met',
        historicalDate: FuzzyDate(qualifier: DateQualifier.about, year: 1937).serialize(),
        body: '## A borrowed umbrella\n\n'
            'It was the first heavy rain of the monsoon. **Gopal** had just started teaching in Thrissur '
            'and, being Gopal, had forgotten his umbrella.\n\n'
            '> "She lent me her umbrella and told me to bring it back the next day. I brought it back every day for a month."\n\n'
            'They married the following May at Guruvayur.\n\n'
            '- The umbrella is still with Sarada.\n'
            '- _Told by Lakshmi to her grandchildren, 1995._',
        personIds: [gopal, lakshmi],
      );
      return tree;
    });
  }
}
