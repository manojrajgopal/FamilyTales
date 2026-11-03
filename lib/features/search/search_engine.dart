import '../../core/database/app_database.dart';
import '../../core/models/fuzzy_date.dart';
import '../family/domain/family_graph.dart';
import 'text_normalize.dart';

/// Why a person matched (shown under their name).
enum PersonMatchField {
  name('Name'),
  birthName('Birth name'),
  nickname('Nickname'),
  birthYear('Born'),
  deathYear('Died');

  const PersonMatchField(this.label);
  final String label;
}

class PersonResult {
  const PersonResult(this.person, this.score, this.field);
  final Person person;
  final int score;
  final PersonMatchField field;
}

/// A place and everything recorded there.
class PlaceResult {
  const PlaceResult({
    required this.place,
    required this.score,
    required this.bornHere,
    required this.diedHere,
    required this.eventIds,
  });

  final String place;
  final int score;
  final List<String> bornHere;
  final List<String> diedHere;
  final List<String> eventIds;

  /// Distinct people connected to the place.
  Set<String> get personIds => {...bornHere, ...diedHere};
}

class EventResult {
  const EventResult(this.event, this.score);
  final FamilyEvent event;
  final int score;
}

class StoryResult {
  const StoryResult(this.story, this.score, this.snippet);
  final Story story;
  final int score;

  /// Plain-text excerpt around the first body match (null for title-only
  /// matches).
  final String? snippet;
}

class BranchResult {
  const BranchResult(this.branch, this.score);
  final FamilyBranch branch;
  final int score;
}

class SourceResult {
  const SourceResult(this.source, this.score);
  final Source source;
  final int score;
}

class SearchResults {
  const SearchResults({
    required this.query,
    required this.tokens,
    this.people = const [],
    this.places = const [],
    this.events = const [],
    this.stories = const [],
    this.branches = const [],
    this.sources = const [],
  });

  static const empty = SearchResults(query: '', tokens: []);

  final String query;

  /// Folded query tokens – use with `matchRanges` to highlight.
  final List<String> tokens;
  final List<PersonResult> people;
  final List<PlaceResult> places;
  final List<EventResult> events;
  final List<StoryResult> stories;
  final List<BranchResult> branches;
  final List<SourceResult> sources;

  int get total =>
      people.length + places.length + events.length + stories.length + branches.length + sources.length;
  bool get isEmpty => total == 0;
}

class _PlaceEntry {
  _PlaceEntry(this.key);
  final String key;
  final Map<String, int> variants = {};
  final List<String> born = [];
  final List<String> died = [];
  final List<String> events = [];

  /// Most frequent spelling; ties go to the first one recorded.
  String get label {
    MapEntry<String, int>? best;
    for (final e in variants.entries) {
      if (best == null || e.value > best.value) best = e;
    }
    return best!.key;
  }
}

class _PersonIndex {
  _PersonIndex(this.person)
      : name = foldText([
          person.displayName,
          person.firstName,
          person.middleName ?? '',
          person.lastName ?? '',
        ].join(' ')),
        display = foldText(person.displayName),
        birthName = foldText(person.birthName ?? ''),
        nickname = foldText(person.nickname ?? ''),
        birthYear = person.birth?.approxYear,
        deathYear = person.death?.approxYear;

  final Person person;
  final String name;
  final String display;
  final String birthName;
  final String nickname;
  final int? birthYear;
  final int? deathYear;
}

/// In-memory full-text search over one tree. Matching is case- and
/// accent-insensitive; every query word must match (AND). Build once per
/// data change and call [search] as the user types.
class SearchEngine {
  SearchEngine({
    required this.graph,
    List<FamilyEvent> events = const [],
    List<Story> stories = const [],
    List<FamilyBranch> branches = const [],
    List<Source> sources = const [],
  })  : _events = [for (final e in events) (e, foldText(_eventText(e)))],
        _stories = [for (final s in stories) _storyEntry(s)],
        _branches = [
          for (final b in branches) (b, foldText(b.name), foldText(b.description ?? '')),
        ],
        _sources = [
          for (final s in sources)
            (s, foldText(s.title), foldText([s.author, s.repository].whereType<String>().join(' '))),
        ],
        eventsById = {for (final e in events) e.id: e},
        _people = [for (final p in graph.people.values) _PersonIndex(p)] {
    void addPlace(String? raw, void Function(_PlaceEntry e) add) {
      if (raw == null) return;
      final label = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
      final key = normalizeKey(label);
      if (key.isEmpty) return;
      final entry = _places[key] ??= _PlaceEntry(key);
      entry.variants[label] = (entry.variants[label] ?? 0) + 1;
      add(entry);
    }

    for (final p in graph.people.values) {
      addPlace(p.birthPlace, (e) => e.born.add(p.id));
      addPlace(p.deathPlace, (e) => e.died.add(p.id));
    }
    for (final e in events) {
      addPlace(e.location, (x) => x.events.add(e.id));
    }
  }

  final FamilyGraph graph;
  final Map<String, FamilyEvent> eventsById;
  final List<_PersonIndex> _people;
  final List<(FamilyEvent, String)> _events;
  final List<(Story, String, String, String)> _stories;
  final List<(FamilyBranch, String, String)> _branches;
  final List<(Source, String, String)> _sources;
  final Map<String, _PlaceEntry> _places = {};

  static String _eventText(FamilyEvent e) => [
        e.title,
        e.location ?? '',
        e.type.label,
        e.customLabel ?? '',
      ].join(' \u0000 ');

  static (Story, String, String, String) _storyEntry(Story s) {
    final body = plainText(s.body);
    return (s, foldText(s.title), body, foldText(body));
  }

  static final _markup = RegExp(r'[#*_>`~\[\]]');

  /// Markdown-free single-line version of a story body.
  static String plainText(String body) =>
      body.replaceAll(_markup, '').replaceAll(RegExp(r'\s+'), ' ').trim();

  static final _yearQuery = RegExp(r'^\d{4}$');

  /// Scores how well [token] matches [field] (0 = no match).
  static int _tokenScore(String field, String token) {
    if (field.isEmpty) return 0;
    final i = field.indexOf(token);
    if (i < 0) return 0;
    if (field.length == token.length) return 100;
    if (i == 0) return 80;
    // Word start?
    var idx = i;
    while (idx >= 0) {
      if (idx == 0 || !_isWordChar(field.codeUnitAt(idx - 1))) return 60;
      idx = field.indexOf(token, idx + 1);
      if (idx < 0) break;
    }
    return 35;
  }

  static bool _isWordChar(int u) =>
      (u >= 0x30 && u <= 0x39) || (u >= 0x61 && u <= 0x7A) || u > 0x7F;

  /// Score of all tokens against a set of fields: every token must match at
  /// least one field; the best field per token counts.
  static int _allTokens(List<String> tokens, List<String> fields) {
    var total = 0;
    for (final t in tokens) {
      var best = 0;
      for (final f in fields) {
        final s = _tokenScore(f, t);
        if (s > best) best = s;
      }
      if (best == 0) return 0;
      total += best;
    }
    return total;
  }

  SearchResults search(String query, {int limit = 200}) {
    final tokens = queryTokens(query);
    if (tokens.isEmpty) return SearchResults.empty;
    final trimmed = query.trim();
    final year = _yearQuery.hasMatch(trimmed) ? int.parse(trimmed) : null;

    // ------------------------------------------------------------ people
    final people = <PersonResult>[];
    for (final p in _people) {
      final nameScore = _allTokens(tokens, [p.name]);
      if (nameScore > 0) {
        // Bonus when the visible name itself matches.
        final bonus = _allTokens(tokens, [p.display]) > 0 ? 20 : 0;
        people.add(PersonResult(p.person, nameScore + bonus, PersonMatchField.name));
        continue;
      }
      final birthScore = _allTokens(tokens, [p.name, p.birthName]);
      if (birthScore > 0 && p.birthName.isNotEmpty) {
        people.add(PersonResult(p.person, birthScore - 5, PersonMatchField.birthName));
        continue;
      }
      final nickScore = _allTokens(tokens, [p.name, p.birthName, p.nickname]);
      if (nickScore > 0 && p.nickname.isNotEmpty) {
        people.add(PersonResult(p.person, nickScore - 5, PersonMatchField.nickname));
        continue;
      }
      if (year != null) {
        if (p.birthYear == year) {
          people.add(PersonResult(p.person, 70, PersonMatchField.birthYear));
        } else if (p.deathYear == year) {
          people.add(PersonResult(p.person, 60, PersonMatchField.deathYear));
        }
      }
    }
    people.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : a.person.displayName.toLowerCase().compareTo(b.person.displayName.toLowerCase());
    });

    // ------------------------------------------------------------ places
    final places = <PlaceResult>[];
    for (final e in _places.values) {
      final s = _allTokens(tokens, [e.key]);
      if (s == 0) continue;
      places.add(PlaceResult(
        place: e.label,
        score: s,
        bornHere: List.unmodifiable(e.born.toSet()),
        diedHere: List.unmodifiable(e.died.toSet()),
        eventIds: List.unmodifiable(e.events.toSet()),
      ));
    }
    places.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      final n = (b.personIds.length + b.eventIds.length).compareTo(a.personIds.length + a.eventIds.length);
      return n != 0 ? n : a.place.toLowerCase().compareTo(b.place.toLowerCase());
    });

    // ------------------------------------------------------------ events
    final events = <EventResult>[];
    for (final (e, text) in _events) {
      var s = _allTokens(tokens, [text]);
      if (s == 0 && year != null && FuzzyDate.tryParse(e.date)?.approxYear == year) s = 50;
      if (s > 0) events.add(EventResult(e, s));
    }
    events.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : a.event.title.toLowerCase().compareTo(b.event.title.toLowerCase());
    });

    // ----------------------------------------------------------- stories
    final stories = <StoryResult>[];
    for (final (s, title, body, foldedBody) in _stories) {
      final titleScore = _allTokens(tokens, [title]);
      if (titleScore > 0) {
        stories.add(StoryResult(s, titleScore + 20, null));
        continue;
      }
      final bodyScore = _allTokens(tokens, [title, foldedBody]);
      if (bodyScore > 0) {
        stories.add(StoryResult(s, bodyScore ~/ 2, snippet(body, tokens)));
        continue;
      }
      if (year != null && FuzzyDate.tryParse(s.historicalDate)?.approxYear == year) {
        stories.add(StoryResult(s, 30, null));
      }
    }
    stories.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : a.story.title.toLowerCase().compareTo(b.story.title.toLowerCase());
    });

    // ---------------------------------------------------------- branches
    final branches = <BranchResult>[
      for (final (b, name, desc) in _branches)
        if (_allTokens(tokens, [name, desc]) case final s when s > 0) BranchResult(b, s),
    ]..sort((a, b) {
        final c = b.score.compareTo(a.score);
        return c != 0 ? c : a.branch.name.toLowerCase().compareTo(b.branch.name.toLowerCase());
      });

    // ----------------------------------------------------------- sources
    final sources = <SourceResult>[];
    for (final (s, title, meta) in _sources) {
      final t = _allTokens(tokens, [title]);
      if (t > 0) {
        sources.add(SourceResult(s, t + 10));
        continue;
      }
      final m = _allTokens(tokens, [title, meta]);
      if (m > 0) sources.add(SourceResult(s, m ~/ 2));
    }
    sources.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : a.source.title.toLowerCase().compareTo(b.source.title.toLowerCase());
    });

    List<T> cap<T>(List<T> l) => l.length > limit ? l.sublist(0, limit) : l;
    return SearchResults(
      query: trimmed,
      tokens: tokens,
      people: cap(people),
      places: cap(places),
      events: cap(events),
      stories: cap(stories),
      branches: cap(branches),
      sources: cap(sources),
    );
  }

  /// Excerpt of [text] around the first match of any token.
  static String? snippet(String text, List<String> tokens, {int before = 36, int after = 84}) {
    final folded = foldText(text);
    var first = -1;
    for (final t in tokens) {
      final i = folded.indexOf(t);
      if (i >= 0 && (first < 0 || i < first)) first = i;
    }
    if (first < 0) return null;
    var start = first - before;
    var end = first + after;
    if (start < 0) start = 0;
    if (end > text.length) end = text.length;
    // Avoid cutting words in half.
    if (start > 0) {
      final space = text.indexOf(' ', start);
      if (space >= 0 && space < first) start = space + 1;
    }
    if (end < text.length) {
      final space = text.lastIndexOf(' ', end);
      if (space > first) end = space;
    }
    return '${start > 0 ? '…' : ''}${text.substring(start, end)}${end < text.length ? '…' : ''}';
  }
}
