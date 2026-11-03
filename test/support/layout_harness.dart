import 'dart:math' as math;
import 'dart:ui';

import 'package:drift/drift.dart' show Value;
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/core/models/fuzzy_date.dart';
import 'package:family_tales/core/repositories/family_repository.dart';
import 'package:family_tales/features/family/domain/family_graph.dart';
import 'package:family_tales/features/family_tree/layout/tree_layout.dart';

/// Builds an in-memory [FamilyGraph] without a database, for layout tests.
class GraphBuilder {
  GraphBuilder({this.idPrefix = 'p'});

  /// Start of every person id (different trees need different ids).
  final String idPrefix;
  final persons = <Person>[];
  final links = <ParentChildLink>[];
  final couples = <Partnership>[];
  final _t0 = DateTime(2020);

  String person(String name, {Gender gender = Gender.unknown, int? born}) {
    final id = '$idPrefix${persons.length.toString().padLeft(5, '0')}';
    final at = _t0.add(Duration(seconds: persons.length));
    persons.add(Person(
      id: id,
      treeId: 't',
      firstName: name,
      gender: gender,
      birthDate: born == null ? null : FuzzyDate.ymd(born).serialize(),
      isLiving: true,
      isPrivate: false,
      isArchived: false,
      createdAt: at,
      updatedAt: at,
    ));
    return id;
  }

  void parent(String parentId, String childId, [ParentType type = ParentType.biological]) {
    links.add(ParentChildLink(
      id: 'l${links.length}',
      treeId: 't',
      parentId: parentId,
      childId: childId,
      type: type,
      createdAt: _t0,
      updatedAt: _t0,
    ));
  }

  void couple(String a, String b,
      {PartnerStatus status = PartnerStatus.current, PartnerType type = PartnerType.marriage}) {
    couples.add(Partnership(
      id: 'c${couples.length}',
      treeId: 't',
      personAId: a,
      personBId: b,
      type: type,
      status: status,
      createdAt: _t0,
      updatedAt: _t0,
    ));
  }

  /// Adds a child of [parents] and returns its id.
  String child(List<String> parents, String name,
      {Gender gender = Gender.unknown, int? born, ParentType type = ParentType.biological}) {
    final c = person(name, gender: gender, born: born);
    for (final p in parents) {
      parent(p, c, type);
    }
    return c;
  }

  void removePerson(String id) {
    persons.removeWhere((p) => p.id == id);
    links.removeWhere((l) => l.parentId == id || l.childId == id);
    couples.removeWhere((c) => c.personAId == id || c.personBId == id);
  }

  FamilyGraph build() => FamilyGraph(persons: persons, parentLinks: links, partnerships: couples);
}

/// Saves [g] as a new tree through the repository (the same checks the app
/// applies) and returns the tree id. Person ids are kept.
Future<String> saveFamily(FamilyRepository repo, FamilyGraph g, String name) async {
  final tree = await repo.createTree(name);
  for (final p in g.people.values) {
    await repo.createPerson(PersonsCompanion.insert(
        id: p.id, treeId: tree, firstName: Value(p.firstName), gender: Value(p.gender), birthDate: Value(p.birthDate)));
  }
  for (final l in g.links) {
    await repo.addParent(childId: l.childId, parentId: l.parentId, type: l.type);
  }
  for (final c in g.couples) {
    await repo.addPartnership(a: c.personAId, b: c.personBId, status: c.status, type: c.type);
  }
  return tree;
}

/// Deterministic random family of about [size] people with the structures
/// real families have: couples, single parents, remarriages with
/// half-siblings, in-laws with their own parents, adoption, step and
/// guardian links, unknown second parents and the odd isolated person.
FamilyGraph randomFamily(int seed, {int size = 100, bool complex = true, String idPrefix = 'p'}) {
  final r = math.Random(seed);
  final b = GraphBuilder(idPrefix: idPrefix);
  Gender g() => r.nextBool() ? Gender.male : Gender.female;
  final founders = [b.person('F0', gender: Gender.male, born: 1900), b.person('F1', gender: Gender.female, born: 1902)];
  b.couple(founders[0], founders[1]);
  // Families that can still have children: (parents, birth year).
  var current = <(List<String>, int)>[(founders, 1900)];
  var guard = 0;
  while (b.persons.length < size && guard++ < 400) {
    final next = <(List<String>, int)>[];
    for (final (parents, year) in current) {
      if (b.persons.length >= size) break;
      final kids = r.nextInt(complex ? 5 : 4) + (current.length < 3 ? 1 : 0);
      final kidYear = year + 25 + r.nextInt(6);
      // Adopted / step / guardian children only in complex families.
      for (var k = 0; k < kids && b.persons.length < size; k++) {
        var type = ParentType.biological;
        if (complex) {
          final roll = r.nextInt(30);
          if (roll == 0) type = ParentType.adoptive;
          if (roll == 1) type = ParentType.unknown;
        }
        final c = b.child(parents, 'C${b.persons.length}', gender: g(), born: kidYear + k);
        if (type != ParentType.biological) {
          b.links.removeRange(b.links.length - parents.length, b.links.length);
          for (final p in parents) {
            b.parent(p, c, type);
          }
        }
        final roll = r.nextInt(20);
        if (roll < 11) {
          // Marries an outsider, sometimes one with recorded parents.
          final spouse = b.person('S${b.persons.length}', gender: g(), born: kidYear + k);
          if (complex && r.nextInt(4) == 0) {
            final sp = [b.person('IL${b.persons.length}', gender: Gender.male, born: kidYear - 28),
              b.person('IL${b.persons.length}', gender: Gender.female, born: kidYear - 27)];
            b.couple(sp[0], sp[1]);
            b.parent(sp[0], spouse);
            b.parent(sp[1], spouse);
            if (r.nextBool()) b.child(sp, 'ILS${b.persons.length}', gender: g(), born: kidYear + 2);
          }
          b.couple(c, spouse, status: complex && r.nextInt(6) == 0 ? PartnerStatus.divorced : PartnerStatus.current);
          next.add(([c, spouse], kidYear + k));
          if (complex && r.nextInt(5) == 0) {
            // Remarriage: half-siblings from a second partner.
            final second = b.person('R${b.persons.length}', gender: g(), born: kidYear + k + 2);
            b.couple(c, second);
            next.add(([c, second], kidYear + k + 6));
          }
          if (complex && r.nextInt(12) == 0) {
            // Step child brought into the marriage by the spouse.
            final step = b.child([spouse], 'ST${b.persons.length}', gender: g(), born: kidYear + k + 3);
            b.parent(c, step, ParentType.step);
          }
        } else if (roll < 14 && complex) {
          // Single parent / unknown other parent.
          next.add(([c], kidYear + k));
        } else if (roll == 14 && complex) {
          // Child with a partner who is not recorded as a partner.
          final other = b.person('O${b.persons.length}', gender: g(), born: kidYear + k);
          final kid = b.child([c, other], 'OC${b.persons.length}', gender: g(), born: kidYear + k + 25);
          if (r.nextBool()) next.add(([kid], kidYear + k + 25));
        } else if (roll == 15 && complex) {
          b.child([c], 'G${b.persons.length}', gender: g(), born: kidYear + k + 30, type: ParentType.guardian);
        }
      }
    }
    if (next.isEmpty) {
      // Keep growing: a new couple marries into the latest generation.
      final anchor = b.persons[r.nextInt(b.persons.length)].id;
      final s = b.person('N${b.persons.length}', gender: g());
      b.couple(anchor, s);
      next.add(([anchor, s], 1990));
    }
    current = next..shuffle(r);
  }
  if (complex) {
    // An unconnected relative and a lone couple without children.
    b.person('Loner', gender: g());
    final x = b.person('Lx', gender: Gender.male), y = b.person('Ly', gender: Gender.female);
    b.couple(x, y);
  }
  return b.build();
}

/// Every defect found in [l], as `category: detail` strings. An empty list
/// means the layout is valid.
List<String> validateLayout(FamilyGraph g, TreeLayout l, {Set<String>? expected}) {
  final o = l.options;
  final W = o.nodeWidth, H = o.nodeHeight;
  final out = <String>[];
  String name(String id) => g[id]?.firstName ?? id;

  // ---- membership
  if (expected != null) {
    for (final id in expected) {
      if (!l.nodes.containsKey(id)) out.add('missing: ${name(id)}');
    }
  }
  for (final id in l.nodes.keys) {
    if (!g.contains(id)) out.add('unknown: $id');
  }
  if (!l.size.width.isFinite || !l.size.height.isFinite || l.size.width < 0 || l.size.height < 0) {
    out.add('size: ${l.size}');
  }

  // ---- positions
  final canvas = Offset.zero & l.size;
  final byLayer = <int, List<LayoutNode>>{};
  final layerY = <int, double>{};
  for (final n in l.nodes.values) {
    if (!n.x.isFinite || !n.y.isFinite) {
      out.add('nan: ${name(n.id)} ${n.x},${n.y}');
      continue;
    }
    final r = n.rect(o);
    if (r.left < -0.01 || r.top < -0.01 || r.right > canvas.right + 0.01 || r.bottom > canvas.bottom + 0.01) {
      out.add('bounds: ${name(n.id)} $r outside ${l.size}');
    }
    (byLayer[n.layer] ??= []).add(n);
    final y = layerY[n.layer] ??= n.y;
    if ((y - n.y).abs() > 0.01) out.add('layer-y: ${name(n.id)} y=${n.y} but layer ${n.layer} is at $y');
  }
  for (final layer in byLayer.values) {
    layer.sort((a, b) => a.x.compareTo(b.x));
    for (var i = 1; i < layer.length; i++) {
      final gap = layer[i].x - layer[i - 1].x - W;
      if (gap < o.siblingGap - 0.5) {
        out.add('overlap: ${name(layer[i - 1].id)} / ${name(layer[i].id)} gap=${gap.toStringAsFixed(1)}');
      }
    }
  }
  final ys = layerY.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  for (var i = 1; i < ys.length; i++) {
    if (ys[i].value - ys[i - 1].value < H + 10) out.add('layer-gap: layers ${ys[i - 1].key}/${ys[i].key} overlap');
  }

  // ---- parent / child connectors
  final drawn = <String, int>{}; // 'parent>child' -> count
  final segments = <(Offset, Offset, Set<String>, String)>[]; // a, b, allowed cards, label
  for (final f in l.families) {
    for (final p in f.parents) {
      if (!l.nodes.containsKey(p)) out.add('family-parent: ${name(p)} not in layout');
    }
    if (f.parents.any((p) => !l.nodes.containsKey(p))) continue;
    final ps = [for (final p in f.parents) l.nodes[p]!];
    final label = f.parents.map(name).join('+');
    if (!f.origin.dx.isFinite || !f.origin.dy.isFinite || !f.busY.isFinite) {
      out.add('nan: family $label');
      continue;
    }
    if (ps.length == 1) {
      final want = Offset(ps[0].x + W / 2, ps[0].y + H);
      if ((f.origin - want).distance > 0.5) out.add('origin: $label at ${f.origin}, card bottom is $want');
    } else if (ps.length == 2) {
      final a = ps[0].x < ps[1].x ? ps[0] : ps[1], b = a == ps[0] ? ps[1] : ps[0];
      if (a.layer != b.layer) out.add('origin: couple $label on different layers');
      if (!(f.origin.dx > a.x + W - 0.5 && f.origin.dx < b.x + 0.5)) {
        out.add('origin: couple $label origin x ${f.origin.dx} not between the cards');
      }
      if (f.origin.dy < a.y || f.origin.dy > a.y + H) out.add('origin: couple $label origin y off the cards');
      // The couple must be side by side for the trunk to start on their line.
      final between = l.nodes.values.where((n) => n.layer == a.layer && n.x > a.x + 1 && n.x < b.x - 1);
      if (between.isNotEmpty) out.add('origin: couple $label not adjacent');
    } else {
      out.add('family-size: $label');
    }
    final bottom = ps.map((p) => p.y + H).reduce(math.max);
    for (final c in f.children) {
      final cn = l.nodes[c.childId];
      if (cn == null) {
        out.add('child-missing: ${name(c.childId)}');
        continue;
      }
      for (final p in f.parents) {
        drawn['$p>${c.childId}'] = (drawn['$p>${c.childId}'] ?? 0) + 1;
      }
      final top = Offset(cn.x + W / 2, cn.y);
      if ((c.top - top).distance > 0.5) out.add('child-top: ${name(c.childId)} line ends at ${c.top}, card top is $top');
      final pts = c.points(f.origin.dx, f.busY);
      final firstLayer = l.nodes.values.where((n) => n.y > bottom).map((n) => n.y).fold(double.infinity, math.min);
      if (!(f.busY > bottom + 1 && f.busY < firstLayer - 1)) {
        out.add('bus: $label → ${name(c.childId)} bus ${f.busY} not between $bottom and $firstLayer');
      }
      if ((pts.first - Offset(f.origin.dx, f.busY)).distance > 0.5) out.add('route: $label → ${name(c.childId)} does not start on the bus');
      if ((pts.last - c.top).distance > 0.5) out.add('route: $label → ${name(c.childId)} does not end at the card');
      for (var i = 1; i < pts.length; i++) {
        final a = pts[i - 1], b = pts[i];
        if ((a.dx - b.dx).abs() > 0.01 && (a.dy - b.dy).abs() > 0.01) out.add('route: $label → ${name(c.childId)} diagonal');
        if (!a.dx.isFinite || !a.dy.isFinite) out.add('nan: route $label');
        segments.add((a, b, i == pts.length - 1 ? {c.childId} : <String>{}, '$label → ${name(c.childId)} line'));
      }
    }
    segments.add((f.origin, Offset(f.origin.dx, f.busY), {...f.parents}, '$label trunk'));
  }
  for (final link in g.links) {
    if (!l.nodes.containsKey(link.parentId) || !l.nodes.containsKey(link.childId)) continue;
    final n = drawn['${link.parentId}>${link.childId}'] ?? 0;
    if (n == 0) out.add('link-missing: ${name(link.parentId)} → ${name(link.childId)}');
    if (n > 1) out.add('link-duplicate: ${name(link.parentId)} → ${name(link.childId)} x$n');
    final p = l.nodes[link.parentId]!, c = l.nodes[link.childId]!;
    if (p.layer >= c.layer) out.add('parent-below: ${name(link.parentId)} (${link.type.name}) → ${name(link.childId)}');
  }

  // ---- partner connectors
  for (final s in l.partners) {
    final a = l.nodes[s.a], b = l.nodes[s.b];
    if (a == null || b == null) {
      out.add('partner-missing: ${name(s.a)}/${name(s.b)}');
      continue;
    }
    if (a.layer != b.layer) out.add('partner-layer: ${name(s.a)}/${name(s.b)} on layers ${a.layer}/${b.layer}');
    if ((s.from.dx - (a.x + W)).abs() > 0.5 || (s.to.dx - b.x).abs() > 0.5) {
      out.add('partner-ends: ${name(s.a)}/${name(s.b)}');
    }
    final pts = s.points(o);
    if (!s.adjacent && s.bracketY == null && a.layer == b.layer) out.add('partner-route: ${name(s.a)}/${name(s.b)} has no bracket');
    for (var i = 1; i < pts.length; i++) {
      segments.add((pts[i - 1], pts[i], {s.a, s.b}, 'partner ${name(s.a)}/${name(s.b)}'));
    }
  }
  for (final s in g.couples) {
    if (l.nodes.containsKey(s.personAId) && l.nodes.containsKey(s.personBId) &&
        !l.partners.any((p) => {p.a, p.b}.containsAll({s.personAId, s.personBId}))) {
      out.add('partner-missing: ${name(s.personAId)}/${name(s.personBId)}');
    }
  }

  // ---- lines through unrelated cards
  final rects = {for (final n in l.nodes.values) n.id: n.rect(o).deflate(1)};
  for (final (a, b, allowed, label) in segments) {
    final seg = Rect.fromPoints(a, b);
    for (final e in rects.entries) {
      if (allowed.contains(e.key)) continue;
      final r = e.value;
      final hit = seg.width < 0.01
          ? seg.left > r.left && seg.left < r.right && seg.top < r.bottom && seg.bottom > r.top
          : seg.top > r.top && seg.top < r.bottom && seg.left < r.right && seg.right > r.left;
      // Partner lines may run along the edge of their own cards only.
      if (hit) out.add('through-card: $label crosses ${name(e.key)}');
    }
  }

  // ---- ambiguous lines: horizontal runs of different families (or
  // partner brackets) on the same height that overlap.
  final runs = <(double, double, double, String)>[];
  for (final f in l.families) {
    final key = f.parents.join('+');
    for (final c in f.children) {
      final pts = c.points(f.origin.dx, f.busY);
      for (var i = 1; i < pts.length; i++) {
        final a = pts[i - 1], b = pts[i];
        if ((a.dy - b.dy).abs() < 0.01 && (a.dx - b.dx).abs() > 0.5) {
          runs.add((a.dy, math.min(a.dx, b.dx), math.max(a.dx, b.dx), key));
        }
      }
    }
  }
  for (final s in l.partners) {
    if (s.bracketY != null && !s.adjacent) {
      final p = s.points(o);
      runs.add((s.bracketY!, p[1].dx, p[2].dx, 'bracket ${s.a}/${s.b}'));
    }
  }
  runs.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  for (var i = 0; i < runs.length; i++) {
    for (var j = i + 1; j < runs.length && (runs[j].$1 - runs[i].$1).abs() < 3; j++) {
      final a = runs[i], b = runs[j];
      if (a.$4 != b.$4 && a.$2 < b.$3 - 1 && b.$2 < a.$3 - 1) {
        out.add('bus-shared: ${a.$4} and ${b.$4} overlap at y=${a.$1.toStringAsFixed(0)}');
      }
    }
  }

  // ---- canvas
  final cb = l.contentBounds;
  for (final n in l.nodes.values) {
    if (!cb.inflate(0.5).contains(n.rect(o).topLeft) || !cb.inflate(0.5).contains(n.rect(o).bottomRight)) {
      out.add('content-bounds: ${name(n.id)} outside');
    }
  }
  if (cb.left < -0.5 || cb.top < -0.5 || cb.right > l.size.width + 0.5 || cb.bottom > l.size.height + 0.5) {
    out.add('content-bounds: $cb outside canvas ${l.size}');
  }
  return out;
}

/// Counts of [validateLayout] defects by category.
Map<String, int> defectSummary(List<String> defects) {
  final m = <String, int>{};
  for (final d in defects) {
    final k = d.split(':').first;
    m[k] = (m[k] ?? 0) + 1;
  }
  return m;
}
