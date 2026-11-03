import 'dart:collection';

import '../../../core/models/enums.dart';
import 'family_graph.dart';

enum KinKind { self, blood, partner, inLaw, step, guardian, distant }

/// One way in which person A is related to person B ("A is B's …").
class Kinship {
  const Kinship({
    required this.label,
    required this.kind,
    required this.path,
    this.viaAdoption = false,
    this.note,
  });

  /// Capitalised label, e.g. "First cousin once removed".
  final String label;
  final KinKind kind;

  /// Person ids from A to B (inclusive) illustrating this relationship.
  final List<String> path;
  final bool viaAdoption;
  final String? note;

  String describe(FamilyGraph g, String a, String b) {
    final an = g[a]?.displayName ?? '?';
    final bn = g[b]?.displayName ?? '?';
    if (kind == KinKind.self) return 'This is the same person.';
    final art = label.toLowerCase();
    return '$an is $bn’s $art.';
  }
}

/// Computes kinship between people from parent and partner edges only.
///
/// Blood relationships use the lowest common ancestors (LCA) of A and B:
/// with `a` = generations from A up to the ancestor and `b` = generations
/// from B, (0,1) is a parent, (1,1) siblings, (1,2) aunt/uncle,
/// (n≥2, m≥2) cousins of degree min(n,m)-1 removed |n-m| times, etc.
/// When several distinct paths exist (double cousins, pedigree collapse) all
/// are returned; nothing is guessed.
class KinshipCalculator {
  KinshipCalculator(this.g);
  final FamilyGraph g;

  List<Kinship> between(String a, String b) {
    if (!g.contains(a) || !g.contains(b)) return const [];
    if (a == b) {
      return [Kinship(label: 'Self', kind: KinKind.self, path: [a])];
    }
    final out = <Kinship>[];
    out.addAll(_blood(a, b));

    // Direct partnership.
    final s = g.partnershipBetween(a, b);
    if (s != null) {
      out.add(Kinship(
        label: _partnerLabel(a, s.type, s.status),
        kind: KinKind.partner,
        path: [a, b],
      ));
    }

    // Explicit step / guardian / foster links.
    final direct = g.parentType(a, b);
    if (direct != null && !_bloodType(direct)) {
      out.add(Kinship(
        label: _nonBloodParentLabel(a, direct),
        kind: direct == ParentType.step ? KinKind.step : KinKind.guardian,
        path: [a, b],
      ));
    }
    final directUp = g.parentType(b, a);
    if (directUp != null && !_bloodType(directUp)) {
      out.add(Kinship(
        label: _nonBloodChildLabel(a, directUp),
        kind: directUp == ParentType.step ? KinKind.step : KinKind.guardian,
        path: [a, b],
      ));
    }

    if (out.where((k) => k.kind == KinKind.blood).isEmpty) {
      out.addAll(_viaMarriage(a, b, out));
    }

    if (out.isEmpty) {
      final p = g.shortestPath(a, b);
      if (p != null) {
        out.add(Kinship(
          label: 'Distant relative',
          kind: KinKind.distant,
          path: p,
          note: 'Connected through ${p.length - 2} other '
              '${p.length - 2 == 1 ? 'person' : 'people'}.',
        ));
      }
    }
    // De-duplicate identical labels.
    final seen = <String>{};
    return [for (final k in out) if (seen.add('${k.kind}|${k.label}')) k];
  }

  /// Best single label for "A is B's …", or null if unrelated.
  String? primaryLabel(String a, String b) {
    final ks = between(a, b);
    if (ks.isEmpty) return null;
    return ks.first.label;
  }

  // ------------------------------------------------------------- blood

  static bool _bloodType(ParentType t) =>
      t == ParentType.biological || t == ParentType.unknown || t == ParentType.adoptive;

  /// BFS up through kin parents. Returns distance and one predecessor chain.
  Map<String, (int, String?, bool)> _up(String start) {
    // value: (distance, child-on-path, path uses adoption)
    final res = <String, (int, String?, bool)>{start: (0, null, false)};
    final q = Queue<String>()..add(start);
    while (q.isNotEmpty) {
      final x = q.removeFirst();
      final (d, _, adopt) = res[x]!;
      for (final l in g.parentLinksOf(x)) {
        if (!_bloodType(l.type)) continue;
        if (res.containsKey(l.parentId)) continue;
        res[l.parentId] = (d + 1, x, adopt || l.type == ParentType.adoptive);
        q.add(l.parentId);
      }
    }
    return res;
  }

  List<String> _chain(Map<String, (int, String?, bool)> up, String from) {
    // from ancestor down to start
    final chain = <String>[from];
    var cur = from;
    while (up[cur]!.$2 != null) {
      cur = up[cur]!.$2!;
      chain.add(cur);
    }
    return chain; // ancestor ... start
  }

  List<Kinship> _blood(String a, String b) {
    final ua = _up(a);
    final ub = _up(b);
    final common = ua.keys.where(ub.containsKey).toSet();
    if (common.isEmpty) return const [];
    // Lowest common ancestors: not an ancestor of another common ancestor.
    final lcas = common.where((c) {
      for (final other in common) {
        if (other == c) continue;
        if (_isAncestor(c, other)) return false;
      }
      return true;
    }).toList();

    final byKey = <String, List<String>>{};
    for (final c in lcas) {
      final key = '${ua[c]!.$1}:${ub[c]!.$1}';
      (byKey[key] ??= []).add(c);
    }
    final res = <Kinship>[];
    final keys = byKey.keys.toList()
      ..sort((x, y) {
        int sum(String k) => k.split(':').map(int.parse).reduce((p, q) => p + q);
        return sum(x).compareTo(sum(y));
      });
    for (final key in keys) {
      final ancestors = byKey[key]!;
      final parts = key.split(':').map(int.parse).toList();
      final da = parts[0], db = parts[1];
      final c = ancestors.first;
      final adoption = ua[c]!.$3 || ub[c]!.$3;
      // path A -> ... -> c -> ... -> B
      final upA = _chain(ua, c).reversed.toList(); // a ... c
      final downB = _chain(ub, c); // c ... b
      final path = [...upA, ...downB.skip(1)];
      var half = false;
      if (da >= 1 && db >= 1 && ancestors.length < 2) {
        // Compare the parent sets of the two people just below the ancestor.
        final x = upA[upA.length - 2];
        final y = downB[1];
        final px = g.kinParents(x).toSet();
        final py = g.kinParents(y).toSet();
        half = px.intersection(py).length < 2 &&
            !(px.length == py.length && px.containsAll(py));
      }
      var label = _bloodLabel(a, da, db, half: half);
      if (adoption && (da == 0 || db == 0)) {
        label = 'Adoptive ${label[0].toLowerCase()}${label.substring(1)}';
      }
      res.add(Kinship(
        label: label,
        kind: KinKind.blood,
        path: path,
        viaAdoption: adoption,
        note: adoption ? 'Through adoption.' : null,
      ));
    }
    return res;
  }

  bool _isAncestor(String maybeAncestor, String of) {
    final q = Queue<String>()..add(of);
    final seen = <String>{of};
    while (q.isNotEmpty) {
      final x = q.removeFirst();
      for (final p in g.kinParents(x)) {
        if (p == maybeAncestor) return true;
        if (seen.add(p)) q.add(p);
      }
    }
    return false;
  }

  Gender _gender(String id) => g[id]?.gender ?? Gender.unknown;

  String _g(String id, String m, String f, String n) => switch (_gender(id)) {
        Gender.male => m,
        Gender.female => f,
        _ => n,
      };

  static String _greats(int n) {
    if (n <= 0) return '';
    if (n == 1) return 'Great-';
    return '${_ordinalNum(n)} great-';
  }

  static String _ordinalNum(int n) {
    if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
    return switch (n % 10) { 1 => '${n}st', 2 => '${n}nd', 3 => '${n}rd', _ => '${n}th' };
  }

  static const _ordWords = [
    '', 'First', 'Second', 'Third', 'Fourth', 'Fifth', 'Sixth', 'Seventh',
    'Eighth', 'Ninth', 'Tenth',
  ];

  static String _ordinalWord(int n) => n < _ordWords.length ? _ordWords[n] : _ordinalNum(n);

  static String _removed(int r) => switch (r) {
        0 => '',
        1 => ' once removed',
        2 => ' twice removed',
        _ => ' $r times removed',
      };

  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// Label for "A is B's …" where A is [da] generations below the common
  /// ancestor and B is [db] generations below it.
  String _bloodLabel(String a, int da, int db, {bool half = false}) {
    if (da == 0) {
      // A is an ancestor of B.
      if (db == 1) return _g(a, 'Father', 'Mother', 'Parent');
      final base = _g(a, 'grandfather', 'grandmother', 'grandparent');
      return _cap('${_greats(db - 2)}$base'.toLowerCase());
    }
    if (db == 0) {
      // A is a descendant of B.
      if (da == 1) return _g(a, 'Son', 'Daughter', 'Child');
      final base = _g(a, 'grandson', 'granddaughter', 'grandchild');
      return _cap('${_greats(da - 2)}$base'.toLowerCase());
    }
    if (da == 1 && db == 1) {
      final s = _g(a, 'brother', 'sister', 'sibling');
      return _cap(half ? 'half-$s' : s);
    }
    if (da == 1) {
      // A is sibling of B's ancestor.
      final base = _g(a, 'uncle', 'aunt', 'parent’s sibling');
      if (db == 2) return _cap(half ? 'half-$base' : base);
      return _cap('${_greats(db - 2)}$base'.toLowerCase());
    }
    if (db == 1) {
      final base = _g(a, 'nephew', 'niece', 'sibling’s child');
      if (da == 2) return _cap(half ? 'half-$base' : base);
      final prefix = da - 2 == 1 ? 'grand' : '${_greats(da - 3).toLowerCase()}grand';
      return _cap('$prefix$base');
    }
    final degree = (da < db ? da : db) - 1;
    final removed = (da - db).abs();
    final h = half ? 'half-' : '';
    return _cap('$h${_ordinalWord(degree).toLowerCase()} cousin${_removed(removed)}');
  }

  // ------------------------------------------------------- non-blood

  String _partnerLabel(String a, PartnerType t, PartnerStatus s) {
    final ex = s == PartnerStatus.divorced || s == PartnerStatus.annulled;
    final late = s == PartnerStatus.widowed;
    if (t == PartnerType.engaged) return _g(a, 'Fiancé', 'Fiancée', 'Fiancé(e)');
    if (t == PartnerType.partner) {
      return ex || s == PartnerStatus.separated || s == PartnerStatus.ended
          ? 'Former partner'
          : 'Partner';
    }
    final base = _g(a, 'husband', 'wife', 'spouse');
    if (ex) return _cap('ex-$base');
    if (s == PartnerStatus.separated) return _cap('separated $base');
    if (late) return _cap(base);
    return _cap(base);
  }

  String _nonBloodParentLabel(String a, ParentType t) => switch (t) {
        ParentType.step => _g(a, 'Stepfather', 'Stepmother', 'Step-parent'),
        ParentType.foster => _g(a, 'Foster father', 'Foster mother', 'Foster parent'),
        ParentType.guardian => 'Guardian',
        _ => 'Parent',
      };

  String _nonBloodChildLabel(String a, ParentType t) => switch (t) {
        ParentType.step => _g(a, 'Stepson', 'Stepdaughter', 'Stepchild'),
        ParentType.foster => 'Foster child',
        ParentType.guardian => 'Ward',
        _ => 'Child',
      };

  /// Relationships through one marriage/partnership hop.
  List<Kinship> _viaMarriage(String a, String b, List<Kinship> existing) {
    final res = <Kinship>[];
    final hasStep = existing.any((k) => k.kind == KinKind.step);

    // 1) A's partner P is blood-related to B: "A is the spouse of B's X".
    for (final p in g.partnerIds(a)) {
      if (p == b) continue;
      for (final k in _blood(p, b)) {
        final lbl = _spouseOfLabel(a, k.label);
        if (lbl == null) continue;
        if (hasStep && lbl.startsWith('Step')) continue;
        res.add(Kinship(
          label: lbl,
          kind: lbl.startsWith('Step') ? KinKind.step : KinKind.inLaw,
          path: [a, ...k.path],
        ));
      }
    }
    // 2) B's partner Q: A is blood-related to Q: "A is the X of B's spouse".
    for (final q in g.partnerIds(b)) {
      if (q == a) continue;
      for (final k in _blood(a, q)) {
        final lbl = _relOfSpouseLabel(a, k.label);
        if (lbl == null) continue;
        if (hasStep && lbl.startsWith('Step')) continue;
        res.add(Kinship(
          label: lbl,
          kind: lbl.startsWith('Step') ? KinKind.step : KinKind.inLaw,
          path: [...k.path, b],
        ));
      }
    }
    // 3) Step-siblings: children of partners who share no parent.
    if (res.isEmpty) {
      for (final sib in g.siblings(a)) {
        if (sib.personId == b && sib.kind == SiblingKind.step) {
          res.add(Kinship(
            label: _g(a, 'Stepbrother', 'Stepsister', 'Step-sibling'),
            kind: KinKind.step,
            path: [a, b],
          ));
        }
      }
    }
    return res;
  }

  /// A is partner of P, and P is B's [rel] → A is B's ?
  String? _spouseOfLabel(String a, String rel) {
    final r = rel.toLowerCase();
    if (r == 'father' || r == 'mother' || r == 'parent') {
      return _g(a, 'Stepfather', 'Stepmother', 'Step-parent');
    }
    if (r == 'son' || r == 'daughter' || r == 'child') {
      return _g(a, 'Son-in-law', 'Daughter-in-law', 'Child-in-law');
    }
    // "Parent’s sibling" (an uncle/aunt of unknown gender) is handled below.
    if (r.endsWith('brother') || r.endsWith('sister') || (r.endsWith('sibling') && !r.endsWith('’s sibling'))) {
      return _g(a, 'Brother-in-law', 'Sister-in-law', 'Sibling-in-law');
    }
    if (r.contains('grandson') || r.contains('granddaughter') || r.contains('grandchild')) {
      return _g(a, 'Grandson-in-law', 'Granddaughter-in-law', 'Grandchild-in-law');
    }
    if (r.endsWith('uncle') || r.endsWith('aunt') || r.endsWith('parent’s sibling')) {
      final base = _g(a, 'Uncle', 'Aunt', 'Parent’s sibling');
      return '$base (by marriage)';
    }
    if (r.endsWith('nephew') || r.endsWith('niece') || r.endsWith('sibling’s child')) {
      return _g(a, 'Nephew-in-law', 'Niece-in-law', 'Sibling’s child-in-law');
    }
    if (r.contains('cousin')) return 'Cousin-in-law';
    if (r.contains('grandfather') || r.contains('grandmother') || r.contains('grandparent')) {
      return _g(a, 'Step-grandfather', 'Step-grandmother', 'Step-grandparent');
    }
    return 'Spouse of ${rel.toLowerCase()}';
  }

  /// A is [rel] of Q, and Q is B's partner → A is B's ?
  String? _relOfSpouseLabel(String a, String rel) {
    final r = rel.toLowerCase();
    if (r == 'father' || r == 'mother' || r == 'parent') {
      return _g(a, 'Father-in-law', 'Mother-in-law', 'Parent-in-law');
    }
    if (r == 'son' || r == 'daughter' || r == 'child') {
      return _g(a, 'Stepson', 'Stepdaughter', 'Stepchild');
    }
    // "Parent’s sibling" (an uncle/aunt of unknown gender) is handled below.
    if (r.endsWith('brother') || r.endsWith('sister') || (r.endsWith('sibling') && !r.endsWith('’s sibling'))) {
      return _g(a, 'Brother-in-law', 'Sister-in-law', 'Sibling-in-law');
    }
    if (r.contains('grandfather') || r.contains('grandmother') || r.contains('grandparent')) {
      return _g(a, 'Grandfather-in-law', 'Grandmother-in-law', 'Grandparent-in-law');
    }
    if (r.contains('grandson') || r.contains('granddaughter') || r.contains('grandchild')) {
      return _g(a, 'Step-grandson', 'Step-granddaughter', 'Step-grandchild');
    }
    if (r.endsWith('uncle') || r.endsWith('aunt') || r.endsWith('parent’s sibling')) {
      return _g(a, 'Uncle-in-law', 'Aunt-in-law', 'Parent’s sibling-in-law');
    }
    if (r.endsWith('nephew') || r.endsWith('niece') || r.endsWith('sibling’s child')) {
      final base = _g(a, 'Nephew', 'Niece', 'Sibling’s child');
      return '$base (by marriage)';
    }
    if (r.contains('cousin')) return 'Cousin-in-law';
    return '${_cap(rel.toLowerCase())} of spouse';
  }
}
