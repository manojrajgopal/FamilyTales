import 'dart:collection';

import '../../../core/database/app_database.dart';
import '../../../core/models/enums.dart';
import '../../../core/models/fuzzy_date.dart';

/// Display helpers for the generated [Person] data class.
extension PersonX on Person {
  String get displayName {
    final f = fullName?.trim();
    if (f != null && f.isNotEmpty) return f;
    final parts = [firstName, middleName, lastName]
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    final n = parts.join(' ');
    return n.isEmpty ? 'Unnamed' : n;
  }

  String get shortName {
    final f = firstName.trim();
    if (f.isNotEmpty) return f;
    return displayName.split(' ').first;
  }

  FuzzyDate? get birth => FuzzyDate.tryParse(birthDate);
  FuzzyDate? get death => FuzzyDate.tryParse(deathDate);

  /// "1932 – 2011", "b. 1990", "1890 – ?"
  String get lifespanLabel {
    final b = birth?.formatYear();
    final d = death?.formatYear();
    if (!isLiving) return '${b ?? '?'} – ${d ?? '?'}';
    return b == null ? '' : 'b. $b';
  }

  /// Current age, or age at death. Unknown when someone has passed away
  /// without a recorded death date (never measured up to today).
  AgeSpan? get age => isLiving ? AgeSpan.between(birth, null) : (death == null ? null : AgeSpan.between(birth, death));
}

/// Sibling with the nature of the relationship.
enum SiblingKind { full, half, step, adoptive }

class SiblingInfo {
  const SiblingInfo(this.personId, this.kind);
  final String personId;
  final SiblingKind kind;
}

/// Immutable in-memory view of one family tree, rebuilt whenever the
/// underlying tables change. All derived kinship (siblings, grandparents,
/// cousins…) is computed here from the explicit parent/partner edges.
class FamilyGraph {
  FamilyGraph({
    required Iterable<Person> persons,
    required Iterable<ParentChildLink> parentLinks,
    required Iterable<Partnership> partnerships,
  }) {
    for (final p in persons) {
      people[p.id] = p;
    }
    for (final l in parentLinks) {
      if (!people.containsKey(l.parentId) || !people.containsKey(l.childId)) {
        continue; // edge to a trashed person
      }
      (_parentsOf[l.childId] ??= []).add(l);
      (_childrenOf[l.parentId] ??= []).add(l);
      links.add(l);
    }
    for (final s in partnerships) {
      if (!people.containsKey(s.personAId) || !people.containsKey(s.personBId)) {
        continue;
      }
      (_partnersOf[s.personAId] ??= []).add(s);
      (_partnersOf[s.personBId] ??= []).add(s);
      couples.add(s);
    }
  }

  factory FamilyGraph.empty() =>
      FamilyGraph(persons: const [], parentLinks: const [], partnerships: const []);

  final Map<String, Person> people = {};
  final List<ParentChildLink> links = [];
  final List<Partnership> couples = [];
  final Map<String, List<ParentChildLink>> _parentsOf = {};
  final Map<String, List<ParentChildLink>> _childrenOf = {};
  final Map<String, List<Partnership>> _partnersOf = {};

  Map<String, int>? _generationCache;

  bool contains(String id) => people.containsKey(id);
  Person? operator [](String id) => people[id];
  int get size => people.length;

  List<ParentChildLink> parentLinksOf(String id) => _parentsOf[id] ?? const [];
  List<ParentChildLink> childLinksOf(String id) => _childrenOf[id] ?? const [];
  List<Partnership> partnershipsOf(String id) => _partnersOf[id] ?? const [];

  /// Parents of [id]. With [lineageOnly], guardians and foster parents are
  /// excluded (they are shown but not used for kinship).
  List<String> parentIds(String id, {bool lineageOnly = false}) => [
        for (final l in parentLinksOf(id))
          if (!lineageOnly || l.type.isLineage) l.parentId
      ];

  List<String> childIds(String id, {bool lineageOnly = false}) => [
        for (final l in childLinksOf(id))
          if (!lineageOnly || l.type.isLineage) l.childId
      ];

  List<String> partnerIds(String id) => [
        for (final s in partnershipsOf(id))
          s.personAId == id ? s.personBId : s.personAId
      ];

  ParentType? parentType(String parentId, String childId) {
    for (final l in parentLinksOf(childId)) {
      if (l.parentId == parentId) return l.type;
    }
    return null;
  }

  Partnership? partnershipBetween(String a, String b) {
    for (final s in partnershipsOf(a)) {
      if ((s.personAId == a && s.personBId == b) ||
          (s.personAId == b && s.personBId == a)) {
        return s;
      }
    }
    return null;
  }

  /// Blood/legal parents used for kinship (biological, adoptive, unknown).
  List<String> kinParents(String id) => [
        for (final l in parentLinksOf(id))
          if (l.type == ParentType.biological ||
              l.type == ParentType.unknown ||
              l.type == ParentType.adoptive)
            l.parentId
      ];

  List<SiblingInfo> siblings(String id) {
    final mine = parentLinksOf(id);
    final kinMine = {
      for (final l in mine)
        if (l.type != ParentType.step &&
            l.type != ParentType.guardian &&
            l.type != ParentType.foster)
          l.parentId
    };
    final result = <String, SiblingInfo>{};
    for (final pl in mine) {
      for (final cl in childLinksOf(pl.parentId)) {
        if (cl.childId == id || result.containsKey(cl.childId)) continue;
        final theirs = {
          for (final l in parentLinksOf(cl.childId))
            if (l.type != ParentType.step &&
                l.type != ParentType.guardian &&
                l.type != ParentType.foster)
              l.parentId
        };
        final shared = kinMine.intersection(theirs);
        SiblingKind kind;
        if (shared.isEmpty) {
          kind = SiblingKind.step;
        } else {
          final adoptive = [...mine, ...parentLinksOf(cl.childId)].any((l) =>
              shared.contains(l.parentId) && l.type == ParentType.adoptive);
          if (shared.length >= 2 ||
              (shared.length == kinMine.length &&
                  shared.length == theirs.length)) {
            kind = adoptive ? SiblingKind.adoptive : SiblingKind.full;
          } else {
            kind = SiblingKind.half;
          }
        }
        result[cl.childId] = SiblingInfo(cl.childId, kind);
      }
    }
    // Step-siblings through a parent's partner.
    for (final p in kinMine) {
      for (final partner in partnerIds(p)) {
        if (kinMine.contains(partner)) continue;
        for (final c in childIds(partner, lineageOnly: true)) {
          if (c == id || result.containsKey(c)) continue;
          result[c] = SiblingInfo(c, SiblingKind.step);
        }
      }
    }
    return result.values.toList();
  }

  List<String> grandparents(String id) => {
        for (final p in parentIds(id, lineageOnly: true))
          ...parentIds(p, lineageOnly: true)
      }.toList();

  List<String> grandchildren(String id) => {
        for (final c in childIds(id, lineageOnly: true))
          ...childIds(c, lineageOnly: true)
      }.toList();

  /// All ancestors (lineage links) of [id].
  Set<String> ancestors(String id) {
    final out = <String>{};
    final q = Queue<String>()..add(id);
    while (q.isNotEmpty) {
      final x = q.removeFirst();
      for (final p in parentIds(x, lineageOnly: true)) {
        if (out.add(p)) q.add(p);
      }
    }
    return out;
  }

  /// All descendants (lineage links) of [id].
  Set<String> descendants(String id) {
    final out = <String>{};
    final q = Queue<String>()..add(id);
    while (q.isNotEmpty) {
      final x = q.removeFirst();
      for (final c in childIds(x, lineageOnly: true)) {
        if (out.add(c)) q.add(c);
      }
    }
    return out;
  }

  /// Would linking [parentId] as a parent of [childId] create a cycle?
  bool wouldCreateCycle(String parentId, String childId) {
    if (parentId == childId) return true;
    // Cycle if the proposed parent is already a descendant of the child.
    final q = Queue<String>()..add(childId);
    final seen = <String>{childId};
    while (q.isNotEmpty) {
      final x = q.removeFirst();
      for (final c in childIds(x)) {
        if (c == parentId) return true;
        if (seen.add(c)) q.add(c);
      }
    }
    return false;
  }

  /// Connected components across parent and partner edges.
  List<Set<String>> components() {
    final seen = <String>{};
    final out = <Set<String>>[];
    for (final id in people.keys) {
      if (seen.contains(id)) continue;
      final comp = <String>{};
      final q = Queue<String>()..add(id);
      seen.add(id);
      while (q.isNotEmpty) {
        final x = q.removeFirst();
        comp.add(x);
        for (final n in neighbours(x)) {
          if (seen.add(n)) q.add(n);
        }
      }
      out.add(comp);
    }
    out.sort((a, b) => b.length.compareTo(a.length));
    return out;
  }

  Iterable<String> neighbours(String id) sync* {
    yield* parentIds(id);
    yield* childIds(id);
    yield* partnerIds(id);
  }

  /// Generation index for every person (0 = oldest generation of its
  /// component). Partners share a generation; children sit one below their
  /// parents. Conflicts (e.g. marriages across generations) are resolved by
  /// pushing people down as little as possible.
  Map<String, int> generations() {
    if (_generationCache != null) return _generationCache!;
    final gen = <String, int>{for (final id in people.keys) id: 0};
    final n = people.length;
    // 1) Longest path from the top with partner equalisation.
    for (var iter = 0; iter < n + 2; iter++) {
      var changed = false;
      for (final l in links) {
        if (!l.type.isLineage) continue;
        final want = gen[l.parentId]! + 1;
        if (gen[l.childId]! < want) {
          gen[l.childId] = want;
          changed = true;
        }
      }
      for (final s in couples) {
        final a = gen[s.personAId]!, b = gen[s.personBId]!;
        if (a != b) {
          final m = a > b ? a : b;
          gen[s.personAId] = m;
          gen[s.personBId] = m;
          changed = true;
        }
      }
      if (!changed) break;
    }
    // 2) Pull childless-parentless roots (e.g. a spouse's parents) down so
    //    they sit just above their children.
    for (var iter = 0; iter < 4; iter++) {
      var changed = false;
      for (final id in people.keys) {
        if (parentIds(id, lineageOnly: true).isNotEmpty) continue;
        final kids = childIds(id, lineageOnly: true);
        if (kids.isEmpty) continue;
        var target = kids.map((c) => gen[c]!).reduce((a, b) => a < b ? a : b) - 1;
        // Partners must be able to move too.
        for (final p in partnerIds(id)) {
          if (parentIds(p, lineageOnly: true).isNotEmpty) {
            target = target < gen[p]! ? target : gen[p]!;
          }
        }
        if (target > gen[id]!) {
          gen[id] = target;
          for (final p in partnerIds(id)) {
            if (parentIds(p, lineageOnly: true).isEmpty && gen[p]! < target) {
              gen[p] = target;
            }
          }
          changed = true;
        }
      }
      if (!changed) break;
    }
    // 3) Normalise per component so the oldest generation is 0.
    for (final comp in components()) {
      final minG = comp.map((id) => gen[id]!).reduce((a, b) => a < b ? a : b);
      for (final id in comp) {
        gen[id] = gen[id]! - minG;
      }
    }
    return _generationCache = gen;
  }

  /// Number of generations in the largest span of any component.
  int generationCount() {
    if (people.isEmpty) return 0;
    final g = generations();
    var best = 0;
    for (final comp in components()) {
      final values = comp.map((id) => g[id]!);
      final span = values.reduce((a, b) => a > b ? a : b) -
          values.reduce((a, b) => a < b ? a : b) +
          1;
      if (span > best) best = span;
    }
    return best;
  }

  /// Number of explicit relationships (parent links + partnerships).
  int get relationshipCount => links.length + couples.length;

  /// Root ancestor lines: top people without parents who have descendants,
  /// with partners grouped together. Lines whose descendants all belong to
  /// another line (e.g. a spouse who married into the family) are folded
  /// into that line. Used as "family lines" / branch suggestions.
  ///
  /// With [foldMarriedIn] false every root couple is returned (used for
  /// branch suggestions such as a grandmother's maiden-name line).
  List<List<String>> rootLines({bool foldMarriedIn = true}) {
    final seen = <String>{};
    final lines = <List<String>>[];
    for (final id in people.keys) {
      if (seen.contains(id)) continue;
      if (parentIds(id, lineageOnly: true).isNotEmpty) continue;
      if (childIds(id, lineageOnly: true).isEmpty) continue;
      final group = <String>[id];
      seen.add(id);
      for (final p in partnerIds(id)) {
        if (parentIds(p, lineageOnly: true).isEmpty && seen.add(p)) group.add(p);
      }
      lines.add(group);
    }
    if (!foldMarriedIn) return lines;
    final desc = [
      for (final l in lines) {for (final m in l) ...descendants(m)}
    ];
    final keep = <List<String>>[];
    for (var i = 0; i < lines.length; i++) {
      var contained = false;
      for (var j = 0; j < lines.length; j++) {
        if (i == j) continue;
        final strict = desc[j].length > desc[i].length;
        if ((strict || (desc[j].length == desc[i].length && j < i)) && desc[j].containsAll(desc[i])) {
          contained = true;
          break;
        }
      }
      if (!contained) keep.add(lines[i]);
    }
    return keep;
  }

  /// Shortest connection path over any edge (for "how are they connected").
  List<String>? shortestPath(String from, String to) {
    if (from == to) return [from];
    final prev = <String, String>{};
    final q = Queue<String>()..add(from);
    final seen = <String>{from};
    while (q.isNotEmpty) {
      final x = q.removeFirst();
      for (final n in neighbours(x)) {
        if (!seen.add(n)) continue;
        prev[n] = x;
        if (n == to) {
          final path = <String>[to];
          var cur = to;
          while (prev.containsKey(cur)) {
            cur = prev[cur]!;
            path.add(cur);
          }
          return path.reversed.toList();
        }
        q.add(n);
      }
    }
    return null;
  }

  /// People sorted by display name.
  List<Person> sortedPeople() => people.values.toList()
    ..sort((a, b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
}
