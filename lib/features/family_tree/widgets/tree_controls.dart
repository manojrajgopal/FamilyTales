import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../core/database/app_database.dart';
import '../../../core/widgets/widgets.dart';
import '../../family/domain/family_graph.dart';
import '../../members/widgets/person_widgets.dart';
import '../layout/tree_layout.dart';

/// "My Family Tree ˅" pill: shows the tree name and current layout; opens
/// the tree switcher.
class TreeSwitcherPill extends ConsumerWidget {
  const TreeSwitcherPill({super.key, required this.name, required this.modeLabel});
  final String name;
  final String modeLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ft;
    return FTPill(
      padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
      semanticLabel: 'Switch family tree, current: $name',
      onTap: () => _showSwitcher(context, ref),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const IconBadge(icon: AppIcons.tree, size: 38, accent: true),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(modeLabel, style: context.tx.micro),
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Icon(AppIcons.chevronDown, size: 16, color: c.text3),
        ],
      ),
    );
  }

  Future<void> _showSwitcher(BuildContext context, WidgetRef ref) async {
    final trees = ref.read(treesProvider).value ?? const <FamilyTree>[];
    final active = ref.read(activeTreeIdProvider);
    final r = await showFTOptions<String>(
      context,
      title: 'Family trees',
      options: [
        for (final t in trees)
          FTOption(t.id, t.name,
              icon: AppIcons.tree, subtitle: t.description, selected: t.id == active),
        const FTOption('__manage', 'Manage trees', icon: AppIcons.settings, subtitle: 'Create, rename, merge'),
      ],
    );
    if (r == null) return;
    if (r == '__manage') {
      if (context.mounted) context.push(Routes.trees);
      return;
    }
    await ref.read(settingsProvider.notifier).setActiveTree(r);
  }
}

/// Floating vertical toolbar (zoom, fit, reset, generations).
class TreeToolbar extends StatelessWidget {
  const TreeToolbar({
    super.key,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
    required this.onReset,
    required this.onGenerations,
    required this.generations,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;
  final VoidCallback onReset;
  final VoidCallback onGenerations;
  final int generations;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final br = BorderRadius.circular(Radii.pill);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        borderRadius: br,
        gradient: c.cardGradient,
        boxShadow: c.cardShadow,
      ),
      foregroundDecoration: BoxDecoration(borderRadius: br, border: Border.all(color: c.border)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToolButton(icon: AppIcons.zoomIn, tooltip: 'Zoom in', onTap: onZoomIn),
          _ToolButton(icon: AppIcons.zoomOut, tooltip: 'Zoom out', onTap: onZoomOut),
          _divider(c),
          _ToolButton(icon: AppIcons.fit, tooltip: 'Fit whole tree to screen', onTap: onFit),
          _ToolButton(icon: AppIcons.center, tooltip: 'Reset position', onTap: onReset),
          _divider(c),
          Tooltip(
            message: 'Generations shown',
            child: Pressable(
              onTap: onGenerations,
              semanticLabel: 'Filter generations, $generations shown',
              child: SizedBox(
                width: 48,
                height: 48,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(AppIcons.generations, size: 18, color: c.text),
                    Text('$generations',
                        textScaler: TextScaler.noScaling,
                        style: context.tx.micro.copyWith(color: c.accent, fontSize: 10)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(FTColors c) => Container(width: 22, height: 1, color: c.border);
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Pressable(
          onTap: onTap,
          semanticLabel: tooltip,
          scale: 0.88,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(icon, size: 20, color: context.ft.text),
          ),
        ),
      );
}

/// Tree layout selector (Focus / Descendants / Ancestors / Full / Compact)
/// and a connector legend.
Future<void> showTreeLayoutSheet(
  BuildContext context, {
  required TreeViewMode mode,
  required ValueChanged<TreeViewMode> onMode,
}) {
  return showFTSheet<void>(
    context,
    title: 'Tree layout',
    builder: (ctx) => _LayoutSheet(mode: mode, onMode: onMode),
  );
}

class _LayoutSheet extends StatefulWidget {
  const _LayoutSheet({required this.mode, required this.onMode});
  final TreeViewMode mode;
  final ValueChanged<TreeViewMode> onMode;

  @override
  State<_LayoutSheet> createState() => _LayoutSheetState();
}

class _LayoutSheetState extends State<_LayoutSheet> {
  late TreeViewMode _mode = widget.mode;

  static const _icons = {
    TreeViewMode.focus: AppIcons.focus,
    TreeViewMode.descendants: AppIcons.arrowDown,
    TreeViewMode.ancestors: AppIcons.arrowUp,
    TreeViewMode.full: AppIcons.tree,
    TreeViewMode.compact: AppIcons.generations,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Switching layouts never changes your family data.', style: context.tx.caption),
        const SizedBox(height: Gap.md),
        for (final m in TreeViewMode.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: FTCard(
              padding: const EdgeInsets.all(14),
              highlighted: m == _mode,
              shadow: false,
              onTap: () {
                setState(() => _mode = m);
                widget.onMode(m);
              },
              semanticLabel: '${m.label}: ${m.description}',
              child: Row(
                children: [
                  IconBadge(icon: _icons[m]!, accent: m == _mode, size: 44),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.label, style: context.tx.bodyStrong),
                        const SizedBox(height: 2),
                        Text(m.description, style: context.tx.caption),
                      ],
                    ),
                  ),
                  if (m == _mode) Icon(AppIcons.checkCircle, color: c.accent),
                ],
              ),
            ),
          ),
        const SizedBox(height: Gap.lg),
        Text('Line styles', style: context.tx.caption),
        const SizedBox(height: Gap.xs),
        const _Legend(),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    Widget item(String label, List<double> dash, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                height: 10,
                child: CustomPaint(painter: _LinePainter(color ?? c.text2, dash)),
              ),
              const SizedBox(width: 12),
              Text(label, style: context.tx.label.copyWith(color: c.text2)),
            ],
          ),
        );
    return Column(
      children: [
        item('Biological parent · current partner', const []),
        item('Adoptive parent', const [8, 5]),
        item('Step-parent · engagement', const [2, 5]),
        item('Foster parent · guardian', const [10, 4, 1.5, 4]),
        item('Divorced / separated partners', const [7, 6]),
        item('Lineage of the selected person', const [], color: c.accent),
      ],
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.color, this.dash);
  final Color color;
  final List<double> dash;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    if (dash.isEmpty) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
      return;
    }
    var x = 0.0;
    var i = 0;
    while (x < size.width) {
      final len = dash[i % dash.length];
      if (i.isEven) canvas.drawLine(Offset(x, y), Offset((x + len).clamp(0, size.width), y), p);
      x += len;
      i++;
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) => false;
}

/// How many generations exist above and below [focus] in its connected part
/// of the tree, plus the total span of that part.
class GenerationDepth {
  const GenerationDepth(this.up, this.down, this.total);
  final int up;
  final int down;
  final int total;

  /// Largest useful "generations up and down" value; anything above shows all.
  int get max => up > down ? up : down;
}

GenerationDepth generationDepth(FamilyGraph g, String focus) {
  if (!g.contains(focus)) return const GenerationDepth(0, 0, 0);
  final gens = g.generations();
  final comp = g.components().firstWhere((c) => c.contains(focus), orElse: () => {focus});
  var lo = gens[focus] ?? 0, hi = lo;
  for (final id in comp) {
    final v = gens[id] ?? 0;
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  final f = gens[focus] ?? 0;
  return GenerationDepth(f - lo, hi - f, hi - lo + 1);
}

/// Lets people limit how many generations around the focus person are
/// drawn. The choices come from the tree itself, so every option changes
/// what's shown.
Future<void> showGenerationSheet(
  BuildContext context, {
  required int value,
  required GenerationDepth depth,
  required int total,
  required int shown,
  required String focusName,
  required ValueChanged<int> onChanged,
}) {
  /// Stored value meaning "no limit".
  const all = 99;
  return showFTSheet<void>(
    context,
    title: 'Filter generations',
    builder: (ctx) {
      var v = value >= depth.max ? all : value;
      return StatefulBuilder(
        builder: (ctx, set) {
          void pick(int n) {
            set(() => v = n);
            onChanged(n);
            Navigator.of(ctx).pop();
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                total <= 1
                    ? 'This part of the tree has 1 generation so far – everyone is already shown.'
                    : 'This part of the tree has $total generations. Showing $shown.',
                style: ctx.tx.body,
              ),
              const SizedBox(height: Gap.xs),
              Text('Choose how far to show above and below $focusName.', style: ctx.tx.caption),
              const SizedBox(height: Gap.md),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FTChip(label: 'All generations', selected: v == all, onTap: () => pick(all)),
                  for (var n = 1; n < depth.max; n++)
                    FTChip(
                      label: n == 1 ? '1 up & down' : '$n up & down',
                      selected: v == n,
                      onTap: () => pick(n),
                    ),
                ],
              ),
            ],
          );
        },
      );
    },
  );
}

/// Bottom panel for the selected person with quick navigation.
class SelectedPersonPanel extends ConsumerWidget {
  const SelectedPersonPanel({
    super.key,
    required this.person,
    required this.graph,
    required this.isFocus,
    required this.collapsed,
    required this.hasChildren,
    this.hasParents = true,
    this.hasPartners = true,
    required this.onClose,
    required this.onProfile,
    required this.onFocus,
    required this.onParents,
    required this.onChildren,
    required this.onPartners,
    required this.onToggleCollapse,
    required this.onAddRelative,
  });

  final Person person;
  final FamilyGraph graph;
  final bool isFocus;
  final bool collapsed;
  final bool hasChildren;
  final bool hasParents;
  final bool hasPartners;
  final VoidCallback onClose;
  final VoidCallback onProfile;
  final VoidCallback onFocus;
  final VoidCallback onParents;
  final VoidCallback onChildren;
  final VoidCallback onPartners;
  final VoidCallback onToggleCollapse;
  final VoidCallback onAddRelative;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(homePersonIdProvider);
    final kin = ref.watch(kinshipProvider);
    String sub = person.lifespanLabel;
    if (home != null && kin != null && home != person.id) {
      final label = kin.primaryLabel(person.id, home);
      if (label != null && label != 'Distant relative') {
        sub = [if (sub.isNotEmpty) sub, '$label of ${graph[home]?.shortName ?? ''}'].join(' · ');
      }
    } else if (home == person.id) {
      sub = [if (sub.isNotEmpty) sub, 'Home person'].join(' · ');
    }
    return FTCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              PersonAvatarFor(person, size: 52, ring: true),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(person.displayName,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.section),
                    if (sub.isNotEmpty)
                      Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.caption),
                  ],
                ),
              ),
              FTIconButton(icon: AppIcons.close, tooltip: 'Clear selection', size: 40, onTap: onClose),
              FTIconButton(icon: AppIcons.arrowUpRight, tooltip: 'Open profile', accent: true, size: 44, onTap: onProfile),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                if (!isFocus) ...[
                  FTChip(label: 'Focus', icon: AppIcons.focus, selected: false, onTap: onFocus),
                  const SizedBox(width: 8),
                ],
                // Only offer jumps that lead somewhere.
                if (hasParents) ...[
                  FTChip(label: 'Parents', icon: AppIcons.arrowUp, selected: false, onTap: onParents),
                  const SizedBox(width: 8),
                ],
                if (hasChildren) ...[
                  FTChip(label: 'Children', icon: AppIcons.arrowDown, selected: false, onTap: onChildren),
                  const SizedBox(width: 8),
                ],
                if (hasPartners) ...[
                  FTChip(label: 'Partners', icon: AppIcons.heart, selected: false, onTap: onPartners),
                  const SizedBox(width: 8),
                ],
                FTChip(label: 'Add relative', icon: AppIcons.personAdd, selected: false, onTap: onAddRelative),
                if (hasChildren) ...[
                  const SizedBox(width: 8),
                  FTChip(
                    label: collapsed ? 'Expand branch' : 'Collapse branch',
                    icon: collapsed ? AppIcons.expand : AppIcons.collapse,
                    selected: collapsed,
                    onTap: onToggleCollapse,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
