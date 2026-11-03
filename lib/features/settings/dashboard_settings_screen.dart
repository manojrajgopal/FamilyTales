import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/settings.dart';
import '../../core/widgets/widgets.dart';
import 'widgets/settings_widgets.dart';

/// Reorder and show/hide the sections of the Home dashboard.
class DashboardSettingsScreen extends ConsumerWidget {
  const DashboardSettingsScreen({super.key});

  static IconData iconOf(DashboardSection s) => switch (s) {
        DashboardSection.overview => AppIcons.stats,
        DashboardSection.quickActions => AppIcons.lightning,
        DashboardSection.recent => AppIcons.personAdd,
        DashboardSection.upcoming => AppIcons.calendar,
        DashboardSection.memories => AppIcons.photos,
      };

  static String descriptionOf(DashboardSection s) => switch (s) {
        DashboardSection.overview => 'People, generations and family facts at a glance',
        DashboardSection.quickActions => 'Shortcuts to add people, events and photos',
        DashboardSection.recent => 'The newest people and changes in your tree',
        DashboardSection.upcoming => 'Birthdays, anniversaries and remembrance days',
        DashboardSection.memories => 'Latest photos and stories',
      };

  bool _isDefault(AppPrefs p) =>
      p.dashboardHidden.isEmpty && listEquals(p.dashboardOrder, DashboardSection.values);

  Future<void> _save(BuildContext context, WidgetRef ref, AppPrefs Function(AppPrefs p) change) async {
    try {
      await ref.read(settingsProvider.notifier).update(change);
    } catch (e) {
      if (context.mounted) {
        showFTToast(context, 'Couldn’t save the layout. ${friendlyError(e)}', error: true);
      }
    }
  }

  void _reorder(BuildContext context, WidgetRef ref, List<DashboardSection> order, int from, int to) {
    if (from == to) return;
    final list = [...order];
    final item = list.removeAt(from);
    list.insert(to.clamp(0, list.length), item);
    _save(context, ref, (p) => p.copyWith(dashboardOrder: list));
  }

  void _toggle(BuildContext context, WidgetRef ref, AppPrefs prefs, DashboardSection s, bool visible) {
    final hidden = {...prefs.dashboardHidden};
    if (visible) {
      hidden.remove(s);
    } else {
      final shown = prefs.dashboardOrder.where((x) => !hidden.contains(x)).length;
      if (shown <= 1) {
        showFTToast(context, 'Keep at least one section on Home', error: true);
        return;
      }
      hidden.add(s);
    }
    _save(context, ref, (p) => p.copyWith(dashboardHidden: hidden));
  }

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    final previous = ref.read(settingsProvider);
    await _save(
      context,
      ref,
      (p) => p.copyWith(dashboardOrder: DashboardSection.values, dashboardHidden: const {}),
    );
    if (!context.mounted) return;
    final settings = ref.read(settingsProvider.notifier);
    showFTToast(
      context,
      'Home layout reset',
      actionLabel: 'Undo',
      onAction: () => settings.update((p) => p.copyWith(
            dashboardOrder: previous.dashboardOrder,
            dashboardHidden: previous.dashboardHidden,
          )),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(settingsProvider);
    final order = prefs.dashboardOrder;
    final hidden = prefs.dashboardHidden;
    final pad = context.pagePadding;
    final c = context.ft;
    final isDefault = _isDefault(prefs);

    return FTPage(
      title: 'Home layout',
      actions: [
        FTIconButton(
          icon: AppIcons.undo,
          tooltip: 'Reset to default',
          onTap: isDefault ? null : () => _reset(context, ref),
        ),
      ],
      body: ContentWidth(
        child: ReorderableListView.builder(
          padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, FTPage.bottomInset(context)),
          buildDefaultDragHandles: false,
          itemCount: order.length,
          onReorderItem: (from, to) => _reorder(context, ref, order, from, to),
          proxyDecorator: (child, index, animation) => AnimatedBuilder(
            animation: animation,
            child: child,
            builder: (context, child) {
              final t = Curves.easeOut.transform(animation.value);
              return Transform.scale(
                scale: 1 + 0.03 * t,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.lg),
                    boxShadow: [
                      BoxShadow(
                        color: c.accent.withValues(alpha: 0.22 * t),
                        blurRadius: 26,
                        spreadRadius: -6,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Material(type: MaterialType.transparency, child: child),
                ),
              );
            },
          ),
          header: FadeSlideIn(
            child: Padding(
              padding: const EdgeInsets.only(bottom: Gap.lg),
              child: InfoCard(
                icon: AppIcons.layout,
                title: 'Make Home yours',
                message: 'Drag the handles to change the order. Switch a section off to hide it '
                    '– nothing is deleted.',
                child: Text(
                  '${order.where((s) => !hidden.contains(s)).length} of ${order.length} sections shown',
                  style: context.tx.label.copyWith(color: c.accent),
                ),
              ),
            ),
          ),
          footer: isDefault
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: Gap.md),
                  child: FTButton.secondary(
                    label: 'Reset to default',
                    icon: AppIcons.undo,
                    expand: true,
                    onTap: () => _reset(context, ref),
                  ),
                ),
          itemBuilder: (context, i) {
            final s = order[i];
            final visible = !hidden.contains(s);
            return Padding(
              key: ValueKey(s),
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: FadeSlideIn(
                index: i + 1,
                child: _SectionRow(
                  section: s,
                  index: i,
                  visible: visible,
                  onToggle: (v) => _toggle(context, ref, prefs, s, v),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SectionRow extends StatelessWidget {
  const _SectionRow({
    required this.section,
    required this.index,
    required this.visible,
    required this.onToggle,
  });

  final DashboardSection section;
  final int index;
  final bool visible;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return FTCard(
      padding: const EdgeInsets.fromLTRB(Gap.xxs, Gap.sm, Gap.sm, Gap.sm),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Tooltip(
              message: 'Drag to reorder',
              child: Semantics(
                label: 'Reorder ${section.label}',
                child: const SizedBox(
                  width: 44,
                  height: 48,
                  child: Center(child: GripDots()),
                ),
              ),
            ),
          ),
          AnimatedOpacity(
            duration: Motion.fast,
            opacity: visible ? 1 : 0.5,
            child: IconBadge(
              icon: DashboardSettingsScreen.iconOf(section),
              accent: visible,
            ),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: AnimatedOpacity(
              duration: Motion.fast,
              opacity: visible ? 1 : 0.6,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(section.label,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                  const SizedBox(height: 2),
                  Text(
                    visible ? DashboardSettingsScreen.descriptionOf(section) : 'Hidden from Home',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.tx.caption.copyWith(color: visible ? null : c.text3),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: Gap.xs),
          Semantics(
            label: visible ? 'Hide ${section.label}' : 'Show ${section.label}',
            child: Switch.adaptive(value: visible, onChanged: onToggle),
          ),
        ],
      ),
    );
  }
}
