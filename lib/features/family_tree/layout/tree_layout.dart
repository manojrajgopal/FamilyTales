import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

import '../../../core/models/enums.dart';
import '../../family/domain/family_graph.dart';

/// Visualisation modes. Switching modes never modifies relationship data.
enum TreeViewMode {
  focus('Focus', 'Immediate family around one person'),
  descendants('Descendants', 'Everyone descending from an ancestor'),
  ancestors('Ancestors', 'Parents, grandparents and earlier generations'),
  full('Full family', 'The complete connected family'),
  compact('Compact', 'Condensed view for large families');

  const TreeViewMode(this.label, this.description);
  final String label;
  final String description;
}

class TreeLayoutOptions {
  const TreeLayoutOptions({
    required this.mode,
    this.focusId,
    this.generationsUp = 3,
    this.generationsDown = 3,
    this.collapsed = const {},
  });

  final TreeViewMode mode;
  final String? focusId;
  final int generationsUp;
  final int generationsDown;

  /// People whose branch (descendants; ancestors in ancestor mode) is hidden.
  final Set<String> collapsed;

  bool get compact => mode == TreeViewMode.compact;

  double get nodeWidth => compact ? 88 : 132;
  double get nodeHeight => compact ? 104 : 166;
  double get partnerGap => compact ? 26 : 48;
  double get siblingGap => compact ? 14 : 22;
  double get groupGap => compact ? 30 : 46;
  double get levelGap => compact ? 58 : 78;
  double get margin => compact ? 120 : 160;
}

class LayoutNode {
  LayoutNode(this.id, this.layer);
  final String id;
  final int layer;
  double x = 0; // top-left
  double y = 0;
  int hiddenChildren = 0;
  int hiddenParents = 0;
  bool isFocus = false;

  Rect rect(TreeLayoutOptions o) => Rect.fromLTWH(x, y, o.nodeWidth, o.nodeHeight);
  Offset center(TreeLayoutOptions o) =>
      Offset(x + o.nodeWidth / 2, y + o.nodeHeight / 2);
}

class PartnerConnector {
  const PartnerConnector(this.a, this.b, this.from, this.to, this.status, this.type,
      {this.adjacent = true});
  final String a;
  final String b;
  final Offset from;
  final Offset to;
  final PartnerStatus status;
  final PartnerType type;
  final bool adjacent;
}

class ChildLine {
  const ChildLine(this.childId, this.type, this.top);
  final String childId;
  final ParentType type;
  final Offset top;
}

/// A parent (or couple) and the children drawn from it with a bus line.
class FamilyConnector {
  FamilyConnector(this.parents, this.origin, this.busY, this.children);
  final List<String> parents;
  final Offset origin;
  final double busY;
  final List<ChildLine> children;
}

class TreeLayout {
  TreeLayout(this.options, this.nodes, this.partners, this.families, this.size);
  final TreeLayoutOptions options;
  final Map<String, LayoutNode> nodes;
  final List<PartnerConnector> partners;
  final List<FamilyConnector> families;
  final Size size;

  bool get isEmpty => nodes.isEmpty;

  Rect boundsOf(String id) => nodes[id]!.rect(options);
}

/// Layered ("Sugiyama-style") layout specialised for families:
///
/// 1. Choose the visible people for the view mode.
/// 2. Assign layers: partners share a layer, children sit below parents.
/// 3. Group partners into "units" that always stay adjacent.
/// 4. Order units per layer (DFS seed + barycentre sweeps, keeping the
///    ordering with the fewest edge crossings).
/// 5. Position units with Sugiyama's priority method so children centre
///    under their parents and parents above their children.
/// 6. Build orthogonal connectors (couple → bus → child).
class TreeLayoutEngine {
  TreeLayoutEngine(this.g);
  final FamilyGraph g;

  TreeLayout compute(TreeLayoutOptions o) {
    if (g.size == 0) {
      return TreeLayout(o, {}, const [], const [], Size.zero);
    }
    final focus = (o.focusId != null && g.contains(o.focusId!))
        ? o.focusId!
        : _defaultFocus();
    final visible = _visibleSet(o, focus);

    if (o.mode == TreeViewMode.full || o.mode == TreeViewMode.compact) {
      // Lay out each connected component separately, side by side.
      final comps = _componentsWithin(visible);
      final allNodes = <String, LayoutNode>{};
      final allPartners = <PartnerConnector>[];
      final allFamilies = <FamilyConnector>[];
      double offsetX = 0;
      double maxH = 0;
      for (final comp in comps) {
        final part = _layoutSet(o, comp, focus);
        _shift(part, offsetX, 0);
        allNodes.addAll(part.nodes);
        allPartners.addAll(part.partners);
        allFamilies.addAll(part.families);
        offsetX += part.size.width - o.margin + o.groupGap * 2;
        maxH = math.max(maxH, part.size.height);
      }
      _annotateHidden(allNodes, focus);
      return TreeLayout(o, allNodes, allPartners, allFamilies,
          Size(offsetX - o.groupGap * 2 + o.margin, maxH));
    }
    final res = _layoutSet(o, visible, focus);
    _annotateHidden(res.nodes, focus);
    return res;
  }

  String _defaultFocus() => g.people.keys.first;

  // ------------------------------------------------------------ visibility

  Set<String> _visibleSet(TreeLayoutOptions o, String focus) {
    final collapsed = o.collapsed;
    switch (o.mode) {
      case TreeViewMode.descendants:
        final out = <String>{focus};
        var frontier = [focus];
        for (var d = 0; d < o.generationsDown && frontier.isNotEmpty; d++) {
          final next = <String>[];
          for (final p in frontier) {
            for (final partner in g.partnerIds(p)) {
              out.add(partner);
            }
            if (collapsed.contains(p)) continue;
            for (final c in g.childIds(p)) {
              if (out.add(c)) next.add(c);
            }
          }
          frontier = next;
        }
        for (final p in frontier) {
          out.addAll(g.partnerIds(p));
        }
        return out;
      case TreeViewMode.ancestors:
        final out = <String>{focus};
        var frontier = [focus];
        for (var d = 0; d < o.generationsUp && frontier.isNotEmpty; d++) {
          final next = <String>[];
          for (final p in frontier) {
            if (collapsed.contains(p) && p != focus) continue;
            for (final par in g.parentIds(p)) {
              if (out.add(par)) next.add(par);
            }
          }
          frontier = next;
        }
        return out;
      case TreeViewMode.focus:
        final out = <String>{focus, ...g.partnerIds(focus)};
        // Ancestors (with their partners so couples stay together).
        var up = [focus];
        for (var d = 0; d < o.generationsUp && up.isNotEmpty; d++) {
          final next = <String>[];
          for (final p in up) {
            for (final par in g.parentIds(p)) {
              if (out.add(par)) next.add(par);
            }
          }
          up = next;
        }
        // Siblings (share a parent with focus).
        for (final s in g.siblings(focus)) {
          if (g.parentIds(s.personId).any(out.contains)) out.add(s.personId);
        }
        // Descendants of focus with partners.
        var down = [focus];
        for (var d = 0; d < o.generationsDown && down.isNotEmpty; d++) {
          final next = <String>[];
          for (final p in down) {
            if (collapsed.contains(p)) continue;
            for (final c in g.childIds(p)) {
              if (out.add(c)) next.add(c);
              out.addAll(g.partnerIds(c));
            }
          }
          down = next;
        }
        return out;
      case TreeViewMode.full:
      case TreeViewMode.compact:
        final gens = g.generations();
        final fg = gens[focus] ?? 0;
        final out = <String>{};
        for (final id in g.people.keys) {
          final gi = gens[id] ?? 0;
          if (gi < fg - o.generationsUp || gi > fg + o.generationsDown) continue;
          out.add(id);
        }
        out.add(focus);
        // Hide descendants of collapsed people (unless they are ancestors
        // of the focus person, who must stay visible).
        if (collapsed.isNotEmpty) {
          final keep = g.ancestors(focus)..add(focus);
          for (final c in collapsed) {
            if (!out.contains(c)) continue;
            for (final d in g.descendants(c)) {
              if (!keep.contains(d)) out.remove(d);
            }
          }
          // Remove partners left floating (no other visible connection).
          out.removeWhere((id) =>
              id != focus &&
              !g.neighbours(id).any(out.contains));
        }
        return out;
    }
  }

  List<Set<String>> _componentsWithin(Set<String> v) {
    final seen = <String>{};
    final res = <Set<String>>[];
    // Component containing focus-ish (largest) first.
    for (final id in v) {
      if (seen.contains(id)) continue;
      final comp = <String>{};
      final q = Queue<String>()..add(id);
      seen.add(id);
      while (q.isNotEmpty) {
        final x = q.removeFirst();
        comp.add(x);
        for (final n in g.neighbours(x)) {
          if (v.contains(n) && seen.add(n)) q.add(n);
        }
      }
      res.add(comp);
    }
    res.sort((a, b) => b.length.compareTo(a.length));
    return res;
  }

  void _annotateHidden(Map<String, LayoutNode> nodes, String focus) {
    for (final n in nodes.values) {
      n.hiddenChildren =
          g.childIds(n.id).where((c) => !nodes.containsKey(c)).length;
      n.hiddenParents =
          g.parentIds(n.id).where((p) => !nodes.containsKey(p)).length;
      n.isFocus = n.id == focus;
    }
  }

  void _shift(TreeLayout l, double dx, double dy) {
    for (final n in l.nodes.values) {
      n.x += dx;
      n.y += dy;
    }
    final shifted = l.partners
        .map((p) => PartnerConnector(p.a, p.b, p.from.translate(dx, dy),
            p.to.translate(dx, dy), p.status, p.type,
            adjacent: p.adjacent))
        .toList();
    l.partners
      ..clear()
      ..addAll(shifted);
    final fam = l.families
        .map((f) => FamilyConnector(
              f.parents,
              f.origin.translate(dx, dy),
              f.busY + dy,
              [
                for (final c in f.children)
                  ChildLine(c.childId, c.type, c.top.translate(dx, dy))
              ],
            ))
        .toList();
    l.families
      ..clear()
      ..addAll(fam);
  }

  // ------------------------------------------------------------- layout

  TreeLayout _layoutSet(TreeLayoutOptions o, Set<String> v, String focus) {
    // Edges inside the visible set.
    final parentEdges = <(String, String, ParentType)>[]; // parent, child, type
    for (final id in v) {
      for (final l in g.parentLinksOf(id)) {
        if (v.contains(l.parentId)) parentEdges.add((l.parentId, id, l.type));
      }
    }
    final partnerEdges = <(String, String)>[];
    for (final s in g.couples) {
      if (v.contains(s.personAId) && v.contains(s.personBId)) {
        partnerEdges.add((s.personAId, s.personBId));
      }
    }

    final layerOf = _assignLayers(v, parentEdges, partnerEdges);
    final maxLayer = layerOf.values.fold<int>(0, math.max);

    // ---- units (partner chains within a layer)
    final unitOf = <String, int>{};
    final units = <_Unit>[];
    final partnerAdj = <String, List<String>>{};
    for (final (a, b) in partnerEdges) {
      if (layerOf[a] != layerOf[b]) continue;
      (partnerAdj[a] ??= []).add(b);
      (partnerAdj[b] ??= []).add(a);
    }
    final ids = v.toList()..sort(_byBirth);
    for (final id in ids) {
      if (unitOf.containsKey(id)) continue;
      final members = _chainOrder(id, partnerAdj);
      final u = _Unit(units.length, layerOf[id]!, members);
      units.add(u);
      for (final m in members) {
        unitOf[m] = u.index;
      }
    }

    // Unit-level adjacency (parents above / children below).
    final upUnits = <int, Set<int>>{};
    final downUnits = <int, Set<int>>{};
    for (final (p, c, _) in parentEdges) {
      final up = unitOf[p]!, dn = unitOf[c]!;
      if (up == dn) continue;
      (upUnits[dn] ??= {}).add(up);
      (downUnits[up] ??= {}).add(dn);
    }

    // ---- ordering
    final layers = List.generate(maxLayer + 1, (_) => <int>[]);
    _seedOrder(units, layers, unitOf, focus, o.mode, upUnits, downUnits);
    _reduceCrossings(layers, upUnits, downUnits);
    _orientCouples(units, layers, parentEdges, unitOf);

    // ---- x positioning
    final W = o.nodeWidth;
    double unitWidth(_Unit u) =>
        u.members.length * W + (u.members.length - 1) * o.partnerGap;
    final pos = <int, double>{}; // unit centre x

    // Sibling groups: units sharing a parent family get a tighter gap.
    String? familyKey(_Unit u) {
      final ps = <String>{};
      for (final m in u.members) {
        for (final (p, c, _) in parentEdges) {
          if (c == m) ps.add(p);
        }
      }
      if (ps.isEmpty) return null;
      return (ps.toList()..sort()).join('|');
    }

    final famKey = {for (final u in units) u.index: familyKey(u)};
    double gapBetween(int a, int b) {
      final ka = famKey[a], kb = famKey[b];
      if (ka != null && ka == kb) return o.siblingGap;
      return o.groupGap;
    }

    // Initial packing.
    for (final layer in layers) {
      double x = 0;
      for (var i = 0; i < layer.length; i++) {
        final u = units[layer[i]];
        final w = unitWidth(u);
        if (i > 0) x += gapBetween(layer[i - 1], layer[i]);
        pos[u.index] = x + w / 2;
        x += w;
      }
    }

    double memberOffset(_Unit u, String id) {
      final i = u.members.indexOf(id);
      return -unitWidth(u) / 2 + W / 2 + i * (W + o.partnerGap);
    }

    double personX(String id) {
      final u = units[unitOf[id]!];
      return pos[u.index]! + memberOffset(u, id);
    }

    // Family origins: x where a parent (or couple) connects downward.
    double originX(List<String> parents) {
      if (parents.length == 2) {
        return (personX(parents[0]) + personX(parents[1])) / 2;
      }
      return personX(parents.first);
    }

    final childParents = <String, List<String>>{};
    for (final (p, c, t) in parentEdges) {
      if (!t.isLineage && t != ParentType.step) continue;
      (childParents[c] ??= []).add(p);
    }
    List<String> familyParentsOf(String child) {
      final ps = childParents[child] ?? const <String>[];
      if (ps.length <= 1) return ps;
      // Prefer a couple that is in the same unit.
      for (var i = 0; i < ps.length; i++) {
        for (var j = i + 1; j < ps.length; j++) {
          if (unitOf[ps[i]] == unitOf[ps[j]] &&
              g.partnershipBetween(ps[i], ps[j]) != null) {
            return [ps[i], ps[j]];
          }
        }
      }
      return [ps.first];
    }

    void placeLayer(List<int> layer, Map<int, double> desired, Map<int, double> prio) {
      final n = layer.length;
      if (n == 0) return;
      final xs = [for (final u in layer) pos[u]!];
      final ws = [for (final u in layer) unitWidth(units[u])];
      final fixed = List.filled(n, false);
      double minGap(int i) => (ws[i - 1] + ws[i]) / 2 + gapBetween(layer[i - 1], layer[i]);

      final order = List.generate(n, (i) => i)
        ..sort((a, b) => (prio[layer[b]] ?? 0).compareTo(prio[layer[a]] ?? 0));
      for (final i in order) {
        final d = desired[layer[i]];
        if (d == null) {
          fixed[i] = true;
          continue;
        }
        if (d > xs[i]) {
          // Max position before hitting a fixed unit on the right.
          var limit = double.infinity;
          var acc = 0.0;
          for (var j = i + 1; j < n; j++) {
            acc += minGap(j);
            if (fixed[j]) {
              limit = xs[j] - acc;
              break;
            }
          }
          xs[i] = math.min(d, limit);
          for (var j = i + 1; j < n; j++) {
            final need = xs[j - 1] + minGap(j);
            if (xs[j] < need) {
              xs[j] = need;
            } else {
              break;
            }
          }
        } else if (d < xs[i]) {
          var limit = double.negativeInfinity;
          var acc = 0.0;
          for (var j = i - 1; j >= 0; j--) {
            acc += minGap(j + 1);
            if (fixed[j]) {
              limit = xs[j] + acc;
              break;
            }
          }
          xs[i] = math.max(d, limit);
          for (var j = i - 1; j >= 0; j--) {
            final need = xs[j + 1] - minGap(j + 1);
            if (xs[j] > need) {
              xs[j] = need;
            } else {
              break;
            }
          }
        }
        fixed[i] = true;
      }
      for (var i = 0; i < n; i++) {
        pos[layer[i]] = xs[i];
      }
    }

    void downSweep() {
      for (var L = 1; L < layers.length; L++) {
        final desired = <int, double>{};
        final prio = <int, double>{};
        for (final ui in layers[L]) {
          final u = units[ui];
          var sum = 0.0;
          var cnt = 0;
          for (final m in u.members) {
            final fp = familyParentsOf(m);
            if (fp.isEmpty) continue;
            if (fp.any((p) => layerOf[p]! >= L)) continue;
            sum += originX(fp) - memberOffset(u, m);
            cnt++;
          }
          if (cnt > 0) {
            desired[ui] = sum / cnt;
            prio[ui] = 1000.0 * cnt + (downUnits[ui]?.length ?? 0);
          } else {
            prio[ui] = 0;
          }
        }
        placeLayer(layers[L], desired, prio);
      }
    }

    void upSweep() {
      for (var L = layers.length - 2; L >= 0; L--) {
        final desired = <int, double>{};
        final prio = <int, double>{};
        for (final ui in layers[L]) {
          final u = units[ui];
          // Group children by family origin.
          var sum = 0.0;
          var weight = 0;
          final seenFam = <String, List<double>>{};
          for (final m in u.members) {
            for (final c in g.childIds(m)) {
              if (!v.contains(c) || layerOf[c]! <= L) continue;
              final fp = familyParentsOf(c);
              if (!fp.contains(m)) continue;
              final key = fp.join('|');
              (seenFam[key] ??= []).add(personX(c));
            }
          }
          for (final e in seenFam.entries) {
            final parents = e.key.split('|');
            final mean = e.value.reduce((a, b) => a + b) / e.value.length;
            // origin offset within unit
            final off = parents.length == 2
                ? (memberOffset(u, parents[0]) + memberOffset(u, parents[1])) / 2
                : memberOffset(u, parents[0]);
            sum += (mean - off) * e.value.length;
            weight += e.value.length;
          }
          if (weight > 0) {
            desired[ui] = sum / weight;
            prio[ui] = 1000.0 * weight;
          } else {
            prio[ui] = 0;
          }
        }
        placeLayer(layers[L], desired, prio);
      }
    }

    for (var it = 0; it < 4; it++) {
      downSweep();
      upSweep();
    }
    downSweep();

    // ---- final coordinates
    final nodes = <String, LayoutNode>{};
    double minX = double.infinity, maxX = double.negativeInfinity;
    for (final u in units) {
      for (final m in u.members) {
        final cx = pos[u.index]! + memberOffset(u, m);
        final n = LayoutNode(m, u.layer)
          ..x = cx - W / 2
          ..y = u.layer * (o.nodeHeight + o.levelGap);
        nodes[m] = n;
        minX = math.min(minX, n.x);
        maxX = math.max(maxX, n.x + W);
      }
    }
    final dx = o.margin - minX;
    for (final n in nodes.values) {
      n.x += dx;
      n.y += o.margin;
    }
    final width = (maxX - minX) + o.margin * 2;
    final height = (maxLayer + 1) * o.nodeHeight + maxLayer * o.levelGap + o.margin * 2;

    // ---- connectors
    final partners = <PartnerConnector>[];
    for (final s in g.couples) {
      final a = nodes[s.personAId], b = nodes[s.personBId];
      if (a == null || b == null) continue;
      final adjacent = unitOf[a.id] == unitOf[b.id] &&
          (units[unitOf[a.id]!].members.indexOf(a.id) -
                      units[unitOf[a.id]!].members.indexOf(b.id))
                  .abs() ==
              1;
      final left = a.x <= b.x ? a : b;
      final right = left == a ? b : a;
      final y = left.y + _connectorY(o);
      partners.add(PartnerConnector(
        left.id,
        right.id,
        Offset(left.x + W, y),
        Offset(right.x, y),
        s.status,
        s.type,
        adjacent: adjacent,
      ));
    }

    final famMap = <String, FamilyConnector>{};
    for (final c in nodes.keys) {
      final links = g.parentLinksOf(c).where((l) => nodes.containsKey(l.parentId)).toList();
      if (links.isEmpty) continue;
      final pair = familyParentsOf(c);
      final handled = <String>{};
      if (pair.length == 2) {
        final key = pair.join('|');
        final pa = nodes[pair[0]]!, pb = nodes[pair[1]]!;
        final origin = Offset(
          (pa.x + pb.x + W) / 2,
          pa.y + _connectorY(o),
        );
        final fam = famMap[key] ??= FamilyConnector(
          pair,
          origin,
          pa.y + o.nodeHeight + o.levelGap / 2,
          [],
        );
        final t = links.firstWhere((l) => l.parentId == pair[0]).type;
        fam.children.add(ChildLine(c, t, Offset(nodes[c]!.x + W / 2, nodes[c]!.y)));
        handled.addAll(pair);
      }
      for (final l in links) {
        if (handled.contains(l.parentId)) continue;
        final p = nodes[l.parentId]!;
        final key = '${l.parentId}#${l.type.name}';
        final fam = famMap[key] ??= FamilyConnector(
          [l.parentId],
          Offset(p.x + W / 2, p.y + o.nodeHeight),
          p.y + o.nodeHeight + o.levelGap / 2,
          [],
        );
        fam.children.add(ChildLine(c, l.type, Offset(nodes[c]!.x + W / 2, nodes[c]!.y)));
      }
    }
    // Stagger overlapping buses on the same level so lines stay readable.
    final families = famMap.values.toList();
    final byLevel = <double, List<FamilyConnector>>{};
    for (final f in families) {
      (byLevel[f.busY] ??= []).add(f);
    }
    final result = <FamilyConnector>[];
    for (final group in byLevel.values) {
      group.sort((a, b) => a.origin.dx.compareTo(b.origin.dx));
      final ranges = <(double, double, int)>[];
      for (final f in group) {
        final xs = [f.origin.dx, ...f.children.map((c) => c.top.dx)];
        final lo = xs.reduce(math.min), hi = xs.reduce(math.max);
        var slot = 0;
        final used = ranges
            .where((r) => r.$1 < hi + 6 && lo - 6 < r.$2)
            .map((r) => r.$3)
            .toSet();
        while (used.contains(slot)) {
          slot++;
        }
        ranges.add((lo, hi, slot));
        final offset = slot == 0 ? 0.0 : ((slot + 1) ~/ 2) * 9.0 * (slot.isOdd ? -1 : 1);
        result.add(FamilyConnector(f.parents, f.origin, f.busY + offset, f.children));
      }
    }

    return TreeLayout(o, nodes, partners, result, Size(width, height));
  }

  /// Vertical position (from node top) of the partner line: avatar centre.
  static double _connectorY(TreeLayoutOptions o) => o.compact ? 34 : 50;

  int _byBirth(String a, String b) {
    final pa = g[a]!, pb = g[b]!;
    final ka = pa.birth?.sortKey ?? double.infinity;
    final kb = pb.birth?.sortKey ?? double.infinity;
    final c = ka.compareTo(kb);
    if (c != 0) return c;
    return pa.createdAt.compareTo(pb.createdAt);
  }

  /// Orders a partner component as a chain, hub in the middle.
  List<String> _chainOrder(String start, Map<String, List<String>> adj) {
    // Collect component.
    final comp = <String>{};
    final q = Queue<String>()..add(start);
    comp.add(start);
    while (q.isNotEmpty) {
      final x = q.removeFirst();
      for (final n in adj[x] ?? const <String>[]) {
        if (comp.add(n)) q.add(n);
      }
    }
    if (comp.length == 1) return [start];
    if (comp.length == 2) {
      final l = comp.toList();
      // Conventional order: male left, female right; otherwise by age.
      final a = g[l[0]]!, b = g[l[1]]!;
      if (a.gender == Gender.female && b.gender == Gender.male) return [l[1], l[0]];
      if (a.gender == b.gender || a.gender == Gender.unknown || b.gender == Gender.unknown) {
        l.sort(_byBirth);
      }
      return l;
    }
    final hub = comp.reduce((a, b) =>
        (adj[a]?.length ?? 0) >= (adj[b]?.length ?? 0) ? a : b);
    final placed = <String>{hub};
    final left = <String>[];
    final right = <String>[];
    var toRight = true;
    void expand(String from, List<String> side) {
      final ns = (adj[from] ?? const <String>[]).where((n) => !placed.contains(n)).toList()
        ..sort(_byBirth);
      for (final n in ns) {
        if (!placed.add(n)) continue;
        side.add(n);
        expand(n, side);
      }
    }

    final hubPartners = (adj[hub] ?? const <String>[]).toList()..sort(_byBirth);
    for (final p in hubPartners) {
      if (placed.contains(p)) continue;
      placed.add(p);
      final side = toRight ? right : left;
      side.add(p);
      expand(p, side);
      toRight = !toRight;
    }
    for (final rest in comp) {
      if (placed.add(rest)) right.add(rest);
    }
    return [...left.reversed, hub, ...right];
  }

  Map<String, int> _assignLayers(Set<String> v,
      List<(String, String, ParentType)> pe, List<(String, String)> se) {
    final layer = {for (final id in v) id: 0};
    final n = v.length;
    final lineage = pe.where((e) => e.$3.isLineage || e.$3 == ParentType.step).toList();
    for (var iter = 0; iter < n + 2; iter++) {
      var changed = false;
      for (final (p, c, _) in lineage) {
        if (layer[c]! < layer[p]! + 1) {
          layer[c] = layer[p]! + 1;
          changed = true;
        }
      }
      for (final (a, b) in se) {
        if (layer[a] != layer[b]) {
          final m = math.max(layer[a]!, layer[b]!);
          layer[a] = m;
          layer[b] = m;
          changed = true;
        }
      }
      if (!changed) break;
    }
    // Pull parentless roots down next to their children.
    final parentsOf = <String, List<String>>{};
    final childrenOf = <String, List<String>>{};
    for (final (p, c, _) in lineage) {
      (parentsOf[c] ??= []).add(p);
      (childrenOf[p] ??= []).add(c);
    }
    final partnersOf = <String, List<String>>{};
    for (final (a, b) in se) {
      (partnersOf[a] ??= []).add(b);
      (partnersOf[b] ??= []).add(a);
    }
    for (var iter = 0; iter < 4; iter++) {
      var changed = false;
      for (final id in v) {
        if ((parentsOf[id] ?? const []).isNotEmpty) continue;
        final kids = childrenOf[id] ?? const <String>[];
        if (kids.isEmpty) continue;
        var target = kids.map((k) => layer[k]!).reduce(math.min) - 1;
        final ps = partnersOf[id] ?? const <String>[];
        for (final p in ps) {
          if ((parentsOf[p] ?? const []).isNotEmpty) target = math.min(target, layer[p]!);
        }
        if (target > layer[id]!) {
          layer[id] = target;
          for (final p in ps) {
            if ((parentsOf[p] ?? const []).isEmpty && layer[p]! < target) layer[p] = target;
          }
          changed = true;
        }
      }
      if (!changed) break;
    }
    final used = layer.values.toSet().toList()..sort();
    final remap = {for (var i = 0; i < used.length; i++) used[i]: i};
    return {for (final e in layer.entries) e.key: remap[e.value]!};
  }

  void _seedOrder(
    List<_Unit> units,
    List<List<int>> layers,
    Map<String, int> unitOf,
    String focus,
    TreeViewMode mode,
    Map<int, Set<int>> up,
    Map<int, Set<int>> down,
  ) {
    final placed = <int>{};
    void place(int u) {
      if (placed.add(u)) layers[units[u].layer].add(u);
    }

    if (mode == TreeViewMode.ancestors) {
      // Pedigree: DFS upward from the focus, father's side first.
      void visitUp(int u) {
        place(u);
        final members = units[u].members;
        for (final m in members) {
          final ps = g.parentIds(m).where(unitOf.containsKey).toList()
            ..sort((a, b) {
              int w(String x) => g[x]!.gender == Gender.male ? 0 : 1;
              return w(a).compareTo(w(b));
            });
          for (final p in ps) {
            final pu = unitOf[p]!;
            if (!placed.contains(pu)) visitUp(pu);
          }
        }
      }

      visitUp(unitOf[focus]!);
    } else {
      // DFS downward from top-layer units, children by birth order.
      void visitDown(int u) {
        place(u);
        final kids = <String>[];
        for (final m in units[u].members) {
          kids.addAll(g.childIds(m).where(unitOf.containsKey));
        }
        kids.sort(_byBirth);
        for (final k in kids) {
          final ku = unitOf[k]!;
          if (placed.contains(ku)) continue;
          // Bring in the child's partner's parents first so in-laws sit
          // beside the couple.
          visitDown(ku);
        }
      }

      final roots = [
        for (final u in units)
          if ((up[u.index] ?? const {}).isEmpty) u.index
      ]..sort((a, b) {
          final la = units[a].layer.compareTo(units[b].layer);
          if (la != 0) return la;
          return _byBirth(units[a].members.first, units[b].members.first);
        });
      // Start with the root line containing the focus' ancestry.
      final focusAnc = g.ancestors(focus)..add(focus);
      roots.sort((a, b) {
        final fa = units[a].members.any(focusAnc.contains) ? 0 : 1;
        final fb = units[b].members.any(focusAnc.contains) ? 0 : 1;
        if (fa != fb) return fa.compareTo(fb);
        return 0;
      });
      for (final r in roots) {
        if (!placed.contains(r)) visitDown(r);
      }
    }
    for (final u in units) {
      place(u.index);
    }
  }

  int _crossings(List<List<int>> layers, Map<int, Set<int>> down) {
    var total = 0;
    for (var L = 0; L < layers.length - 1; L++) {
      final posUp = {for (var i = 0; i < layers[L].length; i++) layers[L][i]: i};
      final posDn = {for (var i = 0; i < layers[L + 1].length; i++) layers[L + 1][i]: i};
      final edges = <(int, int)>[];
      for (final u in layers[L]) {
        for (final d in down[u] ?? const <int>{}) {
          final pd = posDn[d];
          if (pd != null) edges.add((posUp[u]!, pd));
        }
      }
      for (var i = 0; i < edges.length; i++) {
        for (var j = i + 1; j < edges.length; j++) {
          final a = edges[i], b = edges[j];
          if ((a.$1 - b.$1) * (a.$2 - b.$2) < 0) total++;
        }
      }
    }
    return total;
  }

  void _reduceCrossings(List<List<int>> layers, Map<int, Set<int>> up,
      Map<int, Set<int>> down) {
    var best = [for (final l in layers) List<int>.of(l)];
    var bestC = _crossings(layers, down);
    if (bestC == 0) return;
    for (var it = 0; it < 8; it++) {
      // Down sweep.
      for (var L = 1; L < layers.length; L++) {
        final prev = {for (var i = 0; i < layers[L - 1].length; i++) layers[L - 1][i]: i};
        _sortByBary(layers[L], (u) => up[u], prev);
      }
      // Up sweep.
      for (var L = layers.length - 2; L >= 0; L--) {
        final next = {for (var i = 0; i < layers[L + 1].length; i++) layers[L + 1][i]: i};
        _sortByBary(layers[L], (u) => down[u], next);
      }
      final c = _crossings(layers, down);
      if (c < bestC) {
        bestC = c;
        best = [for (final l in layers) List<int>.of(l)];
        if (c == 0) break;
      }
    }
    for (var i = 0; i < layers.length; i++) {
      layers[i]
        ..clear()
        ..addAll(best[i]);
    }
  }

  void _sortByBary(List<int> layer, Set<int>? Function(int) nb, Map<int, int> pos) {
    final bary = <int, double>{};
    for (var i = 0; i < layer.length; i++) {
      final u = layer[i];
      final ns = (nb(u) ?? const <int>{}).where(pos.containsKey).toList();
      if (ns.isEmpty) {
        bary[u] = -1; // keep relative position (filled below)
      } else {
        bary[u] = ns.map((n) => pos[n]!.toDouble()).reduce((a, b) => a + b) / ns.length;
      }
    }
    // Units without neighbours keep their slot: interpolate from neighbours.
    for (var i = 0; i < layer.length; i++) {
      if (bary[layer[i]] != -1) continue;
      double? left, right;
      for (var j = i - 1; j >= 0; j--) {
        if (bary[layer[j]] != -1) {
          left = bary[layer[j]];
          break;
        }
      }
      for (var j = i + 1; j < layer.length; j++) {
        if (bary[layer[j]] != -1) {
          right = bary[layer[j]];
          break;
        }
      }
      bary[layer[i]] = left != null && right != null
          ? (left + right) / 2
          : (left ?? right ?? i.toDouble()) + (left != null ? 0.01 : -0.01);
    }
    final idx = {for (var i = 0; i < layer.length; i++) layer[i]: i};
    layer.sort((a, b) {
      final c = bary[a]!.compareTo(bary[b]!);
      return c != 0 ? c : idx[a]!.compareTo(idx[b]!);
    });
  }

  /// Within two-person units, place each partner on the side of their own
  /// parents to avoid crossing lines.
  void _orientCouples(List<_Unit> units, List<List<int>> layers,
      List<(String, String, ParentType)> pe, Map<String, int> unitOf) {
    // Normalised horizontal position (0..1) of each unit within its layer,
    // comparable across layers.
    final posN = <int, double>{};
    for (final l in layers) {
      for (var i = 0; i < l.length; i++) {
        posN[l[i]] = (i + 0.5) / l.length;
      }
    }
    double? parentPos(String id) {
      final ps = [for (final (p, c, _) in pe) if (c == id) p];
      if (ps.isEmpty) return null;
      return ps.map((p) => posN[unitOf[p]!]!).reduce((a, b) => a + b) / ps.length;
    }

    void flip(_Unit u) => u.members.setAll(0, [u.members[1], u.members[0]]);

    for (final u in units) {
      if (u.members.length != 2) continue;
      final a = parentPos(u.members[0]);
      final b = parentPos(u.members[1]);
      final me = posN[u.index]!;
      if (a != null && b != null) {
        if (b < a) flip(u);
      } else if (a == null && b != null) {
        if (b < me) flip(u);
      } else if (b == null && a != null) {
        if (a > me) flip(u);
      }
    }
  }
}

class _Unit {
  _Unit(this.index, this.layer, this.members);
  final int index;
  final int layer;
  final List<String> members;
}
