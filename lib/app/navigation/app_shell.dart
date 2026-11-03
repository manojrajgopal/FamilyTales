import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/widgets.dart';

/// Root shell with the floating premium bottom navigation. Each tab keeps
/// its own navigation/scroll state (StatefulShellRoute.indexedStack).
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  static const items = [
    _NavItem('Home', AppIcons.home, AppIcons.homeActive),
    _NavItem('Tree', AppIcons.tree, AppIcons.treeActive),
    _NavItem('Members', AppIcons.members, AppIcons.membersActive),
    _NavItem('Timeline', AppIcons.timeline, AppIcons.timelineActive),
    _NavItem('More', AppIcons.more, AppIcons.moreActive),
  ];

  /// Height reserved at the bottom of tab screens for the floating bar
  /// (excluding the system inset).
  static const navHeight = 68.0;

  /// Distance from the bottom of a tab screen to just above the floating
  /// nav. The shell uses `extendBody`, so the body's bottom padding already
  /// covers the bar (and the system inset).
  static double navClearance(BuildContext context) => MediaQuery.paddingOf(context).bottom + 10;

  /// Bottom padding tab content should use so it can scroll above the nav.
  static double contentInset(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom + navHeight + 28;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    if (wide) {
      // Tablets / landscape: side rail keeps the canvas wide.
      return Scaffold(
        backgroundColor: context.ft.bg0,
        body: Row(
          children: [
            _SideRail(shell: shell),
            Expanded(child: shell),
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: context.ft.bg0,
      extendBody: true,
      body: shell,
      bottomNavigationBar: FTBottomNav(
        index: shell.currentIndex,
        onSelect: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
      ),
    );
  }
}

class _NavItem {
  const _NavItem(this.label, this.icon, this.activeIcon);
  final String label;
  final IconData icon;
  final IconData activeIcon;
}

/// Floating pill navigation bar. The active tab expands into a mint pill
/// with its label; inactive tabs show icons only.
class FTBottomNav extends StatelessWidget {
  const FTBottomNav({super.key, required this.index, required this.onSelect});
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final br = BorderRadius.circular(Radii.pill);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottom > 0 ? bottom : 14),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ClipRRect(
            borderRadius: br,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                height: AppShell.navHeight,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: br,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: c.isDark
                        ? [
                            const Color(0xFF2A2B30).withValues(alpha: 0.92),
                            const Color(0xFF141518).withValues(alpha: 0.94),
                          ]
                        : [
                            Colors.white.withValues(alpha: 0.94),
                            const Color(0xFFF0F1F3).withValues(alpha: 0.94),
                          ],
                  ),
                  boxShadow: c.cardShadow,
                ),
                foregroundDecoration: BoxDecoration(
                  borderRadius: br,
                  border: Border.all(color: c.borderStrong.withValues(alpha: 0.14)),
                ),
                child: LayoutBuilder(builder: (context, cons) {
                  final n = AppShell.items.length;
                  final activeW = (cons.maxWidth * 0.34).clamp(96.0, 150.0);
                  final otherW = (cons.maxWidth - activeW) / (n - 1);
                  return Row(
                    children: [
                      for (var i = 0; i < n; i++)
                        _NavButton(
                          item: AppShell.items[i],
                          active: i == index,
                          width: i == index ? activeW : otherW,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            onSelect(i);
                          },
                        ),
                    ],
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.active,
    required this.width,
    required this.onTap,
  });

  final _NavItem item;
  final bool active;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final dur = context.reduceMotion ? Duration.zero : Motion.medium;
    return Semantics(
      selected: active,
      button: true,
      label: item.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: dur,
          curve: Motion.emphasized,
          width: width,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: active ? c.accentGradient : null,
            borderRadius: BorderRadius.circular(Radii.pill),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: c.accent.withValues(alpha: 0.30),
                      blurRadius: 16,
                      spreadRadius: -4,
                    )
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedSwitcher(
                duration: dur,
                child: Icon(
                  active ? item.activeIcon : item.icon,
                  key: ValueKey(active),
                  size: 22,
                  color: active ? c.onAccent : c.text2,
                ),
              ),
              if (active)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 7),
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: context.tx.label.copyWith(
                        color: c.onAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Navigation rail for wide layouts (tablets, landscape).
class _SideRail extends StatelessWidget {
  const _SideRail({required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final pad = MediaQuery.paddingOf(context);
    return Container(
      width: 96 + pad.left,
      padding: EdgeInsets.only(left: pad.left, top: pad.top + 16, bottom: pad.bottom + 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [c.surface, c.bg0],
        ),
        border: Border(right: BorderSide(color: c.border)),
      ),
      child: Column(
        children: [
          Image.asset('assets/branding/emblem.png', width: 52, height: 52),
          const SizedBox(height: 24),
          for (var i = 0; i < AppShell.items.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: [
                  FTIconButton(
                    icon: i == shell.currentIndex
                        ? AppShell.items[i].activeIcon
                        : AppShell.items[i].icon,
                    tooltip: AppShell.items[i].label,
                    selected: i == shell.currentIndex,
                    size: 52,
                    onTap: () => shell.goBranch(i, initialLocation: i == shell.currentIndex),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    AppShell.items[i].label,
                    style: context.tx.micro.copyWith(
                      color: i == shell.currentIndex ? c.accent : c.text3,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
