import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/repositories/family_repository.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../members/widgets/person_widgets.dart';
import '../settings/widgets/settings_widgets.dart';
import 'tree_logic.dart';
import 'tree_sheets.dart';

enum _TreeAction { open, edit, home, merge, delete }

/// All family trees on this device: switch, create, edit, set the home
/// person, delete and merge.
class TreesScreen extends ConsumerStatefulWidget {
  const TreesScreen({super.key});

  @override
  ConsumerState<TreesScreen> createState() => _TreesScreenState();
}

class _TreesScreenState extends ConsumerState<TreesScreen> {
  /// Tree currently being changed ('' = a screen-wide operation).
  String? _busy;

  TreeActions get _actions => ref.read(treeActionsProvider);
  SettingsController get _settings => ref.read(settingsProvider.notifier);

  Future<void> _guard(String key, Future<void> Function() action) async {
    if (_busy != null) return;
    setState(() => _busy = key);
    try {
      await action();
    } on ValidationException catch (e) {
      if (mounted) showFTToast(context, e.message, error: true);
    } catch (e) {
      if (mounted) showFTToast(context, 'That didn’t work. ${friendlyError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  static String _summary(TreeStats? s) {
    final st = s ?? TreeStats.empty;
    return '${plural(st.people, 'person', 'people')}, ${plural(st.events, 'event')} '
        'and ${plural(st.photos, 'photo')}';
  }

  // ---------------------------------------------------------------- actions

  Future<void> _create() async {
    final r = await showTreeFormSheet(
      context,
      title: 'New family tree',
      confirmLabel: 'Create tree',
    );
    if (r == null || !mounted) return;
    await _guard('', () async {
      final id = await _actions.create(r.name, description: r.description);
      if (!mounted) return;
      final switchNow = await showFTConfirm(
        context,
        title: 'Switch to “${r.name}”?',
        message: 'Open your new tree now to start adding people. You can switch between '
            'trees any time from here.',
        confirmLabel: 'Switch now',
        cancelLabel: 'Stay here',
        icon: AppIcons.tree,
      );
      if (switchNow) {
        await _settings.setActiveTree(id);
        if (mounted) showFTToast(context, 'Now viewing “${r.name}”');
      } else if (mounted) {
        showFTToast(context, '“${r.name}” created');
      }
    });
  }

  Future<void> _switchTo(FamilyTree t) => _guard(t.id, () async {
        await _settings.setActiveTree(t.id);
        if (mounted) showFTToast(context, 'Now viewing “${t.name}”');
      });

  Future<void> _edit(FamilyTree t) async {
    final r = await showTreeFormSheet(
      context,
      title: 'Edit tree',
      confirmLabel: 'Save changes',
      initialName: t.name,
      initialDescription: t.description,
    );
    if (r == null || !mounted) return;
    await _guard(t.id, () async {
      await _actions.edit(t.id, name: r.name, description: r.description);
      if (mounted) showFTToast(context, 'Tree updated');
    });
  }

  Future<void> _setHomePerson(FamilyTree t, TreeStats? s) async {
    if ((s?.people ?? 0) == 0) {
      showFTToast(context, 'Add people to “${t.name}” first', error: true);
      return;
    }
    if (ref.read(activeTreeIdProvider) != t.id) {
      // The person picker lists the active tree, so open this tree first
      // and wait until its people have loaded.
      await _settings.setActiveTree(t.id);
      try {
        await Future.wait([
          ref.read(peopleProvider.future),
          ref.read(parentLinksProvider.future),
          ref.read(partnershipsProvider.future),
        ]);
      } catch (_) {}
      if (!mounted) return;
      showFTToast(context, 'Now viewing “${t.name}”');
    }
    if (!mounted) return;
    final id = await pickPerson(
      context,
      title: 'Home person for ${t.name}',
      exclude: {?t.homePersonId},
    );
    if (id == null || !mounted) return;
    await _guard(t.id, () async {
      await _actions.setHomePerson(t.id, id);
      if (mounted) showFTToast(context, 'Home person updated');
    });
  }

  Future<void> _delete(FamilyTree t, List<FamilyTree> trees, TreeStats? s) async {
    if (trees.length <= 1) {
      showFTToast(
        context,
        'This is your only family tree. Create another tree before deleting it.',
        error: true,
      );
      return;
    }
    final days = ref.read(settingsProvider).trashRetentionDays;
    final ok = await showFTConfirm(
      context,
      title: 'Delete “${t.name}”?',
      message: 'The tree and everything in it – ${_summary(s)} – moves to the trash. '
          'You can restore it from Trash for $days days.',
      confirmLabel: 'Move to trash',
      destructive: true,
    );
    if (!ok || !mounted) return;
    // Captured now: Undo may run after this screen has closed.
    final system = ref.read(systemRepoProvider);
    final settings = _settings;
    final activeId = ref.read(activeTreeIdProvider);
    await _guard(t.id, () async {
      final r = await _actions.trash(t.id, activeId: activeId);
      if (r.newActiveId != null) await settings.setActiveTree(r.newActiveId!);
      if (!mounted) return;
      final recordId = r.recordId;
      showFTToast(
        context,
        '“${t.name}” moved to trash',
        actionLabel: recordId == null ? null : 'Undo',
        onAction: recordId == null
            ? null
            : () async {
                try {
                  await system.restore(recordId);
                  if (activeId == t.id) await settings.setActiveTree(t.id);
                } catch (_) {}
              },
      );
    });
  }

  Future<void> _merge(List<FamilyTree> trees, {String? sourceId}) async {
    if (trees.length < 2) {
      showFTToast(context, 'You need at least two trees to merge', error: true);
      return;
    }
    final router = GoRouter.of(context);
    final activeId = ref.read(activeTreeIdProvider);
    String? target;
    if (sourceId != null && activeId != sourceId) target = activeId;
    if (sourceId == null && activeId != null) target = activeId;
    final choice = await showMergeTreesSheet(
      context,
      initialSourceId: sourceId,
      initialTargetId: target,
      onBackupFirst: () => router.push(Routes.backup),
    );
    if (choice == null || !mounted) return;
    final source = trees.firstWhere((t) => t.id == choice.sourceId);
    final dest = trees.firstWhere((t) => t.id == choice.targetId);
    final stats = ref.read(treeStatsProvider).value?[source.id];
    final ok = await showFTConfirm(
      context,
      title: 'Merge into “${dest.name}”?',
      message: 'Everything in “${source.name}” – ${_summary(stats)} – moves into '
          '“${dest.name}”, and “${source.name}” is removed. People are not merged '
          'automatically. This can’t be undone.',
      confirmLabel: 'Merge trees',
      destructive: true,
      icon: AppIcons.merge,
    );
    if (!ok || !mounted) return;
    await _guard('', () async {
      await _actions.merge(sourceId: source.id, targetId: dest.id);
      await _settings.setActiveTree(dest.id);
      if (!mounted) return;
      showFTToast(
        context,
        'Merged into “${dest.name}”. Check for people listed twice.',
        actionLabel: 'Find duplicates',
        onAction: () => router.push(Routes.duplicates),
      );
    });
  }

  Future<void> _options(FamilyTree t, bool active, List<FamilyTree> trees, TreeStats? s) async {
    final only = trees.length <= 1;
    final action = await showFTOptions<_TreeAction>(
      context,
      title: t.name,
      options: [
        if (!active)
          const FTOption(_TreeAction.open, 'Switch to this tree',
              icon: AppIcons.swap, subtitle: 'View and edit this tree'),
        const FTOption(_TreeAction.edit, 'Rename or edit description', icon: AppIcons.edit),
        const FTOption(_TreeAction.home, 'Set home person',
            icon: AppIcons.house,
            subtitle: 'Default focus for the tree and relationship labels'),
        if (!only)
          const FTOption(_TreeAction.merge, 'Merge into another tree',
              icon: AppIcons.merge, subtitle: 'Move everything from this tree into another'),
        FTOption(
          _TreeAction.delete,
          'Delete tree',
          icon: AppIcons.delete,
          danger: true,
          subtitle: only ? 'Not available for your only tree' : 'Moves it to the trash',
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _TreeAction.open:
        await _switchTo(t);
      case _TreeAction.edit:
        await _edit(t);
      case _TreeAction.home:
        await _setHomePerson(t, s);
      case _TreeAction.merge:
        await _merge(trees, sourceId: t.id);
      case _TreeAction.delete:
        await _delete(t, trees, s);
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final trees = ref.watch(treesProvider);
    final activeId = ref.watch(activeTreeIdProvider);
    final stats = ref.watch(treeStatsProvider).value ?? const <String, TreeStats>{};
    final list = trees.value ?? const <FamilyTree>[];
    final idle = _busy == null;

    return FTPage(
      title: 'Family trees',
      actions: [
        FTIconButton(
          icon: AppIcons.merge,
          tooltip: 'Merge trees',
          onTap: idle && list.length > 1 ? () => _merge(list) : null,
        ),
        FTIconButton(
          icon: AppIcons.add,
          tooltip: 'New family tree',
          accent: true,
          onTap: idle ? _create : null,
        ),
      ],
      body: trees.when(
        skipLoadingOnReload: true,
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(treesProvider)),
        data: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: AppIcons.tree,
              title: 'No family trees yet',
              message: 'Create a tree to start recording your family.',
              actionLabel: 'Create a tree',
              onAction: idle ? _create : null,
            );
          }
          final pad = context.pagePadding;
          final count = list.length + 2;
          return ListView.builder(
            padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, FTPage.bottomInset(context)),
            itemCount: count,
            itemBuilder: (context, i) {
              Widget child;
              if (i == 0) {
                child = Padding(
                  padding: const EdgeInsets.only(bottom: Gap.md),
                  child: Text(
                    list.length == 1
                        ? 'Keep separate families – like your partner’s side – in their own trees.'
                        : '${plural(list.length, 'tree')} on this device. Tap a tree for more options.',
                    style: context.tx.caption,
                  ),
                );
              } else if (i == count - 1) {
                child = Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: FTButton.secondary(
                    label: 'Create a new tree',
                    icon: AppIcons.add,
                    expand: true,
                    onTap: idle ? _create : null,
                  ),
                );
              } else {
                final t = list[i - 1];
                final active = t.id == activeId;
                final s = stats[t.id];
                child = Padding(
                  padding: const EdgeInsets.only(bottom: Gap.md),
                  child: _TreeCard(
                    tree: t,
                    active: active,
                    stats: s,
                    busy: _busy == t.id,
                    onOptions: idle ? () => _options(t, active, list, s) : null,
                    onSwitch: idle && !active ? () => _switchTo(t) : null,
                  ),
                );
              }
              return ContentWidth(
                child: i < 12 ? FadeSlideIn(index: i, child: child) : child,
              );
            },
          );
        },
      ),
    );
  }
}

class _TreeCard extends ConsumerWidget {
  const _TreeCard({
    required this.tree,
    required this.active,
    required this.stats,
    required this.busy,
    required this.onOptions,
    required this.onSwitch,
  });

  final FamilyTree tree;
  final bool active;
  final TreeStats? stats;
  final bool busy;
  final VoidCallback? onOptions;
  final VoidCallback? onSwitch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ft;
    final s = stats ?? TreeStats.empty;
    final homeId = tree.homePersonId;
    final person = homeId == null ? null : ref.watch(personProvider(homeId)).value;
    final home = person?.deletedAt == null ? person : null;
    final desc = tree.description?.trim() ?? '';

    return FTCard(
      highlighted: active,
      onTap: onOptions,
      semanticLabel: '${tree.name}${active ? ', active tree' : ''}, '
          '${plural(s.people, 'person', 'people')}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconBadge(icon: AppIcons.tree, size: 48, accent: active),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(tree.name,
                        maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.title),
                    if (desc.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(desc,
                          maxLines: 3, overflow: TextOverflow.ellipsis, style: context.tx.body),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: Gap.xs),
              if (busy)
                const Padding(padding: EdgeInsets.all(Gap.md), child: RowSpinner())
              else
                FTIconButton(
                  icon: AppIcons.moreHoriz,
                  tooltip: 'Options for ${tree.name}',
                  size: 40,
                  onTap: onOptions,
                ),
            ],
          ),
          const SizedBox(height: Gap.md),
          Wrap(
            spacing: Gap.xs,
            runSpacing: Gap.xs,
            children: [
              if (active) const FTTag('Active', icon: AppIcons.checkCircle, accent: true),
              if (tree.isExample) const FTTag('Example', icon: AppIcons.sparkle),
              FTTag(plural(s.people, 'person', 'people'), icon: AppIcons.people),
              FTTag(plural(s.events, 'event'), icon: AppIcons.event),
              FTTag(plural(s.photos, 'photo'), icon: AppIcons.photo),
              if (s.stories > 0) FTTag(plural(s.stories, 'story', 'stories'), icon: AppIcons.story),
            ],
          ),
          if (home != null) ...[
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                Icon(AppIcons.house, size: 15, color: c.text3),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Home person: ${home.displayName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.tx.caption,
                  ),
                ),
              ],
            ),
          ],
          if (!active) ...[
            const SizedBox(height: Gap.md),
            FTButton.secondary(
              label: 'Switch to this tree',
              icon: AppIcons.swap,
              expand: true,
              height: 46,
              onTap: onSwitch,
            ),
          ],
        ],
      ),
    );
  }
}
