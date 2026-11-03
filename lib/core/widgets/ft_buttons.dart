import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import 'ft_surfaces.dart';

/// Circular graphite icon button (bell / calendar / back in the reference).
class FTIconButton extends StatelessWidget {
  const FTIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.size = 48,
    this.iconSize,
    this.accent = false,
    this.badge = false,
    this.selected = false,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;
  final double size;
  final double? iconSize;
  final bool accent;

  /// Shows a small accent dot (e.g. pending reminders).
  final bool badge;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final filled = accent || selected;
    final visual = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: filled ? c.accentGradient : c.chipGradient,
        boxShadow: [
          BoxShadow(
            color: filled
                ? c.accent.withValues(alpha: 0.30)
                : c.shadow.withValues(alpha: c.isDark ? 0.55 : 0.10),
            blurRadius: filled ? 18 : 14,
            spreadRadius: filled ? -2 : 0,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      foregroundDecoration: filled
          ? null
          : BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c.border),
            ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(icon,
              size: iconSize ?? size * 0.44,
              color: filled ? c.onAccent : c.text),
          if (badge)
            Positioned(
              top: size * 0.24,
              right: size * 0.26,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: c.accent,
                  shape: BoxShape.circle,
                  border: Border.all(color: c.surfaceHigh, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
    // Guarantee a 48px touch target even for smaller visuals.
    final target = math.max(48.0, size);
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: Pressable(
        onTap: onTap,
        semanticLabel: tooltip,
        scale: 0.92,
        child: SizedBox(
          width: target,
          height: target,
          child: Center(child: visual),
        ),
      ),
    );
  }
}

enum FTButtonKind { primary, secondary, ghost, danger }

/// Pill button. Primary = accent fill with dark label, secondary = graphite.
class FTButton extends StatelessWidget {
  const FTButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.kind = FTButtonKind.primary,
    this.expand = false,
    this.loading = false,
    this.height = 54,
    this.trailingIcon,
  });

  const FTButton.secondary({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.expand = false,
    this.loading = false,
    this.height = 54,
    this.trailingIcon,
  }) : kind = FTButtonKind.secondary;

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final IconData? trailingIcon;
  final FTButtonKind kind;
  final bool expand;
  final bool loading;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final t = context.tx;
    final (Gradient? g, Color? fill, Color fg, bool border) = switch (kind) {
      FTButtonKind.primary => (c.accentGradient, null, c.onAccent, false),
      FTButtonKind.secondary => (c.chipGradient, null, c.text, true),
      FTButtonKind.ghost => (null, Colors.transparent, c.text2, true),
      FTButtonKind.danger => (
          null,
          c.danger.withValues(alpha: c.isDark ? 0.14 : 0.10),
          c.danger,
          false
        ),
    };
    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading)
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          )
        else if (icon != null)
          Icon(icon, size: 19, color: fg),
        if (loading || icon != null) const SizedBox(width: 10),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.label.copyWith(
                color: fg, fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        if (trailingIcon != null) ...[
          const SizedBox(width: 10),
          Icon(trailingIcon, size: 18, color: fg),
        ],
      ],
    );
    return Pressable(
      onTap: loading ? null : onTap,
      enabled: onTap != null,
      semanticLabel: label,
      child: Container(
        height: height,
        constraints: const BoxConstraints(minWidth: 64),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          gradient: g,
          color: fill,
          borderRadius: BorderRadius.circular(Radii.pill),
          border: border ? Border.all(color: c.border) : null,
          boxShadow: kind == FTButtonKind.primary
              ? [
                  BoxShadow(
                    color: c.accent.withValues(alpha: 0.28),
                    blurRadius: 20,
                    spreadRadius: -4,
                    offset: const Offset(0, 8),
                  )
                ]
              : null,
        ),
        child: content,
      ),
    );
  }
}

/// Large mint circular action with an animated progress ring around it
/// (onboarding "next" control from the reference).
class FTRingButton extends StatelessWidget {
  const FTRingButton({
    super.key,
    required this.onTap,
    required this.progress,
    required this.semanticLabel,
    this.icon = Icons.arrow_forward_rounded,
    this.size = 92,
  });

  final VoidCallback? onTap;
  final double progress;
  final String semanticLabel;
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Pressable(
      onTap: onTap,
      semanticLabel: semanticLabel,
      scale: 0.93,
      child: SizedBox(
        width: size,
        height: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: progress),
          duration: context.reduceMotion ? Duration.zero : Motion.slow,
          curve: Motion.curve,
          builder: (context, p, child) => CustomPaint(
            painter: _RingPainter(p, c.accent, c.text.withValues(alpha: 0.10)),
            child: child,
          ),
          child: Center(
            child: Container(
              width: size * 0.7,
              height: size * 0.7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: c.accentGradient,
                boxShadow: [
                  BoxShadow(
                    color: c.accent.withValues(alpha: 0.35),
                    blurRadius: 26,
                    spreadRadius: -2,
                  ),
                ],
              ),
              child: Icon(icon, color: c.onAccent, size: size * 0.3),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.progress, this.color, this.track);
  final double progress;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(3);
    canvas.drawArc(
        rect,
        0,
        math.pi * 2,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = track);
    canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * progress.clamp(0, 1),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}

/// Compact text action ("See all", "Details").
class FTTextAction extends StatelessWidget {
  const FTTextAction(this.label, {super.key, required this.onTap, this.accent = false});
  final String label;
  final VoidCallback? onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
        child: Center(
          widthFactor: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              label,
              style: context.tx.label.copyWith(
                color: accent ? c.accent : c.text3,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
