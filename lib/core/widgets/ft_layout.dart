import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/tokens.dart';
import 'app_icons.dart';
import 'ft_buttons.dart';
import 'ft_surfaces.dart';

/// Standard page: edge-to-edge background, safe-area aware header and body.
///
/// The background is drawn behind the status/navigation bars; the header and
/// body are inset by the safe area so nothing sits under notches, punch holes
/// or the Dynamic Island. Bottom insets are left to the body (lists add
/// [FTPage.bottomInset] padding) so content can scroll behind the gesture
/// bar while remaining reachable.
class FTPage extends StatelessWidget {
  const FTPage({
    super.key,
    this.title,
    this.titleWidget,
    required this.body,
    this.showBack = true,
    this.actions = const [],
    this.leading,
    this.floating,
    this.bottomBar,
    this.onBack,
    this.resizeToAvoidBottomInset = true,
    this.headerBottom,
  });

  final String? title;
  final Widget? titleWidget;
  final Widget body;
  final bool showBack;
  final List<Widget> actions;
  final Widget? leading;
  final Widget? floating;
  final Widget? bottomBar;
  final VoidCallback? onBack;
  final bool resizeToAvoidBottomInset;
  final Widget? headerBottom;

  /// Bottom padding a scrollable body should add so its last item clears the
  /// system gesture area (and the floating nav bar when inside the shell).
  static double bottomInset(BuildContext context, {double extra = 24}) =>
      MediaQuery.paddingOf(context).bottom + extra;

  @override
  Widget build(BuildContext context) {
    final dark = context.ft.isDark;
    final hasHeader = title != null || titleWidget != null || showBack ||
        actions.isNotEmpty || leading != null;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.overlayStyle(dark),
      child: Scaffold(
        backgroundColor: context.ft.bg0,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        extendBody: true,
        floatingActionButton: floating,
        bottomNavigationBar: bottomBar,
        body: Stack(
          children: [
            const Positioned.fill(child: FTBackground()),
            SafeArea(
              bottom: false,
              child: Column(
                children: [
                  if (hasHeader)
                    FTHeader(
                      title: title,
                      titleWidget: titleWidget,
                      showBack: showBack,
                      actions: actions,
                      leading: leading,
                      onBack: onBack,
                    ),
                  ?headerBottom,
                  Expanded(child: body),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Header with circular back button, centred title and trailing actions –
/// mirrors the "Absence" screen of the reference.
class FTHeader extends StatelessWidget {
  const FTHeader({
    super.key,
    this.title,
    this.titleWidget,
    this.showBack = true,
    this.actions = const [],
    this.leading,
    this.onBack,
  });

  final String? title;
  final Widget? titleWidget;
  final bool showBack;
  final List<Widget> actions;
  final Widget? leading;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final pad = context.pagePadding;
    final router = GoRouter.maybeOf(context);
    final canPop = router?.canPop() ?? Navigator.of(context).canPop();
    Widget? lead = leading;
    if (lead == null && showBack) {
      lead = FTIconButton(
        icon: AppIcons.back,
        tooltip: 'Back',
        onTap: onBack ??
            () {
              if (router == null) {
                Navigator.of(context).maybePop();
              } else if (canPop) {
                router.pop();
              } else {
                router.go('/home');
              }
            },
      );
    }
    final sideWidth = 48.0 * (actions.length > 1 ? actions.length : 1);
    return Padding(
      padding: EdgeInsets.fromLTRB(pad - 4, Gap.xs, pad - 4, Gap.xs),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            SizedBox(
              width: sideWidth,
              child: Align(alignment: Alignment.centerLeft, child: lead),
            ),
            Expanded(
              child: Center(
                child: titleWidget ??
                    (title == null
                        ? const SizedBox.shrink()
                        : Semantics(
                            header: true,
                            child: Text(
                              title!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.tx.title,
                            ),
                          )),
              ),
            ),
            SizedBox(
              width: sideWidth,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: actions,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "My Tasks ........ See all" style section header.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction, this.trailing});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xs),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title,
                  style: context.tx.section,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ),
          ?trailing,
          if (action != null) FTTextAction(action!, onTap: onAction),
        ],
      ),
    );
  }
}

/// Constrains content width on tablets and centres it.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth});
  final Widget child;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final mw = maxWidth ?? context.maxContentWidth;
    if (mw == double.infinity) return child;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: mw),
        child: child,
      ),
    );
  }
}

/// Staggered fade + rise entrance. Disabled with reduced motion.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.index = 0,
    this.offset = 18,
  });

  final Widget child;
  final int index;
  final double offset;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: Motion.slow);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (context.reduceMotion) {
      _c.value = 1;
    } else {
      final delay = Duration(milliseconds: (widget.index * 45).clamp(0, 360));
      Future.delayed(delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final v = Motion.curve.transform(_c.value);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, (1 - v) * widget.offset),
            child: child,
          ),
        );
      },
    );
  }
}

/// Friendly empty state with an inset icon and optional action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: Gap.xxl, vertical: compact ? Gap.lg : Gap.huge),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: compact ? 64 : 84,
              height: compact ? 64 : 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: c.chipGradient,
                boxShadow: c.cardShadow,
              ),
              foregroundDecoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: c.border),
              ),
              child: Icon(icon, size: compact ? 26 : 34, color: c.accent),
            ),
            const SizedBox(height: Gap.lg),
            Text(title,
                textAlign: TextAlign.center, style: context.tx.section),
            if (message != null) ...[
              const SizedBox(height: Gap.xs),
              Text(message!,
                  textAlign: TextAlign.center, style: context.tx.body),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: Gap.xl),
              FTButton(label: actionLabel!, onTap: onAction, icon: AppIcons.add),
            ],
          ],
        ),
      ),
    );
  }
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
              strokeWidth: 2.5, color: context.ft.accent),
        ),
      );
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
        icon: AppIcons.warning,
        title: 'Something went wrong',
        message: friendlyError(error),
        actionLabel: onRetry == null ? null : 'Try again',
        onAction: onRetry,
      );
}

/// Converts exceptions into short user-facing messages.
String friendlyError(Object e) {
  final s = e.toString();
  if (s.contains('FOREIGN KEY')) {
    return 'This change conflicts with related records.';
  }
  if (s.contains('UNIQUE')) return 'That record already exists.';
  if (s.startsWith('Exception: ')) return s.substring(11);
  if (s.contains('StateError')) return s.replaceFirst('Bad state: ', '');
  return s.length > 160 ? '${s.substring(0, 160)}…' : s;
}

/// Small rounded tag (e.g. "Deceased", "Adopted", counts).
class FTTag extends StatelessWidget {
  const FTTag(this.label, {super.key, this.icon, this.accent = false, this.color});
  final String label;
  final IconData? icon;
  final bool accent;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final fg = color ?? (accent ? c.accent : c.text2);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: (color ?? (accent ? c.accent : c.text))
            .withValues(alpha: accent || color != null ? 0.12 : 0.06),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(
            color: (color ?? (accent ? c.accent : c.text))
                .withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.tx.micro.copyWith(color: fg, fontSize: 11)),
          ),
        ],
      ),
    );
  }
}

/// Thin divider line used inside cards.
class HairLine extends StatelessWidget {
  const HairLine({super.key, this.vertical = Gap.sm});
  final double vertical;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(vertical: vertical),
        child: Container(height: 1, color: context.ft.border),
      );
}
