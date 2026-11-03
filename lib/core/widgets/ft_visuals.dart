import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';

/// Circular person avatar: photo thumbnail when available, otherwise
/// initials on a graphite gradient. Images are decoded at display size to
/// keep memory low.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.name,
    this.imagePath,
    this.size = 44,
    this.ring = false,
    this.deceased = false,
    this.heroTag,
  });

  final String name;
  final String? imagePath;
  final double size;

  /// Accent ring (selection / focus).
  final bool ring;

  /// Desaturates the photo slightly for deceased relatives.
  final bool deceased;
  final Object? heroTag;

  static String initialsOf(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    final f = parts.first.characters.first;
    final l = parts.length > 1 ? parts.last.characters.first : '';
    return (f + l).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final file = imagePath == null ? null : File(imagePath!);
    Widget inner;
    if (file != null) {
      inner = Image.file(
        file,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * dpr).round(),
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _initials(context),
      );
      if (deceased) {
        inner = ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            0.55, 0.35, 0.10, 0, 0, //
            0.25, 0.65, 0.10, 0, 0,
            0.25, 0.35, 0.40, 0, 0,
            0, 0, 0, 1, 0,
          ]),
          child: inner,
        );
      }
    } else {
      inner = _initials(context);
    }
    Widget avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: ring ? c.accent : c.borderStrong,
          width: ring ? 2 : 1,
        ),
        boxShadow: ring
            ? [
                BoxShadow(
                  color: c.accent.withValues(alpha: 0.35),
                  blurRadius: 14,
                  spreadRadius: -2,
                )
              ]
            : null,
      ),
      padding: EdgeInsets.all(ring ? 2 : 0),
      child: ClipOval(child: inner),
    );
    if (heroTag != null) avatar = Hero(tag: heroTag!, child: avatar);
    return Semantics(
      image: true,
      label: 'Photo of $name',
      excludeSemantics: true,
      child: avatar,
    );
  }

  Widget _initials(BuildContext context) {
    final c = context.ft;
    final hash = name.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0xFFFF);
    final angle = (hash % 360) / 360 * math.pi * 2;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(math.cos(angle), math.sin(angle)),
          end: Alignment(-math.cos(angle), -math.sin(angle)),
          colors: c.isDark
              ? [
                  Color.lerp(const Color(0xFF3B3D44), c.accent, 0.10)!,
                  const Color(0xFF1C1D22),
                ]
              : [Colors.white, const Color(0xFFE2E4E8)],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initialsOf(name),
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: size * 0.36,
          fontWeight: FontWeight.w500,
          color: c.isDark ? c.text.withValues(alpha: 0.9) : c.text2,
          letterSpacing: -0.3,
        ),
      ),
    );
  }
}

/// Overlapping avatars with a trailing "20+" counter (reference task card).
class AvatarStack extends StatelessWidget {
  const AvatarStack({
    super.key,
    required this.people,
    this.size = 30,
    this.max = 3,
    this.total,
  });

  /// (name, imagePath) pairs.
  final List<(String, String?)> people;
  final double size;
  final int max;
  final int? total;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final shown = people.take(max).toList();
    final count = total ?? people.length;
    final extra = count - shown.length;
    final step = size * 0.68;
    final width = shown.isEmpty
        ? 0.0
        : step * (shown.length - 1) + size + (extra > 0 ? step + 6 : 0);
    return SizedBox(
      width: width + (extra > 0 ? 12 : 0),
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * step,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: c.cardMid, width: 2),
                ),
                child: PersonAvatar(
                    name: shown[i].$1, imagePath: shown[i].$2, size: size - 4),
              ),
            ),
          if (extra > 0)
            Positioned(
              left: shown.length * step,
              child: Container(
                height: size,
                constraints: BoxConstraints(minWidth: size),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: c.surfaceHigher,
                  borderRadius: BorderRadius.circular(size),
                  border: Border.all(color: c.cardMid, width: 2),
                ),
                alignment: Alignment.center,
                child: Text('$extra+',
                    style: context.tx.micro
                        .copyWith(color: c.text, fontSize: size * 0.33)),
              ),
            ),
        ],
      ),
    );
  }
}

/// The "Work in Progress ////// 70%" bar from the reference, used for
/// profile completeness and storage meters.
class StripedProgress extends StatelessWidget {
  const StripedProgress({
    super.key,
    required this.value,
    required this.label,
    this.trailing,
    this.height = 40,
  });

  final double value;
  final String label;
  final String? trailing;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final v = value.clamp(0.0, 1.0);
    return Semantics(
      label: '$label ${(v * 100).round()} percent',
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            Expanded(
              child: LayoutBuilder(builder: (context, cons) {
                return Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _StripePainter(
                          c.text.withValues(alpha: c.isDark ? 0.09 : 0.08),
                          v,
                          c.text.withValues(alpha: c.isDark ? 0.05 : 0.04),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 12,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Text(label,
                            style: context.tx.caption.copyWith(color: c.text2)),
                      ),
                    ),
                  ],
                );
              }),
            ),
            Container(
              width: 64,
              alignment: Alignment.center,
              child: Text(
                trailing ?? '${(v * 100).round()}%',
                style: context.tx.bodyStrong.copyWith(fontSize: 15),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StripePainter extends CustomPainter {
  _StripePainter(this.stripe, this.value, this.track);
  final Color stripe;
  final double value;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = track);
    final w = size.width * value;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, w, size.height));
    final p = Paint()
      ..color = stripe
      ..strokeWidth = 1.6;
    for (double x = -size.height; x < w + size.height; x += 7) {
      canvas.drawLine(
          Offset(x, size.height), Offset(x + size.height, 0), p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StripePainter old) =>
      old.value != value || old.stripe != stripe;
}

/// Dashed circular outline (out-of-month calendar days in the reference).
class DashedCirclePainter extends CustomPainter {
  DashedCirclePainter(this.color, {this.dashes = 14, this.strokeWidth = 1.2});
  final Color color;
  final int dashes;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final r = (math.min(size.width, size.height) - strokeWidth) / 2;
    final center = size.center(Offset.zero);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final sweep = math.pi * 2 / dashes;
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(Rect.fromCircle(center: center, radius: r),
          i * sweep, sweep * 0.55, false, p);
    }
  }

  @override
  bool shouldRepaint(DashedCirclePainter old) => old.color != color;
}

/// Small metric block: big number + caption.
class MetricTile extends StatelessWidget {
  const MetricTile({super.key, required this.value, required this.label, this.icon});
  final String value;
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Semantics(
      label: '$value $label',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: c.accent),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.tx.caption),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            style: context.tx.headline.copyWith(fontSize: 24),
          ),
        ],
      ),
    );
  }
}
