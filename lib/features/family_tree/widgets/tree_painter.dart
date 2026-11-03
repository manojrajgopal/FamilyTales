import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';

import '../../../core/models/enums.dart';
import '../layout/tree_layout.dart';

/// Paints every connector of a [TreeLayout] in one pass.
///
/// * Couples: horizontal line at avatar height with a small ring marker.
///   Ended relationships (divorced/separated/ended) are dashed, engagements
///   dotted.
/// * Parent → children: vertical drop from the couple midpoint to a bus,
///   rounded orthogonal elbows down to each child; a child several
///   generations down follows its routed lane. Biological = solid,
///   adoptive = dashed, step = dotted, foster/guardian = dash-dot.
/// * Partners who cannot stand side by side: a bracket over the cards
///   between them.
/// * Gender colours (when given): each parent's own line, down to the point
///   where it meets the other parent's line, and their half of the couple
///   line take the colour of their card border. Shared lines stay neutral.
/// * Lineage of the selected person (ancestors + descendants) is redrawn in
///   the accent colour on top.
class TreeConnectorPainter extends CustomPainter {
  TreeConnectorPainter({
    required this.layout,
    required this.line,
    required this.accent,
    required this.background,
    required this.highlight,
    this.personColors = const {},
  });

  final TreeLayout layout;
  final Color line;
  final Color accent;
  final Color background;

  /// Person ids whose connecting lines are highlighted.
  final Set<String> highlight;

  /// Line colour per person (gender colour); people not listed stay neutral.
  final Map<String, Color> personColors;

  static const _r = 12.0; // elbow radius

  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final hi = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final glow = Paint()
      ..color = accent.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    Paint tinted(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // How many parent lines reach each child: where two meet, the shared
    // drop below the meeting point stays neutral.
    final incoming = <String, int>{};
    for (final f in layout.families) {
      for (final c in f.children) {
        incoming[c.childId] = (incoming[c.childId] ?? 0) + 1;
      }
    }

    // ---------------------------------------------------------- families
    final hiPaths = <Path>[];
    final colored = <(Path, Paint, ParentType)>[];
    for (final f in layout.families) {
      if (f.children.isEmpty) continue;
      final o = f.origin;
      final busY = f.busY;
      final parentsHi = f.parents.any(highlight.contains);

      // Trunk from the couple to the bus, then a rounded elbow to each child.
      final types = f.children.map((c) => c.type).toSet();
      final trunkType = types.length == 1 ? types.first : ParentType.biological;
      final trunk = Path()
        ..moveTo(o.dx, o.dy)
        ..lineTo(o.dx, busY - _r);
      _stroke(canvas, trunk, base, trunkType);
      // A single parent's line is theirs alone; a couple's trunk is shared.
      final own = f.parents.length == 1 ? personColors[f.parents.first] : null;
      if (own != null) colored.add((trunk, tinted(own), trunkType));
      for (final c in f.children) {
        final (p, tail) = _rounded([Offset(o.dx, busY - _r), ...c.points(o.dx, busY)]);
        _stroke(canvas, p, base, c.type);
        if (own != null) {
          final merged = (incoming[c.childId] ?? 0) > 1;
          colored.add((merged ? _trimEnd(p, tail) : p, tinted(own), c.type));
        }
        if (parentsHi && highlight.contains(c.childId)) {
          hiPaths.add(Path()
            ..moveTo(o.dx, o.dy)
            ..lineTo(o.dx, busY - _r)
            ..addPath(p, Offset.zero));
        }
      }
    }

    // ---------------------------------------------------------- partners
    for (final s in layout.partners) {
      final a = s.from, b = s.to;
      var path = Path();
      if (!s.adjacent && s.bracketY != null) {
        // Partners who are not side by side: a bracket over the cards
        // between them, on its own track.
        path = _rounded(s.points(layout.options)).$1;
      } else if (s.adjacent || (b.dx - a.dx).abs() < layout.options.nodeWidth * 1.5) {
        path
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy);
      } else {
        // Non-adjacent partners: arc above the row.
        final lift = 36.0;
        path
          ..moveTo(a.dx - layout.options.nodeWidth / 2, a.dy - 50)
          ..cubicTo(a.dx - layout.options.nodeWidth / 2, a.dy - 50 - lift,
              b.dx + layout.options.nodeWidth / 2, b.dy - 50 - lift,
              b.dx + layout.options.nodeWidth / 2, b.dy - 50);
      }
      final ended = s.status == PartnerStatus.divorced ||
          s.status == PartnerStatus.separated ||
          s.status == PartnerStatus.ended ||
          s.status == PartnerStatus.annulled;
      final isHi = highlight.contains(s.a) && highlight.contains(s.b);
      void draw(Path path, Paint p) {
        if (s.type == PartnerType.engaged) {
          _dashed(canvas, path, p, 2, 5);
        } else if (ended) {
          _dashed(canvas, path, p, 7, 6);
        } else {
          canvas.drawPath(path, p);
        }
      }

      draw(path, isHi ? hi : base);
      if (!isHi && s.adjacent) {
        // Each partner's half of the couple line, up to the meeting point.
        final mid = Offset((a.dx + b.dx) / 2, a.dy);
        final ca = personColors[s.a], cb = personColors[s.b];
        if (ca != null) draw(Path()..moveTo(a.dx, a.dy)..lineTo(mid.dx, mid.dy), tinted(ca));
        if (cb != null) draw(Path()..moveTo(mid.dx, mid.dy)..lineTo(b.dx, b.dy), tinted(cb));
      }
      if (s.adjacent) {
        final mid = Offset((a.dx + b.dx) / 2, a.dy);
        canvas.drawCircle(mid, 5.5, Paint()..color = background);
        canvas.drawCircle(
            mid,
            5.5,
            Paint()
              ..color = isHi ? accent : line
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.6);
        if (!ended) canvas.drawCircle(mid, 2.2, Paint()..color = isHi ? accent : line);
      }
    }

    // Gender-coloured parent lines go over the neutral ones.
    for (final (path, paint, type) in colored) {
      _stroke(canvas, path, paint, type);
    }

    // --------------------------------------------------------- highlight
    for (final p in hiPaths) {
      canvas.drawPath(p, glow);
      canvas.drawPath(p, hi);
    }
  }

  /// [path] without its last [tail] pixels: a parent's own line up to where
  /// it meets the other parent's line above the child.
  Path _trimEnd(Path path, double tail) {
    final out = Path();
    for (final m in path.computeMetrics()) {
      out.addPath(m.extractPath(0, (m.length - tail).clamp(0.0, m.length)), Offset.zero);
    }
    return out;
  }

  /// Orthogonal polyline with rounded corners, and the length of its final
  /// straight run after the last corner.
  (Path, double) _rounded(List<Offset> raw) {
    final pts = <Offset>[];
    for (final q in raw) {
      if (pts.isNotEmpty && (pts.last - q).distance < 0.01) continue;
      if (pts.length >= 2) {
        final a = pts[pts.length - 2], b = pts.last;
        if (((a.dx - b.dx).abs() < 0.01 && (b.dx - q.dx).abs() < 0.01) ||
            ((a.dy - b.dy).abs() < 0.01 && (b.dy - q.dy).abs() < 0.01)) {
          pts.removeLast();
        }
      }
      pts.add(q);
    }
    final p = Path()..moveTo(pts.first.dx, pts.first.dy);
    if (pts.length < 2) return (p, 0.0);
    var tail = (pts.last - pts[pts.length - 2]).distance;
    for (var i = 1; i < pts.length - 1; i++) {
      final a = pts[i - 1], b = pts[i], c = pts[i + 1];
      final lin = (b - a).distance, lout = (c - b).distance;
      // The first and last runs may be used up entirely by a corner; inner
      // runs are shared by two corners.
      final r = math.min(_r, math.min(i == 1 ? lin : lin / 2, i == pts.length - 2 ? lout : lout / 2));
      final p1 = b - (b - a) / lin * r, p2 = b + (c - b) / lout * r;
      p
        ..lineTo(p1.dx, p1.dy)
        ..quadraticBezierTo(b.dx, b.dy, p2.dx, p2.dy);
      if (i == pts.length - 2) tail = lout - r;
    }
    p.lineTo(pts.last.dx, pts.last.dy);
    return (p, tail);
  }

  void _stroke(Canvas canvas, Path path, Paint paint, ParentType type) {
    switch (type) {
      case ParentType.biological:
      case ParentType.unknown:
        canvas.drawPath(path, paint);
      case ParentType.adoptive:
        _dashed(canvas, path, paint, 8, 5);
      case ParentType.step:
        _dashed(canvas, path, paint, 2, 5);
      case ParentType.foster:
      case ParentType.guardian:
        _dashed(canvas, path, paint, 10, 4, dot: true);
    }
  }

  void _dashed(Canvas canvas, Path path, Paint paint, double on, double off, {bool dot = false}) {
    for (final ui.PathMetric m in path.computeMetrics()) {
      var d = 0.0;
      var draw = true;
      var phase = 0;
      while (d < m.length) {
        double len;
        if (dot) {
          // dash-dot pattern: on, off, 1.5, off
          len = draw ? (phase.isEven ? on : 1.5) : off;
        } else {
          len = draw ? on : off;
        }
        if (draw) {
          canvas.drawPath(m.extractPath(d, (d + len).clamp(0, m.length)), paint);
          phase++;
        }
        d += len;
        draw = !draw;
      }
    }
  }

  @override
  bool shouldRepaint(TreeConnectorPainter old) =>
      old.layout != layout ||
      old.line != line ||
      old.accent != accent ||
      !mapEquals(old.personColors, personColors) ||
      !_setEq(old.highlight, highlight);

  static bool _setEq(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);
}
