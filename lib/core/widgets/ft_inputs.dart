import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/tokens.dart';
import 'app_icons.dart';
import 'ft_surfaces.dart';

/// Rounded graphite text field with floating label.
class FTTextField extends StatelessWidget {
  const FTTextField({
    super.key,
    this.controller,
    required this.label,
    this.hint,
    this.icon,
    this.maxLines = 1,
    this.minLines,
    this.keyboardType,
    this.textInputAction,
    this.validator,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.textCapitalization = TextCapitalization.sentences,
    this.obscure = false,
    this.inputFormatters,
    this.suffix,
    this.enabled = true,
    this.focusNode,
    this.initialValue,
    this.maxLength,
    this.helper,
  });

  final TextEditingController? controller;
  final String label;
  final String? hint;
  final IconData? icon;
  final int? maxLines;
  final int? minLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final TextCapitalization textCapitalization;
  final bool obscure;
  final List<TextInputFormatter>? inputFormatters;
  final Widget? suffix;
  final bool enabled;
  final FocusNode? focusNode;
  final String? initialValue;
  final int? maxLength;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final t = context.tx;
    OutlineInputBorder b(Color col, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide(color: col, width: w),
        );
    return TextFormField(
      controller: controller,
      initialValue: controller == null ? initialValue : null,
      focusNode: focusNode,
      enabled: enabled,
      autofocus: autofocus,
      obscureText: obscure,
      maxLines: obscure ? 1 : maxLines,
      minLines: minLines,
      maxLength: maxLength,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      textCapitalization: textCapitalization,
      inputFormatters: inputFormatters,
      validator: validator,
      onChanged: onChanged,
      onFieldSubmitted: onSubmitted,
      style: t.bodyStrong.copyWith(fontWeight: FontWeight.w400, fontSize: 15),
      cursorColor: c.accent,
      scrollPadding: const EdgeInsets.only(bottom: 140),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperStyle: t.caption,
        helperMaxLines: 3,
        labelStyle: t.body.copyWith(color: c.text3),
        floatingLabelStyle: t.caption.copyWith(color: c.accent, fontSize: 13),
        hintStyle: t.body.copyWith(color: c.text3.withValues(alpha: 0.7)),
        errorStyle: t.caption.copyWith(color: c.danger),
        errorMaxLines: 3,
        prefixIcon: icon == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(left: 14, right: 10),
                child: Icon(icon, size: 20, color: c.text3),
              ),
        prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        suffixIcon: suffix,
        filled: true,
        fillColor: c.isDark
            ? Colors.white.withValues(alpha: 0.035)
            : Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
        counterText: '',
        border: b(c.border),
        enabledBorder: b(c.border),
        focusedBorder: b(c.accent, 1.4),
        errorBorder: b(c.danger),
        focusedErrorBorder: b(c.danger, 1.4),
        disabledBorder: b(c.border.withValues(alpha: 0.5)),
      ),
    );
  }
}

/// Search box with leading magnifier and clear button.
class FTSearchField extends StatefulWidget {
  const FTSearchField({
    super.key,
    required this.onChanged,
    this.hint = 'Search',
    this.autofocus = false,
    this.controller,
  });

  final ValueChanged<String> onChanged;
  final String hint;
  final bool autofocus;
  final TextEditingController? controller;

  @override
  State<FTSearchField> createState() => _FTSearchFieldState();
}

class _FTSearchFieldState extends State<FTSearchField> {
  late final TextEditingController _ctl =
      widget.controller ?? TextEditingController();

  @override
  void dispose() {
    if (widget.controller == null) _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return FTPill(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      height: 52,
      child: Row(
        children: [
          const SizedBox(width: 10),
          Icon(AppIcons.search, size: 20, color: c.text3),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _ctl,
              autofocus: widget.autofocus,
              onChanged: (v) {
                setState(() {});
                widget.onChanged(v);
              },
              textInputAction: TextInputAction.search,
              style: context.tx.bodyStrong.copyWith(fontWeight: FontWeight.w400),
              cursorColor: c.accent,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: context.tx.body.copyWith(color: c.text3),
              ),
            ),
          ),
          if (_ctl.text.isNotEmpty)
            IconButton(
              tooltip: 'Clear search',
              icon: Icon(AppIcons.close, size: 18, color: c.text3),
              onPressed: () {
                _ctl.clear();
                setState(() {});
                widget.onChanged('');
              },
            ),
        ],
      ),
    );
  }
}

/// Toggle row used in settings and forms.
class FTSwitchRow extends StatelessWidget {
  const FTSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Pressable(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        haptic: false,
        scale: 0.99,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Row(
            children: [
              if (icon != null) ...[
                IconBadge(icon: icon!, size: 40),
                const SizedBox(width: Gap.md),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: context.tx.bodyStrong),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!, style: context.tx.caption),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: Gap.sm),
              Switch.adaptive(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

/// Settings / navigation row: inset icon, title, subtitle, chevron.
class FTListRow extends StatelessWidget {
  const FTListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.onTap,
    this.trailing,
    this.danger = false,
    this.leading,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool danger;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Pressable(
      onTap: onTap,
      scale: 0.985,
      semanticLabel: subtitle == null ? title : '$title, $subtitle',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Row(
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: Gap.md),
              ] else if (icon != null) ...[
                IconBadge(
                  icon: icon!,
                  size: 40,
                  color: danger ? c.danger.withValues(alpha: 0.14) : null,
                ),
                const SizedBox(width: Gap.md),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        style: context.tx.bodyStrong
                            .copyWith(color: danger ? c.danger : null)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!,
                          style: context.tx.caption,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ],
                ),
              ),
              trailing ??
                  (onTap != null
                      ? Icon(AppIcons.forward, size: 18, color: c.text3)
                      : const SizedBox.shrink()),
            ],
          ),
        ),
      ),
    );
  }
}

/// Segmented control with an animated accent thumb.
class FTSegmented<T> extends StatelessWidget {
  const FTSegmented({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final idx = values.indexOf(selected).clamp(0, values.length - 1);
    return Container(
      height: 46,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.isDark ? Colors.white.withValues(alpha: 0.04) : c.surfaceHigh,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: c.border),
      ),
      child: LayoutBuilder(builder: (context, cons) {
        final w = cons.maxWidth / values.length;
        return Stack(
          children: [
            AnimatedPositioned(
              duration: context.reduceMotion ? Duration.zero : Motion.medium,
              curve: Motion.emphasized,
              left: idx * w,
              top: 0,
              bottom: 0,
              width: w,
              child: Container(
                decoration: BoxDecoration(
                  gradient: c.accentGradient,
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
              ),
            ),
            Row(
              children: [
                for (final v in values)
                  Expanded(
                    child: Semantics(
                      selected: v == selected,
                      button: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onChanged(v);
                        },
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: AnimatedDefaultTextStyle(
                              duration: Motion.fast,
                              style: context.tx.label.copyWith(
                                color: v == selected ? c.onAccent : c.text2,
                                fontWeight: v == selected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                              child: Text(labelOf(v),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      }),
    );
  }
}

/// Rounded selectable chip (filters, time chips in the reference).
class FTChip extends StatelessWidget {
  const FTChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Semantics(
      selected: selected,
      child: Pressable(
        onTap: onTap,
        semanticLabel: label,
        child: AnimatedContainer(
          duration: Motion.fast,
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            gradient: selected ? c.accentGradient : null,
            color: selected
                ? null
                : (c.isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : c.surfaceHigh),
            borderRadius: BorderRadius.circular(Radii.pill),
            border: Border.all(color: selected ? Colors.transparent : c.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: selected ? c.onAccent : c.text2),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: context.tx.label.copyWith(
                  fontSize: 12.5,
                  color: selected ? c.onAccent : c.text2,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tappable field that looks like [FTTextField] and opens a picker.
class FTSelectField extends StatelessWidget {
  const FTSelectField({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
    this.icon,
    this.placeholder = 'Not set',
    this.onClear,
  });

  final String label;
  final String? value;
  final VoidCallback onTap;
  final IconData? icon;
  final String placeholder;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final has = value != null && value!.isNotEmpty;
    return Pressable(
      onTap: onTap,
      scale: 0.99,
      semanticLabel: '$label: ${has ? value : placeholder}',
      child: Container(
        constraints: const BoxConstraints(minHeight: 58),
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        decoration: BoxDecoration(
          color: c.isDark ? Colors.white.withValues(alpha: 0.035) : Colors.white,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: c.text3),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label,
                      style: context.tx.caption
                          .copyWith(color: has ? c.accent : c.text3)),
                  const SizedBox(height: 2),
                  Text(
                    has ? value! : placeholder,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: has
                        ? context.tx.bodyStrong
                            .copyWith(fontWeight: FontWeight.w400)
                        : context.tx.body.copyWith(color: c.text3),
                  ),
                ],
              ),
            ),
            if (has && onClear != null)
              IconButton(
                tooltip: 'Clear $label',
                onPressed: onClear,
                icon: Icon(AppIcons.close, size: 18, color: c.text3),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(AppIcons.chevronDown, size: 18, color: c.text3),
              ),
          ],
        ),
      ),
    );
  }
}

/// Simple numeric stepper for small integers (e.g. generations).
class FTStepper extends StatelessWidget {
  const FTStepper({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.label,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    Widget btn(IconData i, bool enabled, VoidCallback f, String tip) =>
        IconButton(
          tooltip: tip,
          onPressed: enabled ? f : null,
          icon: Icon(i, size: 18, color: enabled ? c.text : c.text3),
        );
    return Container(
      decoration: BoxDecoration(
        color: c.isDark ? Colors.white.withValues(alpha: 0.05) : c.surfaceHigh,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          btn(AppIcons.remove, value > min, () => onChanged(value - 1),
              'Decrease'),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 28),
            child: Text('$value',
                textAlign: TextAlign.center, style: context.tx.bodyStrong),
          ),
          btn(AppIcons.add, value < max, () => onChanged(value + 1),
              'Increase'),
        ],
      ),
    );
  }
}
