import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/models/enums.dart';
import '../layout/tree_layout.dart';

/// Paints every connector of a [TreeLayout] in one pass.
///
/// * Couples: horizontal line at avatar height with a small ring marker.
///   Ended relationships (divorced/separated/ended) are dashed, engagements
///   dotted.
/// * Parent → children: vertical drop from the couple midpoint to a bus,
///   rounded orthogonal elbows down to each child. Biological = solid,
///   adoptive = dashed, step = dotted, foster/guardian = dash-dot.
/// * Lineage of the selected person (ancestors + descendants) is redrawn in
///   the accent colour on top.
class TreeConnectorPainter extends CustomPainter {
  TreeConnectorPainter({
    required this.layout,
    required this.line,
    required this.accent,
    required this.background,
    required this.highlight,
  });

  final TreeLayout layout;
  final Color line;
  final Color accent;
  final Color background;

  /// Person ids whose connecting lines are highlighted.
  final Set<String> highlight;

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

    // ---------------------------------------------------------- families
    final hiPaths = <Path>[];
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
      for (final c in f.children) {
        final p = _elbow(Offset(o.dx, busY), c.top);
        _stroke(canvas, p, base, c.type);
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
      final path = Path();
      if (s.adjacent || (b.dx - a.dx).abs() < layout.options.nodeWidth * 1.5) {
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
      final p = isHi ? hi : base;
      if (s.type == PartnerType.engaged) {
        _dashed(canvas, path, p, 2, 5);
      } else if (ended) {
        _dashed(canvas, path, p, 7, 6);
      } else {
        canvas.drawPath(path, p);
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

    // --------------------------------------------------------- highlight
    for (final p in hiPaths) {
      canvas.drawPath(p, glow);
      canvas.drawPath(p, hi);
    }
  }

  /// Rounded orthogonal path from the bus junction to a child's top edge.
  Path _elbow(Offset from, Offset childTop) {
    final p = Path();
    final dx = childTop.dx - from.dx;
    if (dx.abs() < 1) {
      p
        ..moveTo(from.dx, from.dy - _r)
        ..lineTo(childTop.dx, childTop.dy);
      return p;
    }
    final dir = dx.sign;
    final r = dx.abs() < _r * 2 ? dx.abs() / 2 : _r;
    p
      ..moveTo(from.dx, from.dy - r)
      ..quadraticBezierTo(from.dx, from.dy, from.dx + dir * r, from.dy)
      ..lineTo(childTop.dx - dir * r, from.dy)
      ..quadraticBezierTo(childTop.dx, from.dy, childTop.dx, from.dy + r)
      ..lineTo(childTop.dx, childTop.dy);
    return p;
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
      !_setEq(old.highlight, highlight);

  static bool _setEq(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);
}
