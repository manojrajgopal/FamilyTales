import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import 'app_icons.dart';
import 'ft_buttons.dart';
import 'ft_inputs.dart';
import 'ft_surfaces.dart';

/// Presents a premium bottom sheet: rounded 30px top, lit gradient, drag
/// handle, keyboard- and safe-area-aware.
Future<T?> showFTSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  String? title,
  bool scrollable = true,
  bool isDismissible = true,
  double maxHeightFactor = 0.92,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    // Above the floating tab bar, not inside the tab’s navigator.
    useRootNavigator: true,
    useSafeArea: true,
    isDismissible: isDismissible,
    enableDrag: isDismissible,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    sheetAnimationStyle: context.reduceMotion
        ? const AnimationStyle(duration: Duration.zero)
        : null,
    builder: (ctx) {
      final c = ctx.ft;
      final mq = MediaQuery.of(ctx);
      final br = const BorderRadius.vertical(top: Radius.circular(Radii.xl));
      return Padding(
        padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: (mq.size.height - mq.viewInsets.bottom) * maxHeightFactor,
            maxWidth: 720,
          ),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: c.isDark
                    ? [const Color(0xFF26272C), c.cardMid, c.bg1]
                    : [Colors.white, c.cardMid, c.cardBottom],
              ),
              borderRadius: br,
            ),
            child: CustomPaint(
              foregroundPainter:
                  EdgeBorderPainter(radius: br, gradient: c.edgeGradient),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 10),
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: c.text.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  if (title != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          Gap.xl, Gap.md, Gap.md, Gap.xs),
                      child: Row(
                        children: [
                          Expanded(
                            child: Semantics(
                              header: true,
                              child: Text(title, style: ctx.tx.title),
                            ),
                          ),
                          FTIconButton(
                            icon: AppIcons.close,
                            tooltip: 'Close',
                            size: 40,
                            onTap: () => Navigator.of(ctx).maybePop(),
                          ),
                        ],
                      ),
                    )
                  else
                    const SizedBox(height: Gap.sm),
                  Flexible(
                    child: scrollable
                        ? SingleChildScrollView(
                            padding: EdgeInsets.fromLTRB(Gap.xl, Gap.xs,
                                Gap.xl, Gap.xl + mq.padding.bottom),
                            child: builder(ctx),
                          )
                        : Padding(
                            padding: EdgeInsets.only(bottom: mq.padding.bottom),
                            child: builder(ctx),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class FTOption<T> {
  const FTOption(this.value, this.label,
      {this.icon, this.subtitle, this.danger = false, this.selected = false});
  final T value;
  final String label;
  final String? subtitle;
  final IconData? icon;
  final bool danger;
  final bool selected;
}

/// Action / choice list sheet. Returns the chosen value.
Future<T?> showFTOptions<T>(
  BuildContext context, {
  required String title,
  required List<FTOption<T>> options,
}) {
  return showFTSheet<T>(
    context,
    title: title,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final o in options)
          FTListRow(
            title: o.label,
            subtitle: o.subtitle,
            icon: o.icon,
            danger: o.danger,
            trailing: o.selected
                ? Icon(AppIcons.checkCircle, color: ctx.ft.accent, size: 22)
                : const SizedBox.shrink(),
            onTap: () => Navigator.of(ctx).pop(o.value),
          ),
      ],
    ),
  );
}

/// Confirmation dialog. Destructive actions use the danger style.
Future<bool> showFTConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool destructive = false,
  IconData? icon,
}) async {
  final result = await showFTSheet<bool>(
    context,
    builder: (ctx) {
      final c = ctx.ft;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconBadge(
            icon: icon ?? (destructive ? AppIcons.warning : AppIcons.info),
            size: 52,
            color: destructive ? c.danger.withValues(alpha: 0.16) : null,
          ),
          const SizedBox(height: Gap.md),
          Text(title, style: ctx.tx.title),
          const SizedBox(height: Gap.xs),
          Text(message, style: ctx.tx.body),
          const SizedBox(height: Gap.xl),
          Row(
            children: [
              Expanded(
                child: FTButton.secondary(
                  label: cancelLabel,
                  expand: true,
                  onTap: () => Navigator.of(ctx).pop(false),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: FTButton(
                  label: confirmLabel,
                  expand: true,
                  kind: destructive ? FTButtonKind.danger : FTButtonKind.primary,
                  onTap: () => Navigator.of(ctx).pop(true),
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// Asks for a single line of text (rename, new album…).
Future<String?> showFTTextPrompt(
  BuildContext context, {
  required String title,
  required String label,
  String? initial,
  String confirmLabel = 'Save',
  String? hint,
}) {
  final ctl = TextEditingController(text: initial);
  final formKey = GlobalKey<FormState>();
  return showFTSheet<String>(
    context,
    title: title,
    builder: (ctx) => Form(
      key: formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FTTextField(
            controller: ctl,
            label: label,
            hint: hint,
            autofocus: true,
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Please enter a value' : null,
            onSubmitted: (_) {
              if (formKey.currentState!.validate()) {
                Navigator.of(ctx).pop(ctl.text.trim());
              }
            },
          ),
          const SizedBox(height: Gap.lg),
          FTButton(
            label: confirmLabel,
            expand: true,
            onTap: () {
              if (formKey.currentState!.validate()) {
                Navigator.of(ctx).pop(ctl.text.trim());
              }
            },
          ),
        ],
      ),
    ),
  );
}

/// Floating toast with optional action (e.g. Undo).
void showFTToast(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  bool error = false,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final c = context.ft;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      duration: Duration(seconds: actionLabel != null ? 6 : 3),
      margin: EdgeInsets.fromLTRB(16, 0, 16,
          MediaQuery.paddingOf(context).bottom > 0 ? 96 : 104),
      content: Row(
        children: [
          Icon(error ? AppIcons.warning : AppIcons.checkCircle,
              size: 18, color: error ? c.danger : c.accent),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: context.tx.label)),
        ],
      ),
      action: actionLabel == null
          ? null
          : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
    ),
  );
}
