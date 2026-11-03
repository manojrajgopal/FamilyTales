import 'package:flutter/material.dart';

import '../models/enums.dart';
import 'app_icons.dart';

/// Colour and symbol used to tell genders apart at a glance (tree cards,
/// avatars, legends). A gender that was never recorded has no style, so
/// nothing is guessed from a name.
@immutable
class GenderStyle {
  const GenderStyle._(this.gender, this.color, this.onColor, this.icon);

  final Gender gender;

  /// Badge / border colour, tuned for the current theme.
  final Color color;

  /// Symbol colour drawn on top of [color].
  final Color onColor;
  final IconData icon;

  String get label => gender.label;

  /// Genders that have a style, in legend order.
  static const shown = [Gender.male, Gender.female, Gender.nonBinary, Gender.other];

  static GenderStyle? of(Gender gender, {required bool dark}) {
    const ink = Color(0xFF111216);
    return switch (gender) {
      Gender.male => GenderStyle._(
          gender, dark ? const Color(0xFF6AA8FF) : const Color(0xFF1D4ED8), dark ? ink : Colors.white, AppIcons.male),
      Gender.female => GenderStyle._(
          gender, dark ? const Color(0xFFFF7EB3) : const Color(0xFFDB2777), dark ? ink : Colors.white, AppIcons.female),
      Gender.nonBinary => GenderStyle._(
          gender, dark ? const Color(0xFFB99CFF) : const Color(0xFF6D45CF), dark ? ink : Colors.white, AppIcons.neutral),
      Gender.other => GenderStyle._(
          gender, dark ? const Color(0xFFF5B85C) : const Color(0xFF9A5B00), dark ? ink : Colors.white, AppIcons.neutral),
      Gender.unknown => null,
    };
  }
}

/// Small filled circle with the gender symbol.
class GenderBadge extends StatelessWidget {
  const GenderBadge({super.key, required this.style, this.size = 18, this.borderColor});

  final GenderStyle style;
  final double size;

  /// Ring that separates the badge from what it overlaps.
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: style.label,
      excludeSemantics: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: style.color,
          border: borderColor == null ? null : Border.all(color: borderColor!, width: 2),
        ),
        alignment: Alignment.center,
        child: Icon(style.icon, size: size * (borderColor == null ? 0.66 : 0.55), color: style.onColor),
      ),
    );
  }
}
