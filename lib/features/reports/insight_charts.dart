import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/widgets/widgets.dart';

/// One bar / slice.
class ChartDatum {
  const ChartDatum(this.label, this.value);
  final String label;
  final int value;
}

/// Shown inside a chart card when there is nothing meaningful to draw.
class ChartEmpty extends StatelessWidget {
  const ChartEmpty({super.key, this.hint});
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: Gap.lg, horizontal: Gap.md),
      decoration: BoxDecoration(
        color: c.text.withValues(alpha: c.isDark ? 0.03 : 0.025),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Icon(AppIcons.stats, size: 22, color: c.text3),
          const SizedBox(height: Gap.xs),
          Text('Not enough data yet',
              textAlign: TextAlign.center, style: context.tx.label.copyWith(color: c.text2)),
          if (hint != null) ...[
            const SizedBox(height: 2),
            Text(hint!, textAlign: TextAlign.center, style: context.tx.caption),
          ],
        ],
      ),
    );
  }
}

/// Wraps a value-from-0-to-1 animation that respects reduced motion.
class _Grow extends StatelessWidget {
  const _Grow({required this.builder});
  final Widget Function(BuildContext context, double t) builder;

  @override
  Widget build(BuildContext context) {
    if (context.reduceMotion) return builder(context, 1);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 700),
      curve: Motion.emphasized,
      builder: (context, t, _) => builder(context, t),
    );
  }
}

// ================================================================== bars

/// Vertical bar chart: rounded mint bars on graphite tracks, value labels
/// on top and caption-style axis labels underneath. Labels are thinned
/// automatically when they would overlap.
class InsightBarChart extends StatelessWidget {
  const InsightBarChart({
    super.key,
    required this.data,
    required this.semanticsLabel,
    this.barAreaHeight = 132,
    this.highlightMax = true,
  });

  final List<ChartDatum> data;
  final String semanticsLabel;
  final double barAreaHeight;
  final bool highlightMax;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final scaler = MediaQuery.textScalerOf(context);
    final labelStyle = context.tx.micro.copyWith(color: c.text3, letterSpacing: 0);
    final valueStyle = context.tx.micro.copyWith(color: c.text2, fontWeight: FontWeight.w600, letterSpacing: 0);
    final lineH = scaler.scale(11) * 1.35;
    final height = barAreaHeight + lineH * 2 + 14;
    final summary = data.map((d) => '${d.label}: ${d.value}').join(', ');
    return Semantics(
      label: '$semanticsLabel. $summary',
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: _Grow(
          builder: (context, t) => CustomPaint(
            painter: _BarPainter(
              data: data,
              t: t,
              track: c.text.withValues(alpha: c.isDark ? 0.055 : 0.06),
              barTop: c.accentHi,
              barBottom: c.accent2,
              dimmed: c.accent.withValues(alpha: 0.55),
              baseline: c.border,
              labelStyle: labelStyle,
              valueStyle: valueStyle,
              scaler: scaler,
              lineH: lineH,
              highlightMax: highlightMax,
              textDirection: Directionality.of(context),
            ),
          ),
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.data,
    required this.t,
    required this.track,
    required this.barTop,
    required this.barBottom,
    required this.dimmed,
    required this.baseline,
    required this.labelStyle,
    required this.valueStyle,
    required this.scaler,
    required this.lineH,
    required this.highlightMax,
    required this.textDirection,
  });

  final List<ChartDatum> data;
  final double t;
  final Color track;
  final Color barTop;
  final Color barBottom;
  final Color dimmed;
  final Color baseline;
  final TextStyle labelStyle;
  final TextStyle valueStyle;
  final TextScaler scaler;
  final double lineH;
  final bool highlightMax;
  final TextDirection textDirection;

  TextPainter _tp(String s, TextStyle style) => TextPainter(
        text: TextSpan(text: s, style: style),
        textDirection: textDirection,
        textScaler: scaler,
        maxLines: 1,
      )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final n = data.length;
    if (n == 0 || size.width <= 0) return;
    final maxV = data.map((d) => d.value).fold<int>(0, math.max);
    final top = lineH + 6;
    final bottom = size.height - lineH - 8;
    final area = math.max(0.0, bottom - top);
    final slot = size.width / n;
    final barW = (slot * 0.56).clamp(3.0, 30.0);
    final radius = Radius.circular(math.min(barW / 2, 10));

    final labels = [for (final d in data) _tp(d.label, labelStyle)];
    final widest = labels.fold<double>(0, (a, p) => math.max(a, p.width));
    final step = math.max(1, ((widest + 8) / slot).ceil());

    final values = [for (final d in data) _tp('${d.value}', valueStyle)];
    final widestValue = values.fold<double>(0, (a, p) => math.max(a, p.width));
    final showValues = widestValue + 2 <= slot;

    final trackPaint = Paint()..color = track;
    for (var i = 0; i < n; i++) {
      final cx = slot * (i + 0.5);
      final trackRect = Rect.fromLTWH(cx - barW / 2, top, barW, area);
      canvas.drawRRect(RRect.fromRectAndRadius(trackRect, radius), trackPaint);

      final v = data[i].value;
      if (v > 0 && maxV > 0) {
        var h = area * (v / maxV) * t;
        h = math.max(h, math.min(barW, area) * t);
        final r = Rect.fromLTWH(cx - barW / 2, bottom - h, barW, h);
        final paint = Paint();
        if (!highlightMax || v == maxV) {
          paint.shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [barTop, barBottom],
          ).createShader(r);
        } else {
          paint.color = dimmed;
        }
        canvas.drawRRect(RRect.fromRectAndRadius(r, radius), paint);
        if (showValues && t > 0.6) {
          final vp = values[i];
          vp.paint(canvas, Offset(cx - vp.width / 2, bottom - h - vp.height - 3));
        }
      }

      if (i % step == 0) {
        final lp = labels[i];
        var x = cx - lp.width / 2;
        x = x.clamp(0.0, math.max(0.0, size.width - lp.width));
        lp.paint(canvas, Offset(x, bottom + 7));
      }
    }

    canvas.drawLine(
      Offset(0, bottom + 0.5),
      Offset(size.width, bottom + 0.5),
      Paint()
        ..color = baseline
        ..strokeWidth = 1,
    );
    for (final p in [...labels, ...values]) {
      p.dispose();
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.t != t ||
      old.data != data ||
      old.track != track ||
      old.barTop != barTop ||
      old.scaler != scaler;
}

// ========================================================= horizontal bars

/// Labelled horizontal bars (for categories with long names).
class InsightHBars extends StatelessWidget {
  const InsightHBars({super.key, required this.data, this.icons});
  final List<ChartDatum> data;

  /// Optional icon per row (same order as [data]).
  final List<IconData>? icons;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final maxV = data.map((d) => d.value).fold<int>(0, math.max);
    return Semantics(
      label: data.map((d) => '${d.label}: ${d.value}').join(', '),
      excludeSemantics: true,
      child: _Grow(
        builder: (context, t) => Column(
          children: [
            for (var i = 0; i < data.length; i++) ...[
              if (i > 0) const SizedBox(height: Gap.sm),
              Row(
                children: [
                  if (icons != null) ...[
                    Icon(icons![i], size: 16, color: c.text3),
                    const SizedBox(width: Gap.xs),
                  ],
                  Expanded(
                    child: Text(data[i].label,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.label),
                  ),
                  const SizedBox(width: Gap.xs),
                  Text('${data[i].value}', style: context.tx.label.copyWith(color: c.text2)),
                ],
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 8,
                width: double.infinity,
                child: CustomPaint(
                  painter: _HBarPainter(
                    fraction: maxV == 0 ? 0 : data[i].value / maxV * t,
                    track: c.text.withValues(alpha: c.isDark ? 0.06 : 0.07),
                    from: c.accent2,
                    to: c.accentHi,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HBarPainter extends CustomPainter {
  _HBarPainter({required this.fraction, required this.track, required this.from, required this.to});
  final double fraction;
  final Color track;
  final Color from;
  final Color to;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, r), Paint()..color = track);
    if (fraction <= 0) return;
    final w = math.max(size.height, size.width * fraction.clamp(0.0, 1.0));
    final rect = Rect.fromLTWH(0, 0, w, size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, r),
      Paint()..shader = LinearGradient(colors: [from, to]).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_HBarPainter old) =>
      old.fraction != fraction || old.track != track || old.from != from;
}

// ================================================================= donut

/// Palette for donut slices: mint first, then graphite shades.
List<Color> donutPalette(FTColors c, int n) {
  final base = <Color>[
    c.accent,
    Color.lerp(c.accent, c.isDark ? c.surfaceHigher : c.cardBottom, 0.5)!,
    c.text.withValues(alpha: c.isDark ? 0.55 : 0.6),
    c.text.withValues(alpha: c.isDark ? 0.34 : 0.4),
    c.text.withValues(alpha: c.isDark ? 0.2 : 0.24),
    c.text.withValues(alpha: c.isDark ? 0.11 : 0.13),
  ];
  return [for (var i = 0; i < n; i++) base[i % base.length]];
}

/// Donut chart with a centred total and a legend (percentages).
class InsightDonut extends StatelessWidget {
  const InsightDonut({
    super.key,
    required this.data,
    required this.centerLabel,
    required this.semanticsLabel,
  });

  final List<ChartDatum> data;
  final String centerLabel;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final total = data.fold<int>(0, (a, d) => a + d.value);
    final colors = donutPalette(c, data.length);
    String pct(int v) => total == 0 ? '0%' : '${(v / total * 100).round()}%';
    final summary = data.map((d) => '${d.label} ${d.value}, ${pct(d.value)}').join('; ');

    Widget donut(double size) => SizedBox(
          width: size,
          height: size,
          child: _Grow(
            builder: (context, t) => CustomPaint(
              painter: _DonutPainter(
                values: [for (final d in data) d.value],
                colors: colors,
                track: c.text.withValues(alpha: c.isDark ? 0.05 : 0.06),
                t: t,
              ),
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(size * 0.2),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('$total', style: context.tx.headline.copyWith(fontSize: 22)),
                        Text(centerLabel, style: context.tx.caption),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

    final legend = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < data.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: colors[i], shape: BoxShape.circle),
                ),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(data[i].label,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.label),
                ),
                const SizedBox(width: Gap.xs),
                Text('${data[i].value}', style: context.tx.label.copyWith(color: c.text2)),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 36),
                  child: Text(pct(data[i].value),
                      textAlign: TextAlign.end, style: context.tx.caption),
                ),
              ],
            ),
          ),
      ],
    );

    return Semantics(
      label: '$semanticsLabel. $summary',
      excludeSemantics: true,
      child: LayoutBuilder(builder: (context, cons) {
        final wide = cons.maxWidth >= 300;
        final size = math.min(148.0, wide ? cons.maxWidth * 0.42 : cons.maxWidth * 0.6);
        if (!wide) {
          return Column(
            children: [
              donut(size),
              const SizedBox(height: Gap.md),
              legend,
            ],
          );
        }
        return Row(
          children: [
            donut(size),
            const SizedBox(width: Gap.lg),
            Expanded(child: legend),
          ],
        );
      }),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({required this.values, required this.colors, required this.track, required this.t});
  final List<int> values;
  final List<Color> colors;
  final Color track;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.13;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: (size.shortestSide - stroke) / 2,
    );
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    final total = values.fold<int>(0, (a, b) => a + b);
    if (total == 0) return;
    final nonZero = values.where((v) => v > 0).length;
    final gap = nonZero > 1 ? 0.045 : 0.0;
    var start = -math.pi / 2;
    final full = math.pi * 2 * t;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v <= 0) continue;
      final sweep = full * v / total;
      final visible = sweep - gap;
      if (visible > 0) {
        canvas.drawArc(
          rect,
          start + gap / 2,
          visible,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.butt
            ..color = colors[i],
        );
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.t != t || old.values != values || old.track != track || old.colors != colors;
}
