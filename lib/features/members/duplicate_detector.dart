import 'dart:isolate';
import 'dart:math' as math;

import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/models/fuzzy_date.dart';
import '../family/domain/family_graph.dart';
import '../search/text_normalize.dart';

/// Canonical, order-independent key of a pair of people.
String pairKey(String a, String b) => a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';

/// A pair of people that may be the same person. Detection only suggests –
/// merging always requires an explicit user decision.
class DuplicateCandidate {
  const DuplicateCandidate({
    required this.aId,
    required this.bId,
    required this.score,
    required this.reasons,
  });

  final String aId;
  final String bId;

  /// Confidence between 0 and 1.
  final double score;

  /// Human-readable evidence, strongest first.
  final List<String> reasons;

  String get key => pairKey(aId, bId);
  int get percent => (score * 100).round();

  @override
  String toString() => 'DuplicateCandidate($aId, $bId, $percent%, $reasons)';
}

/// Jaro–Winkler similarity (0 = nothing in common, 1 = identical).
double jaroWinkler(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  final range = math.max(0, math.max(a.length, b.length) ~/ 2 - 1);
  final aMatched = List<bool>.filled(a.length, false);
  final bMatched = List<bool>.filled(b.length, false);
  var matches = 0;
  for (var i = 0; i < a.length; i++) {
    final start = math.max(0, i - range);
    final end = math.min(i + range + 1, b.length);
    for (var j = start; j < end; j++) {
      if (bMatched[j] || a.codeUnitAt(i) != b.codeUnitAt(j)) continue;
      aMatched[i] = true;
      bMatched[j] = true;
      matches++;
      break;
    }
  }
  if (matches == 0) return 0;
  var transpositions = 0;
  var k = 0;
  for (var i = 0; i < a.length; i++) {
    if (!aMatched[i]) continue;
    while (!bMatched[k]) {
      k++;
    }
    if (a.codeUnitAt(i) != b.codeUnitAt(k)) transpositions++;
    k++;
  }
  final m = matches.toDouble();
  final jaro = (m / a.length + m / b.length + (m - transpositions / 2) / m) / 3;
  var prefix = 0;
  for (var i = 0; i < math.min(4, math.min(a.length, b.length)); i++) {
    if (a.codeUnitAt(i) != b.codeUnitAt(i)) break;
    prefix++;
  }
  return jaro + prefix * 0.1 * (1 - jaro);
}

/// American Soundex of an already folded word ("smith" → "s530"). Falls
/// back to the first three characters for non-Latin scripts.
String soundex(String word) {
  final letters = word.replaceAll(RegExp(r'[^a-z]'), '');
  if (letters.isEmpty) {
    final w = word.replaceAll(' ', '');
    return w.length > 3 ? w.substring(0, 3) : w;
  }
  const codes = {
    'b': '1', 'f': '1', 'p': '1', 'v': '1',
    'c': '2', 'g': '2', 'j': '2', 'k': '2', 'q': '2', 's': '2', 'x': '2', 'z': '2',
    'd': '3', 't': '3',
    'l': '4',
    'm': '5', 'n': '5',
    'r': '6',
  };
  final out = StringBuffer(letters[0]);
  var last = codes[letters[0]] ?? '';
  for (var i = 1; i < letters.length && out.length < 4; i++) {
    final ch = letters[i];
    final code = codes[ch];
    if (code == null) {
      // Vowels separate equal codes; h and w do not.
      if (ch != 'h' && ch != 'w') last = '';
      continue;
    }
    if (code != last) out.write(code);
    last = code;
  }
  return out.toString().padRight(4, '0');
}

class _Profile {
  _Profile(this.p, FamilyGraph g)
      : full = normalizeKey(p.displayName),
        given = _given(p),
        surname = _surname(p),
        birthSurname = _lastToken(normalizeKey(p.birthName)),
        nickname = normalizeKey(p.nickname),
        birth = p.birth,
        deathYear = p.death?.approxYear,
        birthPlace = normalizeKey(p.birthPlace),
        birthPlaceHead = normalizeKey(p.birthPlace?.split(',').first),
        parents = g.kinParents(p.id).toSet(),
        partners = g.partnerIds(p.id).toSet();

  final Person p;
  final String full;
  final String given;
  final String surname;
  final String birthSurname;
  final String nickname;
  final FuzzyDate? birth;
  final int? deathYear;
  final String birthPlace;
  final String birthPlaceHead;
  final Set<String> parents;
  final Set<String> partners;

  int? get birthYear => birth?.approxYear;

  bool get hasName =>
      p.firstName.trim().isNotEmpty ||
      (p.lastName ?? '').trim().isNotEmpty ||
      (p.fullName ?? '').trim().isNotEmpty;

  static String _lastToken(String s) {
    if (s.isEmpty) return s;
    final parts = s.split(' ');
    return parts.last;
  }

  static String _given(Person p) {
    final f = normalizeKey(p.firstName);
    if (f.isNotEmpty) return f.split(' ').first;
    final full = normalizeKey(p.fullName);
    return full.isEmpty ? '' : full.split(' ').first;
  }

  static String _surname(Person p) {
    final l = normalizeKey(p.lastName);
    if (l.isNotEmpty) return _lastToken(l);
    final full = normalizeKey(p.fullName);
    final parts = full.split(' ').where((s) => s.isNotEmpty).toList();
    return parts.length > 1 ? parts.last : '';
  }
}

/// Finds likely duplicate people within one tree.
///
/// Candidate pairs are generated with *blocking* (people sharing a phonetic
/// surname / birth-name key, a given-name initial + birth year, or a parent)
/// so large trees never need a full O(n²) comparison. Each pair is scored
/// from name similarity (Jaro–Winkler on accent-folded names), birth date,
/// birthplace, shared parents/partners, death year and gender.
class DuplicateDetector {
  DuplicateDetector(this.graph, {this.threshold = 0.5, this.maxBlockSize = 400})
      : _profiles = {
          for (final p in graph.people.values) p.id: _Profile(p, graph),
        };

  final FamilyGraph graph;

  /// Minimum score (0–1) for a pair to be reported.
  final double threshold;

  /// Blocks larger than this are split further by given-name initial.
  final int maxBlockSize;
  final Map<String, _Profile> _profiles;

  /// Number of pairs scored by the last [find] call (for diagnostics/tests).
  int comparisons = 0;

  /// Candidate pair keys produced by blocking.
  Set<String> candidatePairs() {
    final blocks = <String, List<String>>{};
    void put(String key, String id) => (blocks[key] ??= []).add(id);

    for (final pr in _profiles.values) {
      if (!pr.hasName) continue;
      final id = pr.p.id;
      final keys = <String>{};
      if (pr.surname.isNotEmpty) keys.add('s:${soundex(pr.surname)}');
      if (pr.birthSurname.isNotEmpty) keys.add('s:${soundex(pr.birthSurname)}');
      if (pr.surname.isEmpty && pr.birthSurname.isEmpty && pr.given.isNotEmpty) {
        keys.add('g:${soundex(pr.given)}');
      }
      final y = pr.birthYear;
      if (y != null && pr.given.isNotEmpty) keys.add('y:${pr.given[0]}$y');
      for (final parent in pr.parents) {
        keys.add('p:$parent');
      }
      for (final k in keys) {
        put(k, id);
      }
    }

    final pairs = <String>{};
    void addBlock(List<String> ids) {
      for (var i = 0; i < ids.length; i++) {
        for (var j = i + 1; j < ids.length; j++) {
          pairs.add(pairKey(ids[i], ids[j]));
        }
      }
    }

    for (final e in blocks.entries) {
      final ids = e.value;
      if (ids.length < 2) continue;
      if (ids.length <= maxBlockSize) {
        addBlock(ids);
        continue;
      }
      // Too common (e.g. everyone shares the family name): split by the
      // first letter of the given name.
      final sub = <String, List<String>>{};
      for (final id in ids) {
        final g = _profiles[id]!.given;
        (sub[g.isEmpty ? '' : g[0]] ??= []).add(id);
      }
      for (final s in sub.values) {
        if (s.length >= 2) addBlock(s);
      }
    }
    return pairs;
  }

  /// All candidates at or above [threshold], best first. Pairs whose key is
  /// in [dismissed] ("not a duplicate") are skipped.
  List<DuplicateCandidate> find({Set<String> dismissed = const {}}) {
    comparisons = 0;
    final out = <DuplicateCandidate>[];
    for (final key in candidatePairs()) {
      if (dismissed.contains(key)) continue;
      final sep = key.indexOf('|');
      final c = compare(key.substring(0, sep), key.substring(sep + 1));
      if (c != null && c.score >= threshold) out.add(c);
    }
    out.sort((a, b) {
      final s = b.score.compareTo(a.score);
      if (s != 0) return s;
      return graph[a.aId]!.displayName.toLowerCase().compareTo(graph[b.aId]!.displayName.toLowerCase());
    });
    return out;
  }

  /// Scores one pair. Returns null when the names are not similar enough or
  /// the two are directly related (partners, parent/child, ancestor).
  DuplicateCandidate? compare(String aId, String bId) {
    final a = _profiles[aId], b = _profiles[bId];
    if (a == null || b == null || aId == bId) return null;
    if (!a.hasName || !b.hasName) return null;
    comparisons++;

    // People linked to each other are clearly two different people.
    if (a.partners.contains(bId) ||
        graph.parentIds(aId).contains(bId) ||
        graph.parentIds(bId).contains(aId)) {
      return null;
    }

    // ------------------------------------------------------------- names
    final fullSim = jaroWinkler(a.full, b.full);
    var givenSim = jaroWinkler(a.given, b.given);
    for (final (x, y) in [(a.nickname, b.given), (a.given, b.nickname), (a.nickname, b.nickname)]) {
      if (x.isNotEmpty && y.isNotEmpty && x == y) givenSim = math.max(givenSim, 0.95);
    }
    double? surnameSim;
    var viaBirthName = false;
    if ((a.surname.isNotEmpty || a.birthSurname.isNotEmpty) &&
        (b.surname.isNotEmpty || b.birthSurname.isNotEmpty)) {
      final direct = jaroWinkler(a.surname, b.surname);
      var best = direct;
      for (final (x, y) in [
        (a.birthSurname, b.surname),
        (a.surname, b.birthSurname),
        (a.birthSurname, b.birthSurname),
      ]) {
        final s = jaroWinkler(x, y);
        if (s > best) best = s;
      }
      viaBirthName = best >= 0.92 && direct < 0.85;
      surnameSim = best;
    }
    final name = surnameSim == null
        ? 0.6 * givenSim + 0.4 * fullSim
        : 0.45 * givenSim + 0.35 * surnameSim + 0.20 * fullSim;
    if (name < 0.86) return null;

    final reasons = <String>[];
    var points = 0.0;
    final sameName = a.full == b.full || name >= 0.985;
    if (sameName) {
      points += 50;
      reasons.add('Same name');
    } else {
      points += 45 * ((name - 0.86) / 0.125).clamp(0.0, 1.0);
      reasons.add(name >= 0.92 ? 'Very similar names' : 'Similar names');
    }
    if (viaBirthName) reasons.add('Birth name matches');

    // ------------------------------------------------------------- birth
    final ab = a.birth, bb = b.birth;
    final ay = a.birthYear, by = b.birthYear;
    if (ab != null && bb != null && ay != null && by != null) {
      final diff = (ay - by).abs();
      if (ab.isExactDay && bb.isExactDay && ab.serialize() == bb.serialize()) {
        points += 25;
        reasons.add('Same birth date');
      } else if (diff == 0) {
        points += 18;
        reasons.add('Both born in $ay');
      } else if (diff == 1) {
        points += 10;
        reasons.add('Born a year apart');
      } else if (diff > 5) {
        points -= 40;
      }
    }
    if (a.birthPlace.isNotEmpty && b.birthPlace.isNotEmpty) {
      if (a.birthPlace == b.birthPlace) {
        points += 12;
        reasons.add('Both born in ${a.p.birthPlace!.trim()}');
      } else if (a.birthPlaceHead.isNotEmpty && a.birthPlaceHead == b.birthPlaceHead) {
        points += 8;
        reasons.add('Both born in ${a.p.birthPlace!.split(',').first.trim()}');
      }
    }

    // ------------------------------------------------------ relationships
    final sharedParents = a.parents.intersection(b.parents);
    if (sharedParents.length >= 2) {
      points += 25;
      reasons.add('Same parents');
    } else if (sharedParents.length == 1) {
      points += 15;
      reasons.add('Shared parent: ${graph[sharedParents.first]?.displayName ?? '?'}');
    }
    final sharedPartners = a.partners.intersection(b.partners);
    if (sharedPartners.isNotEmpty) {
      points += 20;
      reasons.add('Shared partner: ${graph[sharedPartners.first]?.displayName ?? '?'}');
    }

    // ------------------------------------------------------------- death
    final ad = a.deathYear, bd = b.deathYear;
    if (ad != null && bd != null) {
      if (ad == bd) {
        points += 8;
        reasons.add('Both died in $ad');
      } else if ((ad - bd).abs() > 2) {
        points -= 15;
      }
    }

    // ------------------------------------------------------------ gender
    final ag = a.p.gender, bg = b.p.gender;
    if (ag != Gender.unknown && bg != Gender.unknown) {
      if (ag == bg) {
        points += 4;
      } else {
        points -= 35;
      }
    }

    final score = (points / 100).clamp(0.0, 1.0);
    // Ancestor / descendant pairs can never be merged safely. The graph walk
    // is only needed for pairs that would be reported.
    if (score >= threshold &&
        (graph.ancestors(aId).contains(bId) || graph.ancestors(bId).contains(aId))) {
      return null;
    }
    return DuplicateCandidate(aId: aId, bId: bId, score: score, reasons: reasons);
  }
}

/// Runs [DuplicateDetector.find] on a background isolate so large trees do
/// not block the UI. Falls back to the current isolate if spawning fails.
Future<List<DuplicateCandidate>> findDuplicatesInBackground(
  FamilyGraph graph, {
  Set<String> dismissed = const {},
}) async {
  try {
    return await Isolate.run(() => DuplicateDetector(graph).find(dismissed: dismissed));
  } on Object {
    return DuplicateDetector(graph).find(dismissed: dismissed);
  }
}
