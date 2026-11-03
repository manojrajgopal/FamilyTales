import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Accent colour choices offered in Appearance settings. Mint is the
/// signature colour taken from the design reference.
enum AccentChoice {
  mint('Mint', Color(0xFF86D8CA), Color(0xFF6BC9B9), Color(0xFFA4E7DC),
      Color(0xFF2F9C89)),
  sky('Sky', Color(0xFF8EC5F0), Color(0xFF6FB0E6), Color(0xFFB4D9F6),
      Color(0xFF2C7FBF)),
  lavender('Lavender', Color(0xFFB9A8F2), Color(0xFFA08DEA), Color(0xFFD3C8F8),
      Color(0xFF6A55C8)),
  amber('Amber', Color(0xFFEBC27E), Color(0xFFE0AE5E), Color(0xFFF4D7A6),
      Color(0xFFB07A1C)),
  rose('Rose', Color(0xFFEFA3B6), Color(0xFFE58AA1), Color(0xFFF6C4D1),
      Color(0xFFBB4767));

  const AccentChoice(this.label, this.primary, this.secondary, this.highlight,
      this.onLight);
  final String label;
  final Color primary;
  final Color secondary;
  final Color highlight;

  /// Deeper variant with enough contrast on light backgrounds.
  final Color onLight;
}

/// Spacing scale (logical pixels).
abstract final class Gap {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double huge = 48;
}

/// Corner radii calibrated against the reference design.
abstract final class Radii {
  static const double sm = 12;
  static const double md = 18;
  static const double lg = 24;
  static const double xl = 30;
  static const double pill = 999;
}

abstract final class Motion {
  static const fast = Duration(milliseconds: 160);
  static const medium = Duration(milliseconds: 280);
  static const slow = Duration(milliseconds: 420);
  static const curve = Curves.easeOutCubic;
  static const emphasized = Cubic(0.2, 0.0, 0, 1.0);
}

/// The full colour system. Exposed as a [ThemeExtension] so every widget can
/// read it with `context.ft`.
@immutable
class FTColors extends ThemeExtension<FTColors> {
  const FTColors({
    required this.isDark,
    required this.bg0,
    required this.bg1,
    required this.surface,
    required this.surfaceHigh,
    required this.surfaceHigher,
    required this.cardTop,
    required this.cardMid,
    required this.cardBottom,
    required this.text,
    required this.text2,
    required this.text3,
    required this.border,
    required this.borderStrong,
    required this.accent,
    required this.accent2,
    required this.accentHi,
    required this.onAccent,
    required this.danger,
    required this.warning,
    required this.success,
    required this.shadow,
    required this.glow,
  });

  final bool isDark;
  final Color bg0;
  final Color bg1;
  final Color surface;
  final Color surfaceHigh;
  final Color surfaceHigher;
  final Color cardTop;
  final Color cardMid;
  final Color cardBottom;
  final Color text;
  final Color text2;
  final Color text3;
  final Color border;
  final Color borderStrong;
  final Color accent;
  final Color accent2;
  final Color accentHi;
  final Color onAccent;
  final Color danger;
  final Color warning;
  final Color success;
  final Color shadow;
  final Color glow;

  static FTColors dark(AccentChoice a) => FTColors(
        isDark: true,
        bg0: const Color(0xFF0B0C0F),
        bg1: const Color(0xFF131417),
        surface: const Color(0xFF17181C),
        surfaceHigh: const Color(0xFF24252A),
        surfaceHigher: const Color(0xFF303136),
        cardTop: const Color(0xFF2C2D32),
        cardMid: const Color(0xFF1B1C20),
        cardBottom: const Color(0xFF111215),
        text: Colors.white,
        text2: const Color(0xFFB7B9BE),
        text3: const Color(0xFF81848B),
        border: const Color(0x1FFFFFFF),
        borderStrong: const Color(0x2EFFFFFF),
        accent: a.primary,
        accent2: a.secondary,
        accentHi: a.highlight,
        onAccent: const Color(0xFF0B0C0F),
        danger: const Color(0xFFEE8E82),
        warning: const Color(0xFFE9C47E),
        success: a.primary,
        shadow: const Color(0xCC000000),
        glow: const Color(0xFF2A2B30),
      );

  static FTColors light(AccentChoice a) => FTColors(
        isDark: false,
        bg0: const Color(0xFFEEEFF1),
        bg1: const Color(0xFFF6F7F8),
        surface: const Color(0xFFFFFFFF),
        surfaceHigh: const Color(0xFFF1F2F4),
        surfaceHigher: const Color(0xFFE4E6E9),
        cardTop: const Color(0xFFFFFFFF),
        cardMid: const Color(0xFFF8F9FA),
        cardBottom: const Color(0xFFEDEEF0),
        text: const Color(0xFF111215),
        text2: const Color(0xFF4A4D55),
        text3: const Color(0xFF7A7E87),
        border: const Color(0x14000000),
        borderStrong: const Color(0x24000000),
        // Text and icons use the deep variant; filled accent surfaces use the
        // light tones with dark text so labels stay readable.
        accent: a.onLight,
        accent2: a.primary,
        accentHi: a.highlight,
        onAccent: const Color(0xFF0B0C0F),
        danger: const Color(0xFFC4473A),
        warning: const Color(0xFFB07A1C),
        success: a.onLight,
        shadow: const Color(0x22000000),
        glow: const Color(0xFFFFFFFF),
      );

  /// Signature card gradient: lit from the top-left like the reference.
  LinearGradient get cardGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [cardTop, cardMid, cardBottom],
        stops: const [0, 0.55, 1],
      );

  /// Raised graphite used for circular icon buttons and chips.
  LinearGradient get chipGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? const [Color(0xFF3A3B41), Color(0xFF1C1D21)]
            : const [Color(0xFFFFFFFF), Color(0xFFE9EAED)],
      );

  LinearGradient get accentGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [accentHi, accent, accent2]
            : [accentHi, accent2, Color.lerp(accent2, accent, 0.3)!],
      );

  /// Gradient used for 1px "lit edge" borders.
  LinearGradient get edgeGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? const [Color(0x40FFFFFF), Color(0x14FFFFFF), Color(0x08FFFFFF)]
            : const [Color(0x10000000), Color(0x0C000000), Color(0x18000000)],
        stops: const [0, 0.45, 1],
      );

  List<BoxShadow> get cardShadow => [
        BoxShadow(
          color: shadow,
          blurRadius: isDark ? 28 : 22,
          spreadRadius: isDark ? -6 : -8,
          offset: const Offset(0, 14),
        ),
      ];

  List<BoxShadow> get softShadow => [
        BoxShadow(
          color: shadow.withValues(alpha: isDark ? 0.45 : 0.10),
          blurRadius: 16,
          offset: const Offset(0, 6),
        ),
      ];

  @override
  FTColors copyWith() => this;

  @override
  FTColors lerp(covariant FTColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return FTColors(
      isDark: t < 0.5 ? isDark : other.isDark,
      bg0: l(bg0, other.bg0),
      bg1: l(bg1, other.bg1),
      surface: l(surface, other.surface),
      surfaceHigh: l(surfaceHigh, other.surfaceHigh),
      surfaceHigher: l(surfaceHigher, other.surfaceHigher),
      cardTop: l(cardTop, other.cardTop),
      cardMid: l(cardMid, other.cardMid),
      cardBottom: l(cardBottom, other.cardBottom),
      text: l(text, other.text),
      text2: l(text2, other.text2),
      text3: l(text3, other.text3),
      border: l(border, other.border),
      borderStrong: l(borderStrong, other.borderStrong),
      accent: l(accent, other.accent),
      accent2: l(accent2, other.accent2),
      accentHi: l(accentHi, other.accentHi),
      onAccent: l(onAccent, other.onAccent),
      danger: l(danger, other.danger),
      warning: l(warning, other.warning),
      success: l(success, other.success),
      shadow: l(shadow, other.shadow),
      glow: l(glow, other.glow),
    );
  }
}

/// Typography (Inter, bundled). Medium weights and tight tracking for large
/// headings mirror the reference.
@immutable
class FTText extends ThemeExtension<FTText> {
  const FTText({
    required this.display,
    required this.headline,
    required this.title,
    required this.section,
    required this.body,
    required this.bodyStrong,
    required this.label,
    required this.caption,
    required this.micro,
  });

  final TextStyle display;
  final TextStyle headline;
  final TextStyle title;
  final TextStyle section;
  final TextStyle body;
  final TextStyle bodyStrong;
  final TextStyle label;
  final TextStyle caption;
  final TextStyle micro;

  factory FTText.of(FTColors c) {
    const f = 'Inter';
    return FTText(
      display: TextStyle(
          fontFamily: f,
          fontSize: 31,
          height: 1.18,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.9,
          color: c.text),
      headline: TextStyle(
          fontFamily: f,
          fontSize: 25,
          height: 1.24,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.6,
          color: c.text),
      title: TextStyle(
          fontFamily: f,
          fontSize: 19,
          height: 1.25,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.3,
          color: c.text),
      section: TextStyle(
          fontFamily: f,
          fontSize: 16,
          height: 1.3,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: c.text),
      body: TextStyle(
          fontFamily: f,
          fontSize: 14,
          height: 1.5,
          fontWeight: FontWeight.w400,
          color: c.text2),
      bodyStrong: TextStyle(
          fontFamily: f,
          fontSize: 14.5,
          height: 1.4,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.1,
          color: c.text),
      label: TextStyle(
          fontFamily: f,
          fontSize: 13,
          height: 1.3,
          fontWeight: FontWeight.w500,
          color: c.text),
      caption: TextStyle(
          fontFamily: f,
          fontSize: 12,
          height: 1.35,
          fontWeight: FontWeight.w400,
          color: c.text3),
      micro: TextStyle(
          fontFamily: f,
          fontSize: 10.5,
          height: 1.2,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.3,
          color: c.text3),
    );
  }

  @override
  FTText copyWith() => this;

  @override
  FTText lerp(covariant FTText? other, double t) {
    if (other == null) return this;
    TextStyle l(TextStyle a, TextStyle b) => TextStyle.lerp(a, b, t)!;
    return FTText(
      display: l(display, other.display),
      headline: l(headline, other.headline),
      title: l(title, other.title),
      section: l(section, other.section),
      body: l(body, other.body),
      bodyStrong: l(bodyStrong, other.bodyStrong),
      label: l(label, other.label),
      caption: l(caption, other.caption),
      micro: l(micro, other.micro),
    );
  }
}

extension FTThemeX on BuildContext {
  FTColors get ft => Theme.of(this).extension<FTColors>()!;
  FTText get tx => Theme.of(this).extension<FTText>()!;

  /// True when the OS asks for reduced motion or the user disabled
  /// animations in Appearance settings.
  bool get reduceMotion => MediaQuery.of(this).disableAnimations;

  /// Width-based layout class.
  double get screenWidth => MediaQuery.sizeOf(this).width;
  bool get isTablet => MediaQuery.sizeOf(this).shortestSide >= 600;

  /// Horizontal page padding that scales with the screen.
  double get pagePadding {
    final w = MediaQuery.sizeOf(this).width;
    if (w >= 1000) return 40;
    if (w >= 700) return 32;
    if (w < 350) return 16;
    return 20;
  }

  /// Max content width for readable layouts on tablets.
  double get maxContentWidth => isTablet ? 760 : double.infinity;
}

double lerpD(double a, double b, double t) => lerpDouble(a, b, t)!;
