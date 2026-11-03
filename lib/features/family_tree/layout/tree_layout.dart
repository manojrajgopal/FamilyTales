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

  /// Minimum gap between generations; grows when many lines share it.
  double get levelGap => compact ? 58 : 78;
  double get margin => compact ? 120 : 160;

  /// Space between a line passing through a generation and the cards beside it.
  double get laneGap => compact ? 14 : 20;

  /// Space between two lines passing through a generation side by side.
  double get laneSpacing => compact ? 8 : 10;

  /// Vertical distance between parallel horizontal lines in one gap.
  double get trackSpacing => compact ? 8 : 10;

  /// Free space between the cards and the outermost line in a gap.
  double get trackPadding => compact ? 18 : 24;
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
      {this.adjacent = true, this.bracketY});
  final String a;
  final String b;
  final Offset from;
  final Offset to;
  final PartnerStatus status;
  final PartnerType type;
  final bool adjacent;

  /// For partners who are not side by side: the height of the bracket drawn
  /// over the cards between them (its own track in the gap above the row).
  final double? bracketY;

  /// Where a bracket leaves the top of the left / right card.
  static const bracketInset = 26.0;

  /// The connector as an orthogonal polyline.
  List<Offset> points(TreeLayoutOptions o) {
    final y = bracketY;
    if (adjacent || y == null) return [from, to];
    final top = from.dy - _connectorY(o);
    final ax = from.dx - bracketInset, bx = to.dx + bracketInset;
    return [Offset(ax, top), Offset(ax, y), Offset(bx, y), Offset(bx, top)];
  }
}

class ChildLine {
  const ChildLine(this.childId, this.type, this.top, {this.route});
  final String childId;
  final ParentType type;

  /// Where the line meets the child's card (top centre).
  final Offset top;

  /// Orthogonal waypoints from the family bus to [top] for a child more
  /// than one generation below (the line keeps to its own lane through the
  /// generations in between). Null for a child directly below.
  final List<Offset>? route;

  /// The line from the family bus at [fromX] down to the child.
  List<Offset> points(double fromX, double busY) =>
      route ?? [Offset(fromX, busY), Offset(top.dx, busY), top];
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
  TreeLayout(this.options, this.nodes, this.partners, this.families, this.size, {Rect? contentBounds})
      : contentBounds = contentBounds ?? Offset.zero & size;
  final TreeLayoutOptions options;
  final Map<String, LayoutNode> nodes;
  final List<PartnerConnector> partners;
  final List<FamilyConnector> families;

  /// Canvas size: the content plus a margin to pan into.
  final Size size;

  /// Everything that is drawn (cards and lines), in canvas coordinates.
  final Rect contentBounds;

  bool get isEmpty => nodes.isEmpty;

  Rect boundsOf(String id) => nodes[id]!.rect(options);
}

/// Vertical position (from node top) of the partner line: avatar centre.
double _connectorY(TreeLayoutOptions o) => o.compact ? 34 : 50;

/// Layered ("Sugiyama-style") layout specialised for families:
///
/// 1. Choose the visible people for the view mode.
/// 2. Assign layers: partners share a layer, children sit below every
///    parent they are drawn from, and branches that married in move down
///    as a block to sit just above their child.
/// 3. Group partners into "units" that always stay adjacent, and give
///    every line that skips generations a lane unit in each generation it
///    passes, so it never runs through a card.
/// 4. Order units per layer (DFS seed + barycentre sweeps, keeping the
///    ordering with the fewest edge crossings).
/// 5. Position units with Sugiyama's priority method so children centre
///    under their parents, parents above their children and lanes run
///    straight.
/// 6. Route connectors from the final coordinates: every horizontal line in
///    a gap between generations gets its own track and the gap grows to
///    fit them, so no two families share a line.
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
      Rect? content;
      for (final comp in comps) {
        final part = _layoutSet(o, comp, focus);
        final shifted = _shift(part, offsetX, 0);
        allNodes.addAll(shifted.nodes);
        allPartners.addAll(shifted.partners);
        allFamilies.addAll(shifted.families);
        content = content == null ? shifted.contentBounds : content.expandToInclude(shifted.contentBounds);
        offsetX += part.size.width - o.margin + o.groupGap * 2;
        maxH = math.max(maxH, part.size.height);
      }
      _annotateHidden(allNodes, focus);
      return TreeLayout(o, allNodes, allPartners, allFamilies,
          Size(offsetX - o.groupGap * 2 + o.margin, maxH),
          contentBounds: content);
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

  /// [l] moved by ([dx], [dy]), connectors included.
  static TreeLayout _shift(TreeLayout l, double dx, double dy) {
    final d = Offset(dx, dy);
    for (final n in l.nodes.values) {
      n.x += dx;
      n.y += dy;
    }
    return TreeLayout(
      l.options,
      l.nodes,
      [
        for (final p in l.partners)
          PartnerConnector(p.a, p.b, p.from + d, p.to + d, p.status, p.type,
              adjacent: p.adjacent, bracketY: p.bracketY == null ? null : p.bracketY! + dy)
      ],
      [
        for (final f in l.families)
          FamilyConnector(f.parents, f.origin + d, f.busY + dy, [
            for (final c in f.children)
              ChildLine(c.childId, c.type, c.top + d, route: c.route?.map((p) => p + d).toList())
          ])
      ],
      l.size,
      contentBounds: l.contentBounds.shift(d),
    );
  }

  // ------------------------------------------------------------- layout

  TreeLayout _layoutSet(TreeLayoutOptions o, Set<String> v, String focus) {
    final W = o.nodeWidth, H = o.nodeHeight;

    // Edges inside the visible set. Every parent link is drawn, so every
    // link type constrains the layers: a child always sits below the
    // parents its lines come from.
    final parentEdges = <(String, String, ParentType)>[]; // parent, child, type
    final linksOf = <String, List<(String, ParentType)>>{};
    for (final id in v) {
      for (final l in g.parentLinksOf(id)) {
        if (l.parentId == id || !v.contains(l.parentId)) continue;
        parentEdges.add((l.parentId, id, l.type));
        (linksOf[id] ??= []).add((l.parentId, l.type));
      }
    }
    final partnerEdges = <(String, String)>[];
    for (final s in g.couples) {
      if (s.personAId != s.personBId && v.contains(s.personAId) && v.contains(s.personBId)) {
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

    // ---- families: who each child's lines come from
    bool sideBySide(String a, String b) {
      if (unitOf[a] != unitOf[b]) return false;
      final m = units[unitOf[a]!].members;
      return (m.indexOf(a) - m.indexOf(b)).abs() == 1 && g.partnershipBetween(a, b) != null;
    }

    final fams = <_Family>[];
    final famByKey = <String, _Family>{};
    _Family famFor(List<String> parents) => famByKey[parents.join('|')] ??= (fams..add(_Family(
        fams.length, parents, unitOf[parents.first]!, layerOf[parents.first]!))).last;
    for (final c in ids) {
      final ls = linksOf[c];
      if (ls == null) continue;
      // A child of a couple standing side by side hangs from their line,
      // when both links are of the same kind (a step-parent's line is drawn
      // separately from the birth parent's).
      (String, String, ParentType)? pair;
      for (var i = 0; i < ls.length; i++) {
        for (var j = i + 1; j < ls.length; j++) {
          final a = ls[i], b = ls[j];
          if (a.$2 != b.$2 || !sideBySide(a.$1, b.$1)) continue;
          if (pair == null || (a.$2.isLineage && !pair.$3.isLineage)) pair = (a.$1, b.$1, a.$2);
        }
      }
      if (pair != null) {
        final key = ([pair.$1, pair.$2]..sort());
        famFor(key).children.add((c, pair.$3));
      }
      final done = <String>{};
      for (final (p, t) in ls) {
        if (pair != null && (p == pair.$1 || p == pair.$2)) continue;
        if (!done.add(p)) continue; // duplicate link records
        famFor([p]).children.add((c, t));
      }
    }

    // ---- connections between adjacent layers, with lanes for long lines
    final conns = <_Conn>[];
    for (final f in fams) {
      for (final (c, _) in f.children) {
        final lc = layerOf[c]!;
        if (lc <= f.layer) continue; // contradictory data: drawn, not routed
        final down = _Anchor(unitOf[c]!, person: c);
        if (lc == f.layer + 1) {
          conns.add(_Conn(_Anchor(f.unit, family: f), down));
          continue;
        }
        var chain = f.chains[lc];
        if (chain == null) {
          chain = [];
          for (var L = f.layer + 1; L < lc; L++) {
            final d = _Unit(units.length, L, const []);
            units.add(d);
            chain.add(d.index);
          }
          f.chains[lc] = chain;
          conns.add(_Conn(_Anchor(f.unit, family: f), _Anchor(chain.first)));
          for (var i = 1; i < chain.length; i++) {
            conns.add(_Conn(_Anchor(chain[i - 1]), _Anchor(chain[i])));
          }
        }
        conns.add(_Conn(_Anchor(chain.last), down));
      }
    }
    final upConns = <int, List<_Conn>>{};
    final downConns = <int, List<_Conn>>{};
    final upUnits = <int, Set<int>>{};
    final downUnits = <int, Set<int>>{};
    final personUp = <String, List<int>>{};
    for (final c in conns) {
      (upConns[c.down.unit] ??= []).add(c);
      (downConns[c.up.unit] ??= []).add(c);
      (upUnits[c.down.unit] ??= {}).add(c.up.unit);
      (downUnits[c.up.unit] ??= {}).add(c.down.unit);
      if (c.down.person != null) (personUp[c.down.person!] ??= []).add(c.up.unit);
    }

    // ---- ordering
    final layers = List.generate(maxLayer + 1, (_) => <int>[]);
    _seedOrder(units, layers, unitOf, focus, o.mode, upConns, downConns);
    _reduceCrossings(layers, upUnits, downUnits);
    _orientCouples(units, layers, personUp);

    // ---- x positioning
    double unitWidth(_Unit u) =>
        u.isLane ? 0 : u.members.length * W + (u.members.length - 1) * o.partnerGap;
    double memberOffset(_Unit u, String id) {
      final i = u.members.indexOf(id);
      return -unitWidth(u) / 2 + W / 2 + i * (W + o.partnerGap);
    }

    double familyOffset(_Family f) {
      final u = units[f.unit];
      final ps = f.parents;
      return ps.length == 2
          ? (memberOffset(u, ps[0]) + memberOffset(u, ps[1])) / 2
          : memberOffset(u, ps[0]);
    }

    double anchorOffset(_Anchor a) => a.person != null
        ? memberOffset(units[a.unit], a.person!)
        : a.family != null
            ? familyOffset(a.family!)
            : 0;
    for (final c in conns) {
      c.upOff = anchorOffset(c.up);
      c.downOff = anchorOffset(c.down);
    }

    // Sibling groups: units sharing a parent family get a tighter gap.
    final famKey = <int, String?>{
      for (final u in units)
        u.index: u.isLane
            ? null
            : () {
                final ps = <String>{
                  for (final m in u.members) ...?linksOf[m]?.map((l) => l.$1),
                };
                return ps.isEmpty ? null : (ps.toList()..sort()).join('|');
              }(),
    };
    double gapBetween(int a, int b) {
      final la = units[a].isLane, lb = units[b].isLane;
      if (la && lb) return o.laneSpacing;
      if (la || lb) return o.laneGap;
      final ka = famKey[a], kb = famKey[b];
      if (ka != null && ka == kb) return o.siblingGap;
      return o.groupGap;
    }

    final pos = <int, double>{}; // unit centre x
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

    void placeLayer(List<int> layer, Map<int, double> desired, Map<int, double> prio) {
      final n = layer.length;
      if (n == 0) return;
      final xs = [for (final u in layer) pos[u]!];
      final ws = [for (final u in layer) unitWidth(units[u])];
      final fixed = List.filled(n, false);
      final gaps = [0.0, for (var i = 1; i < n; i++) (ws[i - 1] + ws[i]) / 2 + gapBetween(layer[i - 1], layer[i])];

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
            acc += gaps[j];
            if (fixed[j]) {
              limit = xs[j] - acc;
              break;
            }
          }
          xs[i] = math.max(xs[i], math.min(d, limit));
          for (var j = i + 1; j < n; j++) {
            final need = xs[j - 1] + gaps[j];
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
            acc += gaps[j + 1];
            if (fixed[j]) {
              limit = xs[j] + acc;
              break;
            }
          }
          xs[i] = math.min(xs[i], math.max(d, limit));
          for (var j = i - 1; j >= 0; j--) {
            final need = xs[j + 1] - gaps[j + 1];
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

    // Each unit wants to sit over (down sweep) or under (up sweep) what it
    // connects to. Lanes have the highest priority so long lines run
    // straight.
    //
    // Children hanging from one anchor form a block centred under it: the
    // offset of each connection's unit from the middle of its block.
    Map<_Conn, double> blockShift(List<int> layer) {
      final idx = {for (var i = 0; i < layer.length; i++) layer[i]: i};
      final groups = <(int, double), List<_Conn>>{};
      for (final ui in layer) {
        for (final c in upConns[ui] ?? const <_Conn>[]) {
          (groups[(c.up.unit, c.upOff)] ??= []).add(c);
        }
      }
      final out = <_Conn, double>{};
      for (final cs in groups.values) {
        final us = {for (final c in cs) c.down.unit}.toList()..sort((a, b) => idx[a]!.compareTo(idx[b]!));
        final at = <int, double>{us.first: 0};
        for (var i = 1; i < us.length; i++) {
          at[us[i]] = at[us[i - 1]]! +
              (unitWidth(units[us[i - 1]]) + unitWidth(units[us[i]])) / 2 +
              gapBetween(us[i - 1], us[i]);
        }
        final anchors = [for (final c in cs) at[c.down.unit]! + c.downOff];
        final mid = (anchors.reduce(math.min) + anchors.reduce(math.max)) / 2;
        for (final c in cs) {
          out[c] = at[c.down.unit]! - mid;
        }
      }
      return out;
    }

    void sweep({required bool down}) {
      for (var k = 0; k < maxLayer; k++) {
        final L = down ? k + 1 : maxLayer - 1 - k;
        final desired = <int, double>{};
        final prio = <int, double>{};
        final shift = down ? blockShift(layers[L]) : const <_Conn, double>{};
        for (final ui in layers[L]) {
          final cs = (down ? upConns[ui] : downConns[ui]) ?? const <_Conn>[];
          var sum = 0.0;
          if (down) {
            for (final c in cs) {
              sum += pos[c.up.unit]! + c.upOff + shift[c]!;
            }
          } else {
            // Over the middle of each block of children it connects to.
            final groups = <double, List<double>>{};
            for (final c in cs) {
              (groups[c.upOff] ??= []).add(pos[c.down.unit]! + c.downOff);
            }
            for (final MapEntry(key: off, value: xs) in groups.entries) {
              sum += ((xs.reduce(math.min) + xs.reduce(math.max)) / 2 - off) * xs.length;
            }
          }
          if (cs.isEmpty) {
            prio[ui] = 0;
          } else {
            desired[ui] = sum / cs.length;
            prio[ui] = units[ui].isLane
                ? 1e9
                : 1000.0 * cs.length + ((down ? downConns[ui] : upConns[ui])?.length ?? 0);
          }
        }
        placeLayer(layers[L], desired, prio);
      }
    }

    for (var it = 0; it < 4; it++) {
      sweep(down: true);
      sweep(down: false);
    }
    sweep(down: true);

    double personX(String id) => pos[unitOf[id]]! + memberOffset(units[unitOf[id]!], id);
    double originX(_Family f) => pos[f.unit]! + familyOffset(f);

    // ---- horizontal lines per gap, each on its own track
    // Gap k lies between layer k and k + 1; gap -1 is above layer 0.
    final segs = <_Seg>[];
    for (final f in fams) {
      final ox = originX(f);
      final xs = <double>[
        for (final (c, _) in f.children)
          if (layerOf[c] == f.layer + 1) personX(c),
        for (final chain in f.chains.values) pos[chain.first]!,
      ];
      if (xs.isNotEmpty) segs.add(f.bus = _Seg(f.layer, [ox, ...xs]));
      for (final MapEntry(key: lc, value: chain) in f.chains.entries) {
        final hops = <_Seg>[];
        for (var i = 0; i < chain.length; i++) {
          final x = pos[chain[i]]!;
          final next = i + 1 < chain.length
              ? [pos[chain[i + 1]]!]
              : [for (final (c, _) in f.children) if (layerOf[c] == lc) personX(c)];
          hops.add(_Seg(units[chain[i]].layer, [x, ...next]));
        }
        segs.addAll(hops);
        f.hops[lc] = hops;
      }
    }
    final brackets = <(String, String), _Seg>{};
    for (final s in g.couples) {
      final a = s.personAId, b = s.personBId;
      if (!unitOf.containsKey(a) || !unitOf.containsKey(b) || a == b) continue;
      if (layerOf[a] != layerOf[b] || sideBySide(a, b)) continue;
      final ax = personX(a), bx = personX(b);
      final (l, r) = ax <= bx ? (ax, bx) : (bx, ax);
      final seg = _Seg(layerOf[a]! - 1, [l + W / 2 - PartnerConnector.bracketInset, r - W / 2 + PartnerConnector.bracketInset]);
      brackets[(a, b)] = seg;
      segs.add(seg);
    }
    final tracks = <int, int>{}; // gap -> number of tracks
    final byGap = <int, List<_Seg>>{};
    for (final s in segs) {
      (byGap[s.gap] ??= []).add(s);
    }
    for (final MapEntry(key: gap, value: list) in byGap.entries) {
      list.sort((a, b) {
        final c = a.lo.compareTo(b.lo);
        return c != 0 ? c : a.hi.compareTo(b.hi);
      });
      final ends = <double>[];
      for (final s in list) {
        var t = 0;
        while (t < ends.length && ends[t] + o.trackSpacing > s.lo) {
          t++;
        }
        if (t == ends.length) ends.add(0);
        ends[t] = math.max(s.hi, s.lo);
        s.track = t;
      }
      tracks[gap] = ends.length;
    }
    double gapHeight(int k) =>
        math.max(o.levelGap, 2 * o.trackPadding + ((tracks[k] ?? 1) - 1) * o.trackSpacing);
    final layerTop = <double>[0];
    for (var L = 1; L <= maxLayer; L++) {
      layerTop.add(layerTop[L - 1] + H + gapHeight(L - 1));
    }
    double trackY(_Seg s) {
      final n = tracks[s.gap] ?? 1;
      if (s.gap < 0) return -o.trackPadding - (n - 1 - s.track) * o.trackSpacing;
      final mid = layerTop[s.gap] + H + gapHeight(s.gap) / 2;
      return mid - (n - 1) * o.trackSpacing / 2 + s.track * o.trackSpacing;
    }

    // ---- final coordinates
    final nodes = <String, LayoutNode>{};
    for (final u in units) {
      for (final m in u.members) {
        nodes[m] = LayoutNode(m, u.layer)
          ..x = personX(m) - W / 2
          ..y = layerTop[u.layer];
      }
    }

    // ---- connectors, from the final card coordinates
    final partners = <PartnerConnector>[];
    for (final s in g.couples) {
      final a = nodes[s.personAId], b = nodes[s.personBId];
      if (a == null || b == null || a == b) continue;
      final left = a.x <= b.x ? a : b;
      final right = left == a ? b : a;
      final y = left.y + _connectorY(o);
      final bracket = brackets[(s.personAId, s.personBId)];
      partners.add(PartnerConnector(
        left.id,
        right.id,
        Offset(left.x + W, y),
        Offset(right.x, right.y + _connectorY(o)),
        s.status,
        s.type,
        adjacent: sideBySide(a.id, b.id),
        bracketY: bracket == null ? null : trackY(bracket),
      ));
    }

    final families = <FamilyConnector>[];
    for (final f in fams) {
      final ps = [...f.parents]..sort((a, b) => nodes[a]!.x.compareTo(nodes[b]!.x));
      final p0 = nodes[ps.first]!;
      final ox = originX(f);
      final origin = ps.length == 2 ? Offset(ox, p0.y + _connectorY(o)) : Offset(ox, p0.y + H);
      final bus = f.bus;
      final busY = bus != null ? trackY(bus) : p0.y + H + gapHeight(f.layer) / 2;
      final lines = <ChildLine>[];
      for (final (c, t) in f.children) {
        final n = nodes[c]!;
        final top = Offset(n.x + W / 2, n.y);
        final lc = n.layer;
        final hops = f.hops[lc];
        if (lc == f.layer + 1) {
          lines.add(ChildLine(c, t, top));
        } else if (hops != null) {
          // Down the lane through each generation, jogging on its own track.
          final chain = f.chains[lc]!;
          final route = [Offset(ox, busY)];
          var y = busY;
          for (var i = 0; i < chain.length; i++) {
            final x = pos[chain[i]]!;
            route
              ..add(Offset(x, y))
              ..add(Offset(x, y = trackY(hops[i])));
          }
          route
            ..add(Offset(top.dx, y))
            ..add(top);
          lines.add(ChildLine(c, t, top, route: _simplify(route)));
        } else {
          // Contradictory data (child not below this parent): join the
          // bottom of the child's card.
          final bottom = Offset(top.dx, n.y + H);
          lines.add(ChildLine(c, t, bottom, route: [Offset(ox, busY), Offset(top.dx, busY), bottom]));
        }
      }
      families.add(FamilyConnector(ps, origin, busY, lines));
    }

    // ---- bounds
    var content = Rect.zero;
    var first = true;
    void include(Offset p) {
      content = first ? Rect.fromPoints(p, p) : content.expandToInclude(Rect.fromPoints(p, p));
      first = false;
    }

    for (final n in nodes.values) {
      include(Offset(n.x, n.y));
      include(Offset(n.x + W, n.y + H));
    }
    for (final p in partners) {
      p.points(o).forEach(include);
    }
    for (final f in families) {
      include(f.origin);
      for (final c in f.children) {
        c.points(f.origin.dx, f.busY).forEach(include);
      }
    }
    final laid = TreeLayout(o, nodes, partners, families,
        Size(content.width + o.margin * 2, content.height + o.margin * 2),
        contentBounds: content);
    return _shift(laid, o.margin - content.left, o.margin - content.top);
  }

  /// Drops repeated and collinear points from an orthogonal polyline.
  static List<Offset> _simplify(List<Offset> pts) {
    final out = <Offset>[];
    for (final p in pts) {
      if (out.isNotEmpty && (out.last - p).distance < 0.01) continue;
      if (out.length >= 2) {
        final a = out[out.length - 2], b = out.last;
        final collinear = ((a.dx - b.dx).abs() < 0.01 && (b.dx - p.dx).abs() < 0.01) ||
            ((a.dy - b.dy).abs() < 0.01 && (b.dy - p.dy).abs() < 0.01);
        if (collinear) out.removeLast();
      }
      out.add(p);
    }
    return out;
  }

  int _byBirth(String a, String b) {
    final pa = g[a]!, pb = g[b]!;
    final ka = pa.birth?.sortKey ?? double.infinity;
    final kb = pb.birth?.sortKey ?? double.infinity;
    final c = ka.compareTo(kb);
    if (c != 0) return c;
    final t = pa.createdAt.compareTo(pb.createdAt);
    return t != 0 ? t : a.compareTo(b);
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

  /// Layer of every person: children below all their parents, partners on
  /// one layer, and as little empty space between generations as possible.
  Map<String, int> _assignLayers(Set<String> v,
      List<(String, String, ParentType)> pe, List<(String, String)> se) {
    final layer = {for (final id in v) id: 0};
    final n = v.length;
    // 1) Longest path from the top with partner equalisation. Bounded, so
    //    contradictory data (a partner who is also a descendant) cannot
    //    loop forever.
    for (var iter = 0; iter < n + 2; iter++) {
      var changed = false;
      for (final (p, c, _) in pe) {
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

    // 2) A branch that married in (parents without parents of their own,
    //    with their other children and partners) moves down as one block
    //    until it sits just above the child that connects it.
    final parentsOf = <String, List<String>>{};
    final childrenOf = <String, List<String>>{};
    for (final (p, c, _) in pe) {
      (parentsOf[c] ??= []).add(p);
      (childrenOf[p] ??= []).add(c);
    }
    final partnersOf = <String, List<String>>{};
    for (final (a, b) in se) {
      (partnersOf[a] ??= []).add(b);
      (partnersOf[b] ??= []).add(a);
    }
    bool hasParents(String id) => (parentsOf[id] ?? const []).isNotEmpty;

    for (var round = 0; round < 8; round++) {
      var changed = false;
      final seen = <String>{};
      for (final id in v) {
        if (seen.contains(id) || hasParents(id)) continue;
        // Root group: partners connected to [id], none with parents.
        final root = <String>{id};
        final q = Queue<String>()..add(id);
        var ok = true;
        while (q.isNotEmpty) {
          final x = q.removeFirst();
          for (final p in partnersOf[x] ?? const <String>[]) {
            if (hasParents(p)) ok = false;
            if (root.add(p)) q.add(p);
          }
        }
        seen.addAll(root);
        if (!ok) continue;
        // Everything below, then keep only what is closed upwards: all its
        // parents and partners are inside the block too.
        final block = <String>{...root};
        final bq = Queue<String>()..addAll(root);
        while (bq.isNotEmpty) {
          final x = bq.removeFirst();
          for (final c in childrenOf[x] ?? const <String>[]) {
            if (block.add(c)) bq.add(c);
          }
          for (final p in partnersOf[x] ?? const <String>[]) {
            if (block.add(p)) bq.add(p);
          }
        }
        var pruned = true;
        while (pruned) {
          pruned = false;
          block.removeWhere((x) {
            if (root.contains(x)) return false;
            final out = (parentsOf[x] ?? const <String>[]).any((p) => !block.contains(p)) ||
                (partnersOf[x] ?? const <String>[]).any((p) => !block.contains(p));
            if (out) pruned = true;
            return out;
          });
        }
        if (root.any((r) => !block.contains(r))) continue;
        var slack = 1 << 30;
        for (final x in block) {
          for (final c in childrenOf[x] ?? const <String>[]) {
            if (!block.contains(c)) slack = math.min(slack, layer[c]! - layer[x]! - 1);
          }
        }
        if (slack <= 0 || slack == 1 << 30) continue;
        for (final x in block) {
          layer[x] = layer[x]! + slack;
        }
        changed = true;
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
    Map<int, List<_Conn>> up,
    Map<int, List<_Conn>> down,
  ) {
    final placed = <int>{};
    bool place(int u) {
      if (!placed.add(u)) return false;
      layers[units[u].layer].add(u);
      return true;
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
      // The first person a connection leads to (through any lanes).
      String? lead(_Conn c) {
        var a = c.down;
        while (a.person == null) {
          final next = down[a.unit];
          if (next == null || next.isEmpty) return null;
          a = next.first.down;
        }
        return a.person;
      }

      int byLead(_Conn a, _Conn b) {
        final la = lead(a), lb = lead(b);
        if (la == null || lb == null) return (la == null ? 1 : 0) - (lb == null ? 1 : 0);
        return _byBirth(la, lb);
      }

      // DFS downward from top-layer units, children by birth order.
      void visitDown(int u) {
        if (!place(u)) return;
        // In-laws: the roots a partner descends from sit beside the couple.
        if (!units[u].isLane) {
          for (final c in up[u] ?? const <_Conn>[]) {
            var src = c.up.unit;
            while (units[src].isLane && (up[src]?.isNotEmpty ?? false)) {
              src = up[src]!.first.up.unit;
            }
            if ((up[src] ?? const []).isEmpty && !placed.contains(src)) visitDown(src);
          }
        }
        final next = [...?down[u]]..sort(byLead);
        for (final c in next) {
          visitDown(c.down.unit);
        }
      }

      final roots = [
        for (final u in units)
          if (!u.isLane && (up[u.index] ?? const []).isEmpty) u.index
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
        return fa.compareTo(fb);
      });
      for (final r in roots) {
        visitDown(r);
      }
    }
    for (final u in units) {
      place(u.index);
    }
  }

  /// Edge crossings between consecutive layers (inversion count).
  int _crossings(List<List<int>> layers, Map<int, Set<int>> down) {
    var total = 0;
    for (var L = 0; L < layers.length - 1; L++) {
      final posDn = {for (var i = 0; i < layers[L + 1].length; i++) layers[L + 1][i]: i};
      final seq = <int>[];
      for (final u in layers[L]) {
        final ds = [for (final d in down[u] ?? const <int>{}) ?posDn[d]]..sort();
        seq.addAll(ds);
      }
      total += _inversions(seq);
    }
    return total;
  }

  static int _inversions(List<int> a) {
    if (a.length < 2) return 0;
    var buf = List<int>.of(a), tmp = List<int>.filled(a.length, 0);
    var count = 0;
    for (var width = 1; width < a.length; width *= 2) {
      for (var lo = 0; lo < a.length; lo += 2 * width) {
        final mid = math.min(lo + width, a.length), hi = math.min(lo + 2 * width, a.length);
        var i = lo, j = mid, k = lo;
        while (i < mid && j < hi) {
          if (buf[j] < buf[i]) {
            count += mid - i;
            tmp[k++] = buf[j++];
          } else {
            tmp[k++] = buf[i++];
          }
        }
        while (i < mid) {
          tmp[k++] = buf[i++];
        }
        while (j < hi) {
          tmp[k++] = buf[j++];
        }
      }
      final t = buf;
      buf = tmp;
      tmp = t;
    }
    return count;
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
  void _orientCouples(List<_Unit> units, List<List<int>> layers, Map<String, List<int>> personUp) {
    // Normalised horizontal position (0..1) of each unit within its layer,
    // comparable across layers.
    final posN = <int, double>{};
    for (final l in layers) {
      for (var i = 0; i < l.length; i++) {
        posN[l[i]] = (i + 0.5) / l.length;
      }
    }
    double? parentPos(String id) {
      final ups = personUp[id];
      if (ups == null || ups.isEmpty) return null;
      return ups.map((u) => posN[u]!).reduce((a, b) => a + b) / ups.length;
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

  /// People side by side (partners); empty for a lane that carries a line
  /// through this layer.
  final List<String> members;

  bool get isLane => members.isEmpty;
}

/// A parent or couple and the children whose lines come from them.
class _Family {
  _Family(this.id, this.parents, this.unit, this.layer);
  final int id;
  final List<String> parents;
  final int unit;
  final int layer;
  final children = <(String, ParentType)>[];

  /// Lanes towards children further down, by the children's layer.
  final chains = <int, List<int>>{};

  /// The family's own horizontal line, and the jogs of each lane.
  _Seg? bus;
  final hops = <int, List<_Seg>>{};
}

/// Where a connection attaches to a unit: a person, a family's origin or
/// (neither) a lane.
class _Anchor {
  _Anchor(this.unit, {this.person, this.family});
  final int unit;
  final String? person;
  final _Family? family;
}

class _Conn {
  _Conn(this.up, this.down);
  final _Anchor up;
  final _Anchor down;
  double upOff = 0;
  double downOff = 0;
}

/// A horizontal line in the gap below layer [gap].
class _Seg {
  _Seg(this.gap, List<double> xs)
      : lo = xs.reduce(math.min),
        hi = xs.reduce(math.max);
  final int gap;
  final double lo;
  final double hi;
  int track = 0;
}
