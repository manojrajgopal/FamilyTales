import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/tokens.dart';

/// Full-bleed premium background: deep graphite with a soft top-left light
/// source, a faint accent bloom and a subtle diagonal sheen. It is drawn
/// behind transparent system bars (edge-to-edge) – content above it must
/// respect safe areas.
class FTBackground extends StatelessWidget {
  const FTBackground({super.key, this.child, this.intensity = 1});
  final Widget? child;
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _BackgroundPainter(c, intensity),
        child: child ?? const SizedBox.expand(),
      ),
    );
  }
}

class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter(this.c, this.intensity);
  final FTColors c;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = c.bg0);
    final r = size.longestSide;

    // Key light (top-left), like the reference phone screens.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.55, -1.05),
          radius: 1.05,
          colors: [
            c.glow.withValues(alpha: (c.isDark ? 0.95 : 1) * intensity),
            c.glow.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(
            center: Offset(size.width * 0.22, -size.height * 0.02), radius: r)),
    );

    // Accent bloom (bottom-right), barely there.
    canvas.drawCircle(
      Offset(size.width * 1.05, size.height * 0.92),
      r * 0.55,
      Paint()
        ..shader = RadialGradient(colors: [
          c.accent.withValues(alpha: (c.isDark ? 0.07 : 0.06) * intensity),
          c.accent.withValues(alpha: 0),
        ]).createShader(Rect.fromCircle(
            center: Offset(size.width * 1.05, size.height * 0.92),
            radius: r * 0.55)),
    );

    // Diagonal sheen band.
    final sheen = Path()
      ..moveTo(size.width * 0.55, 0)
      ..lineTo(size.width * 0.78, 0)
      ..lineTo(size.width * 0.18, size.height)
      ..lineTo(-size.width * 0.05, size.height)
      ..close();
    canvas.drawPath(
      sheen,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            (c.isDark ? Colors.white : Colors.black)
                .withValues(alpha: 0.018 * intensity),
            Colors.transparent,
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_BackgroundPainter old) =>
      old.c != c || old.intensity != intensity;
}

/// Paints a 1px border whose brightness follows the light source (bright on
/// the top-left edge, fading toward the bottom-right).
class EdgeBorderPainter extends CustomPainter {
  EdgeBorderPainter({
    required this.radius,
    required this.gradient,
    this.width = 1,
    this.color,
  });

  final BorderRadius radius;
  final Gradient gradient;
  final double width;
  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(width / 2);
    final rrect = radius.toRRect(rect);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    if (color != null) {
      p.color = color!;
    } else {
      p.shader = gradient.createShader(rect);
    }
    canvas.drawRRect(rrect, p);
  }

  @override
  bool shouldRepaint(EdgeBorderPainter old) =>
      old.gradient != gradient ||
      old.color != color ||
      old.radius != radius ||
      old.width != width;
}

/// Adds a press-scale animation, haptic tick and button semantics.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.965,
    this.semanticLabel,
    this.haptic = true,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final String? semanticLabel;
  final bool haptic;
  final bool enabled;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final active =
        widget.enabled && (widget.onTap != null || widget.onLongPress != null);
    final reduce = context.reduceMotion;
    return Semantics(
      button: widget.onTap != null,
      enabled: active,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: active ? (_) => _set(true) : null,
        onTapUp: active ? (_) => _set(false) : null,
        onTapCancel: active ? () => _set(false) : null,
        onTap: active && widget.onTap != null
            ? () {
                if (widget.haptic) HapticFeedback.selectionClick();
                widget.onTap!();
              }
            : null,
        onLongPress: active && widget.onLongPress != null
            ? () {
                HapticFeedback.mediumImpact();
                widget.onLongPress!();
              }
            : null,
        child: AnimatedScale(
          scale: _down && !reduce ? widget.scale : 1,
          duration: Motion.fast,
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: widget.enabled ? 1 : 0.45,
            duration: Motion.fast,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// The signature card: top-left lit gradient, lit 1px edge, deep soft shadow
/// and large radius.
class FTCard extends StatelessWidget {
  const FTCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Gap.lg),
    this.radius = Radii.lg,
    this.onTap,
    this.onLongPress,
    this.gradient,
    this.color,
    this.shadow = true,
    this.highlighted = false,
    this.semanticLabel,
    this.width,
    this.height,
    this.clip = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Gradient? gradient;
  final Color? color;
  final bool shadow;

  /// Accent outline + glow, used for selection.
  final bool highlighted;
  final String? semanticLabel;
  final double? width;
  final double? height;
  final bool clip;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final br = BorderRadius.circular(radius);
    Widget card = AnimatedContainer(
      duration: Motion.medium,
      curve: Motion.curve,
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: color == null ? (gradient ?? c.cardGradient) : null,
        color: color,
        borderRadius: br,
        boxShadow: [
          if (shadow) ...c.cardShadow,
          if (highlighted)
            BoxShadow(
              color: c.accent.withValues(alpha: 0.28),
              blurRadius: 22,
              spreadRadius: -4,
            ),
        ],
      ),
      foregroundDecoration: highlighted
          ? BoxDecoration(
              borderRadius: br,
              border: Border.all(color: c.accent, width: 1.4),
            )
          : null,
      child: CustomPaint(
        foregroundPainter: highlighted
            ? null
            : EdgeBorderPainter(radius: br, gradient: c.edgeGradient),
        child: clip
            ? ClipRRect(
                borderRadius: br,
                child: Padding(padding: padding, child: child),
              )
            : Padding(padding: padding, child: child),
      ),
    );
    if (onTap != null || onLongPress != null) {
      card = Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        semanticLabel: semanticLabel,
        child: card,
      );
    } else if (semanticLabel != null) {
      card = Semantics(label: semanticLabel, child: card);
    }
    return card;
  }
}

/// Rounded "pill" surface (header greeting, person rows, chips).
class FTPill extends StatelessWidget {
  const FTPill({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(6, 6, 18, 6),
    this.onTap,
    this.color,
    this.semanticLabel,
    this.height,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final String? semanticLabel;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final br = BorderRadius.circular(Radii.pill);
    Widget pill = Container(
      height: height,
      decoration: BoxDecoration(
        gradient: color == null ? c.cardGradient : null,
        color: color,
        borderRadius: br,
        boxShadow: c.softShadow,
      ),
      child: CustomPaint(
        foregroundPainter:
            EdgeBorderPainter(radius: br, gradient: c.edgeGradient),
        child: Padding(padding: padding, child: child),
      ),
    );
    if (onTap != null) {
      pill = Pressable(onTap: onTap, semanticLabel: semanticLabel, child: pill);
    }
    return pill;
  }
}

/// Small circular "inset" icon container used at the top-left of cards
/// (matches the announcement cards in the reference).
class IconBadge extends StatelessWidget {
  const IconBadge({
    super.key,
    required this.icon,
    this.size = 40,
    this.iconSize,
    this.accent = false,
    this.color,
  });

  final IconData icon;
  final double size;
  final double? iconSize;
  final bool accent;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final br = BorderRadius.circular(size);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: accent ? c.accentGradient : (color == null ? c.chipGradient : null),
        color: color,
        boxShadow: [
          BoxShadow(
            color: c.shadow.withValues(alpha: c.isDark ? 0.5 : 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      foregroundDecoration: accent
          ? null
          : BoxDecoration(
              borderRadius: br,
              border: Border.all(color: c.border),
            ),
      child: Icon(
        icon,
        size: iconSize ?? size * 0.48,
        color: accent ? c.onAccent : c.text,
      ),
    );
  }
}
