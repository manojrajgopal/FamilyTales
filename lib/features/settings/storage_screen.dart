import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/repositories/family_repository.dart';
import '../../core/repositories/system_repository.dart';
import '../../core/services/app_paths.dart';
import '../../core/widgets/widgets.dart';
import '../trees/tree_logic.dart';
import 'settings_logic.dart';
import 'widgets/settings_widgets.dart';

enum _Task { orphans, vacuum, integrity, emptyTrash, clearTree, eraseAll }

/// Space used on this device plus maintenance and clean-up tools.
class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});

  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  _Task? _running;

  /// Runs one maintenance task at a time with a spinner on its row.
  Future<void> _run(_Task task, Future<void> Function() action) async {
    if (_running != null) return;
    setState(() => _running = task);
    try {
      await action();
    } on ValidationException catch (e) {
      if (mounted) showFTToast(context, e.message, error: true);
    } catch (e) {
      if (mounted) showFTToast(context, 'That didn’t work. ${friendlyError(e)}', error: true);
    } finally {
      if (mounted) {
        setState(() => _running = null);
        ref.invalidate(storageReportProvider);
      }
    }
  }

  Widget? _trailing(_Task t) => _running == t ? const RowSpinner() : null;

  // ---------------------------------------------------------------- tasks

  Future<void> _cleanOrphans() => _run(_Task.orphans, () async {
        final n = await ref.read(systemRepoProvider).cleanOrphanFiles();
        if (!mounted) return;
        showFTToast(context, n == 0 ? 'No unused files found' : 'Removed ${plural(n, 'unused file')}');
      });

  Future<void> _optimise() => _run(_Task.vacuum, () async {
        final saved = await ref.read(maintenanceProvider).optimise();
        if (!mounted) return;
        showFTToast(context,
            saved > 0 ? 'Database optimised · ${formatBytes(saved)} freed' : 'Database optimised');
      });

  Future<void> _checkIntegrity() => _run(_Task.integrity, () async {
        final errors = await ref.read(databaseProvider).integrityCheckErrors();
        if (!mounted) return;
        if (errors == 0) {
          showFTToast(context, 'No problems found · your database passed the full integrity check');
        } else {
          final backup = await showFTConfirm(
            context,
            title: 'Problems found',
            message: 'The integrity check reported ${plural(errors, 'problem')}. '
                'Create a backup now, then restore your most recent good backup if '
                'something looks wrong.',
            confirmLabel: 'Open backups',
            cancelLabel: 'Later',
            destructive: true,
          );
          if (backup && mounted) context.push(Routes.backup);
        }
      });

  Future<void> _emptyTrash(int count) async {
    if (count == 0) {
      showFTToast(context, 'The trash is already empty');
      return;
    }
    final ok = await showFTConfirm(
      context,
      title: 'Empty trash?',
      message: 'This permanently deletes ${plural(count, 'item')} in the trash across all '
          'family trees, including their photos. This can’t be undone.',
      confirmLabel: 'Empty trash',
      destructive: true,
    );
    if (!ok) return;
    await _run(_Task.emptyTrash, () async {
      await ref.read(systemRepoProvider).emptyTrash();
      if (mounted) showFTToast(context, 'Trash emptied');
    });
  }

  Future<void> _clearTree(Map<String, TreeStats> stats) async {
    final trees = ref.read(treesProvider).value ?? const <FamilyTree>[];
    if (trees.isEmpty) {
      showFTToast(context, 'There are no family trees to clear', error: true);
      return;
    }
    final activeId = ref.read(activeTreeIdProvider);
    final id = await showFTOptions<String>(
      context,
      title: 'Clear a family tree',
      options: [
        for (final t in trees)
          FTOption(
            t.id,
            t.name,
            icon: AppIcons.tree,
            subtitle: _treeSummary(stats[t.id]),
            selected: t.id == activeId,
          ),
      ],
    );
    if (id == null || !mounted) return;
    final tree = trees.firstWhere((t) => t.id == id);
    final only = trees.length == 1;
    final days = ref.read(settingsProvider).trashRetentionDays;
    final ok = await showFTConfirm(
      context,
      title: 'Clear “${tree.name}”?',
      message: 'The whole tree – ${_treeSummary(stats[id])} – moves to the trash. '
          'You can restore it from Trash for $days days.'
          '${only ? ' Because it’s your only tree, a new empty tree will be created for you.' : ''}',
      confirmLabel: 'Move to trash',
      destructive: true,
    );
    if (!ok) return;
    // Captured now: the Undo action may run after this screen is closed.
    final system = ref.read(systemRepoProvider);
    final settings = ref.read(settingsProvider.notifier);
    await _run(_Task.clearTree, () async {
      final r = await ref
          .read(treeActionsProvider)
          .trash(id, activeId: activeId, allowLast: true);
      if (r.newActiveId != null) await settings.setActiveTree(r.newActiveId!);
      if (!mounted) return;
      final recordId = r.recordId;
      showFTToast(
        context,
        r.createdReplacement ? 'Tree moved to trash · started a new empty tree' : 'Tree moved to trash',
        actionLabel: recordId == null ? null : 'Undo',
        onAction: recordId == null
            ? null
            : () async {
                try {
                  await system.restore(recordId);
                  await settings.setActiveTree(id);
                } catch (_) {}
              },
      );
    });
  }

  Future<void> _eraseEverything() async {
    final first = await showFTConfirm(
      context,
      title: 'Delete all local data?',
      message: 'Every family tree, person, event, story, photo and document stored by '
          'Family Tales on this device will be permanently erased, and your settings '
          'and PIN reset. Backups you saved elsewhere are not affected.\n\n'
          'This can’t be undone. Consider creating a backup first.',
      confirmLabel: 'Continue',
      destructive: true,
    );
    if (!first || !mounted) return;
    final typed = await showFTSheet<bool>(
      context,
      title: 'Type DELETE to confirm',
      builder: (_) => const _TypeToConfirm(word: 'DELETE'),
    );
    if (typed != true || !mounted) return;
    final router = GoRouter.of(context);
    await _run(_Task.eraseAll, () async {
      await ref.read(maintenanceProvider).eraseEverything();
      await resetPreferences(ref);
      router.go(Routes.welcome);
    });
  }

  static String _treeSummary(TreeStats? s) {
    final st = s ?? TreeStats.empty;
    return '${plural(st.people, 'person', 'people')}, '
        '${plural(st.events, 'event')}, ${plural(st.photos, 'photo')}';
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final report = ref.watch(storageReportProvider);
    final stats = ref.watch(treeStatsProvider).value ?? const <String, TreeStats>{};
    final trashCount = ref.watch(trashProvider).value?.length ?? report.value?.trashItems ?? 0;
    final busy = _running != null;

    return FTPage(
      title: 'Storage',
      actions: [
        FTIconButton(
          icon: AppIcons.refresh,
          tooltip: 'Refresh',
          onTap: () => ref.invalidate(storageReportProvider),
        ),
      ],
      body: SettingsBody(
        children: [
          report.when(
            skipLoadingOnReload: true,
            data: (r) => _UsageCard(report: r),
            loading: () => const FTCard(
              child: SizedBox(height: 180, child: LoadingView()),
            ),
            error: (e, _) => InfoCard(
              icon: AppIcons.warning,
              title: 'Couldn’t measure storage',
              message: friendlyError(e),
              danger: true,
            ),
          ),
          SettingsGroup(
            title: 'Maintenance',
            children: [
              FTListRow(
                icon: AppIcons.broom,
                title: 'Clean up unused files',
                subtitle: 'Remove photo files no longer linked to anything',
                trailing: _trailing(_Task.orphans),
                onTap: busy ? null : _cleanOrphans,
              ),
              FTListRow(
                icon: AppIcons.database,
                title: 'Optimise database',
                subtitle: 'Compact the database and reclaim free space',
                trailing: _trailing(_Task.vacuum),
                onTap: busy ? null : _optimise,
              ),
              FTListRow(
                icon: AppIcons.shield,
                title: 'Check database integrity',
                subtitle: 'Scan for damaged or inconsistent data',
                trailing: _trailing(_Task.integrity),
                onTap: busy ? null : _checkIntegrity,
              ),
            ],
          ),
          SettingsGroup(
            title: 'Clean up',
            children: [
              FTListRow(
                icon: AppIcons.trash,
                title: 'Empty trash',
                subtitle: trashCount == 0
                    ? 'The trash is empty'
                    : '${plural(trashCount, 'item')} waiting in the trash',
                trailing: _trailing(_Task.emptyTrash),
                onTap: busy ? null : () => _emptyTrash(trashCount),
              ),
              FTListRow(
                icon: AppIcons.tree,
                title: 'Clear a family tree',
                subtitle: 'Move an entire tree to the trash',
                trailing: _trailing(_Task.clearTree),
                onTap: busy ? null : () => _clearTree(stats),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Danger zone',
            footer: 'Erases everything Family Tales stores on this device and returns '
                'the app to its first-run state.',
            children: [
              FTListRow(
                icon: AppIcons.warning,
                title: 'Permanently delete all local data',
                subtitle: 'Trees, people, photos, settings and PIN',
                danger: true,
                trailing: _trailing(_Task.eraseAll),
                onTap: busy ? null : _eraseEverything,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Total size, share bars (database vs files) and record counts.
class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.report});
  final StorageReport report;

  @override
  Widget build(BuildContext context) {
    final total = report.totalBytes;
    double share(int bytes) => total <= 0 ? 0 : bytes / total;
    final mediaLabel = report.documents > 0 ? 'Photos & documents' : 'Photos';
    return FTCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const IconBadge(icon: AppIcons.storage, size: 48),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(formatBytes(total), style: context.tx.headline),
                    Text('used on this device', style: context.tx.caption),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.lg),
          StripedProgress(value: share(report.databaseBytes), label: 'Database'),
          const SizedBox(height: Gap.xs),
          StripedProgress(value: share(report.mediaBytes), label: mediaLabel),
          const SizedBox(height: Gap.sm),
          Wrap(
            spacing: Gap.md,
            runSpacing: Gap.xxs,
            children: [
              Text('Database ${formatBytes(report.databaseBytes)}', style: context.tx.caption),
              Text('$mediaLabel ${formatBytes(report.mediaBytes)}', style: context.tx.caption),
            ],
          ),
          const HairLine(vertical: Gap.md),
          Row(
            children: [
              Expanded(
                child: MetricTile(
                    value: '${report.people}', label: 'People', icon: AppIcons.people),
              ),
              Expanded(
                child: MetricTile(
                    value: '${report.photos}', label: 'Photos', icon: AppIcons.photo),
              ),
            ],
          ),
          const SizedBox(height: Gap.md),
          Row(
            children: [
              Expanded(
                child: MetricTile(
                    value: '${report.documents}', label: 'Documents', icon: AppIcons.document),
              ),
              Expanded(
                child: MetricTile(
                    value: '${report.trashItems}', label: 'In trash', icon: AppIcons.trash),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Final safety step: the confirm button only enables once [word] is typed.
class _TypeToConfirm extends StatefulWidget {
  const _TypeToConfirm({required this.word});
  final String word;

  @override
  State<_TypeToConfirm> createState() => _TypeToConfirmState();
}

class _TypeToConfirmState extends State<_TypeToConfirm> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  bool get _matches => _ctl.text.trim() == widget.word;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'All family data on this device will be erased immediately. '
          'Type ${widget.word} in capitals to confirm.',
          style: context.tx.body,
        ),
        const SizedBox(height: Gap.lg),
        FTTextField(
          controller: _ctl,
          label: 'Type ${widget.word}',
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (_matches) Navigator.of(context).pop(true);
          },
        ),
        const SizedBox(height: Gap.lg),
        FTButton(
          label: 'Delete everything',
          icon: AppIcons.delete,
          kind: FTButtonKind.danger,
          expand: true,
          onTap: _matches ? () => Navigator.of(context).pop(true) : null,
        ),
        const SizedBox(height: Gap.xs),
        Text(
          'Tip: keep a backup file somewhere safe if you might want this data again.',
          style: context.tx.caption.copyWith(color: c.text3),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
