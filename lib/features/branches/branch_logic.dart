import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../family/domain/family_graph.dart';
import '../search/text_normalize.dart';

/// Ids explicitly assigned to [branchId] that still exist in [g].
Set<String> explicitBranchMembers(String branchId, FamilyGraph g, Iterable<PersonBranch> explicit) => {
      for (final pb in explicit)
        if (pb.branchId == branchId && g.contains(pb.personId)) pb.personId,
    };

/// People derived from a root person: the root, all their descendants and
/// the partners of everyone in that line.
Set<String> lineMembers(String rootId, FamilyGraph g) {
  if (!g.contains(rootId)) return {};
  final line = {rootId, ...g.descendants(rootId)};
  return {
    ...line,
    for (final id in line) ...g.partnerIds(id),
  };
}

/// Members of a branch = explicit members ∪ (root + descendants + their
/// partners). People who are no longer in the graph (e.g. trashed) are
/// ignored.
Set<String> branchMembers(FamilyBranch b, FamilyGraph g, Iterable<PersonBranch> explicit) {
  final root = b.rootPersonId;
  return {
    ...explicitBranchMembers(b.id, g, explicit),
    if (root != null) ...lineMembers(root, g),
  };
}

/// Members ordered for display: root first, then by generation and name.
List<String> orderedMembers(Set<String> members, FamilyGraph g, {String? rootId}) {
  final gens = g.generations();
  return members.where(g.contains).toList()
    ..sort((a, b) {
      if (a == rootId) return -1;
      if (b == rootId) return 1;
      final ga = gens[a] ?? 0, gb = gens[b] ?? 0;
      if (ga != gb) return ga.compareTo(gb);
      return g[a]!.displayName.toLowerCase().compareTo(g[b]!.displayName.toLowerCase());
    });
}

enum SuggestionKind { paternal, maternal, rootLine }

/// A branch the user could create with one tap.
class BranchSuggestion {
  const BranchSuggestion({
    required this.kind,
    required this.name,
    required this.rootId,
    required this.description,
    required this.memberCount,
  });

  final SuggestionKind kind;
  final String name;
  final String rootId;
  final String description;
  final int memberCount;
}

/// The parent of [id] with [gender] (biological / adoptive / unspecified
/// links only), or null.
String? parentWithGender(FamilyGraph g, String id, Gender gender) {
  for (final p in g.kinParents(id)) {
    if (g[p]?.gender == gender) return p;
  }
  return null;
}

/// Walks up from [startId], preferring the parent of [prefer] gender (the
/// classic patrilineal / matrilineal line) and falling back to any recorded
/// parent, until nobody further up is known. Returns the topmost ancestor
/// (which may be [startId] itself).
String topmostAncestor(FamilyGraph g, String startId, Gender prefer) {
  var cur = startId;
  final seen = <String>{cur};
  while (true) {
    final parents = g.kinParents(cur);
    if (parents.isEmpty) return cur;
    final next = parentWithGender(g, cur, prefer) ?? parents.first;
    if (!seen.add(next)) return cur; // defensive: never loop
    cur = next;
  }
}

/// "Sharma line" (surname of the root) – or the full name when the surname
/// is unknown or already used by another suggestion.
String _lineName(FamilyGraph g, List<String> group, Set<String> usedNames) {
  final first = g[group.first]!;
  final surname = (first.lastName ?? '').trim();
  if (surname.isNotEmpty && !usedNames.contains(normalizeKey('$surname line'))) {
    return '$surname line';
  }
  return '${first.displayName} line';
}

/// Suggested branches that have not been created yet:
///  * "Paternal line" – the topmost ancestor through the home person's father
///  * "Maternal line" – the topmost ancestor through the mother
///  * one "{Name} line" per root couple of the tree ([FamilyGraph.rootLines]).
///
/// A suggestion is hidden when a branch with the same root person or the
/// same name (case-insensitive) already exists.
List<BranchSuggestion> suggestBranches(
  FamilyGraph g, {
  String? homePersonId,
  Iterable<FamilyBranch> existing = const [],
  int maxRootLines = 6,
}) {
  final takenRoots = {for (final b in existing) ?b.rootPersonId};
  final takenNames = {for (final b in existing) normalizeKey(b.name)};
  final usedRoots = <String>{};
  final usedNames = <String>{};
  final out = <BranchSuggestion>[];

  void add(SuggestionKind kind, String name, String rootId, String description) {
    if (takenRoots.contains(rootId) || usedRoots.contains(rootId)) return;
    final key = normalizeKey(name);
    if (takenNames.contains(key) || usedNames.contains(key)) return;
    usedRoots.add(rootId);
    usedNames.add(key);
    out.add(BranchSuggestion(
      kind: kind,
      name: name,
      rootId: rootId,
      description: description,
      memberCount: lineMembers(rootId, g).length,
    ));
  }

  final home = homePersonId;
  if (home != null && g.contains(home)) {
    final father = parentWithGender(g, home, Gender.male);
    if (father != null) {
      final root = topmostAncestor(g, father, Gender.male);
      add(SuggestionKind.paternal, 'Paternal line', root,
          'Descendants of ${g[root]!.displayName}, through ${g[home]!.shortName}’s father');
    }
    final mother = parentWithGender(g, home, Gender.female);
    if (mother != null) {
      final root = topmostAncestor(g, mother, Gender.female);
      add(SuggestionKind.maternal, 'Maternal line', root,
          'Descendants of ${g[root]!.displayName}, through ${g[home]!.shortName}’s mother');
    }
  }

  final lines = g.rootLines(foldMarriedIn: false)
    ..sort((a, b) => g.descendants(b.first).length.compareTo(g.descendants(a.first).length));
  for (final group in lines.take(maxRootLines)) {
    final names = group.map((id) => g[id]!.displayName).join(' & ');
    add(SuggestionKind.rootLine, _lineName(g, group, {...usedNames, ...takenNames}), group.first, 'Descendants of $names');
  }
  return out;
}
