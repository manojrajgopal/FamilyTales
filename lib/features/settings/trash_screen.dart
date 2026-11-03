import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/repositories/family_repository.dart';
import '../../core/widgets/widgets.dart';
import 'settings_logic.dart';
import 'widgets/settings_widgets.dart';

/// Deleted items of the active tree (plus deleted trees): restore them or
/// delete them for good. Items are purged automatically after the
/// retention period.
class TrashScreen extends ConsumerStatefulWidget {
  const TrashScreen({super.key});

  static const retentionChoices = [7, 30, 90];

  static IconData iconOf(TrashEntity e) => switch (e) {
        TrashEntity.person => AppIcons.person,
        TrashEntity.event => AppIcons.event,
        TrashEntity.media => AppIcons.photo,
        TrashEntity.story => AppIcons.story,
        TrashEntity.source => AppIcons.source,
        TrashEntity.album => AppIcons.album,
        TrashEntity.tree => AppIcons.tree,
        TrashEntity.relationship => AppIcons.link,
      };

  static String groupLabel(TrashEntity e) => switch (e) {
        TrashEntity.person => 'People',
        TrashEntity.event => 'Events',
        TrashEntity.media => 'Photos & documents',
        TrashEntity.story => 'Stories',
        TrashEntity.source => 'Sources',
        TrashEntity.album => 'Albums',
        TrashEntity.tree => 'Family trees',
        TrashEntity.relationship => 'Relationships',
      };

  @override
  ConsumerState<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends ConsumerState<TrashScreen> {
  final Set<String> _working = {};
  bool _emptying = false;

  List<DeletionRecord> _visible(List<DeletionRecord> all, String? activeId) => all
      .where((r) => r.entityType == TrashEntity.tree || r.treeId == null || r.treeId == activeId)
      .toList();

  // ---------------------------------------------------------------- actions

  Future<void> _restore(DeletionRecord r) async {
    if (_working.contains(r.id)) return;
    final settings = ref.read(settingsProvider.notifier);
    setState(() => _working.add(r.id));
    try {
      final ok = await ref.read(systemRepoProvider).restore(r.id);
      if (!mounted) return;
      if (!ok) {
        showFTToast(context, 'This item is no longer in the trash', error: true);
      } else if (r.entityType == TrashEntity.tree) {
        showFTToast(
          context,
          '“${r.label}” restored',
          actionLabel: 'Open',
          onAction: () => settings.setActiveTree(r.entityId),
        );
      } else {
        showFTToast(context, '“${r.label}” restored');
      }
    } on ValidationException catch (e) {
      if (mounted) showFTToast(context, e.message, error: true);
    } catch (e) {
      if (mounted) showFTToast(context, 'Couldn’t restore it. ${friendlyError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _working.remove(r.id));
    }
  }

  Future<void> _purge(DeletionRecord r) async {
    if (_working.contains(r.id)) return;
    final system = ref.read(systemRepoProvider);
    var exclusive = 0;
    if (r.entityType == TrashEntity.person) {
      try {
        exclusive = (await system.exclusiveMediaOf(r.entityId)).length;
      } catch (_) {}
      if (!mounted) return;
    }
    final deleteMedia = await showFTSheet<bool>(
      context,
      builder: (_) => _PurgeConfirm(record: r, exclusivePhotos: exclusive),
    );
    if (deleteMedia == null || !mounted) return;
    setState(() => _working.add(r.id));
    try {
      await system.purge(r.id, deleteExclusiveMedia: deleteMedia);
      if (!mounted) return;
      showFTToast(
        context,
        deleteMedia && exclusive > 0
            ? '“${r.label}” and ${plural(exclusive, 'photo')} deleted'
            : '“${r.label}” deleted permanently',
      );
    } catch (e) {
      if (mounted) showFTToast(context, 'Couldn’t delete it. ${friendlyError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _working.remove(r.id));
    }
  }

  Future<void> _options(DeletionRecord r) async {
    final choice = await showFTOptions<bool>(
      context,
      title: r.label,
      options: const [
        FTOption(true, 'Restore', icon: AppIcons.restore, subtitle: 'Put it back where it was'),
        FTOption(false, 'Delete permanently',
            icon: AppIcons.delete, danger: true, subtitle: 'Erase it from this device'),
      ],
    );
    if (choice == null || !mounted) return;
    choice ? await _restore(r) : await _purge(r);
  }

  Future<void> _emptyVisible(List<DeletionRecord> records) async {
    if (records.isEmpty || _emptying) return;
    final ok = await showFTConfirm(
      context,
      title: 'Empty trash?',
      message: '${plural(records.length, 'item')} will be permanently deleted from this device. '
          'Photos that are still linked to someone stay in the gallery. This can’t be undone.',
      confirmLabel: 'Empty trash',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final system = ref.read(systemRepoProvider);
    setState(() => _emptying = true);
    var failed = 0;
    for (final r in records) {
      try {
        await system.purge(r.id);
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() => _emptying = false);
    showFTToast(
      context,
      failed == 0 ? 'Trash emptied' : 'Trash emptied · ${plural(failed, 'item')} couldn’t be deleted',
      error: failed > 0,
    );
  }

  Future<void> _setRetention(int days) async {
    final current = ref.read(settingsProvider).trashRetentionDays;
    if (days == current) return;
    final maintenance = ref.read(maintenanceProvider);
    final settings = ref.read(settingsProvider.notifier);
    try {
      if (days < current) {
        final older = await maintenance.trashOlderThan(days);
        if (!mounted) return;
        if (older > 0) {
          final ok = await showFTConfirm(
            context,
            title: 'Keep items for $days days?',
            message: '${plural(older, 'item')} in the trash ${older == 1 ? 'is' : 'are'} older than '
                '$days days and will be permanently deleted now.',
            confirmLabel: 'Delete and save',
            destructive: true,
          );
          if (!ok) return;
          await settings.update((p) => p.copyWith(trashRetentionDays: days));
          await ref.read(systemRepoProvider).autoPurge(days: days);
          if (mounted) showFTToast(context, 'Removed ${plural(older, 'old item')}');
          return;
        }
      }
      await settings.update((p) => p.copyWith(trashRetentionDays: days));
    } catch (e) {
      if (mounted) showFTToast(context, 'Couldn’t save that. ${friendlyError(e)}', error: true);
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(settingsProvider);
    final activeId = ref.watch(activeTreeIdProvider);
    final activeTree = ref.watch(activeTreeProvider);
    final trash = ref.watch(trashProvider);
    final visible = _visible(trash.value ?? const [], activeId);

    return FTPage(
      title: 'Trash',
      actions: [
        if (visible.isNotEmpty)
          FTIconButton(
            icon: AppIcons.broom,
            tooltip: 'Empty trash',
            onTap: _emptying ? null : () => _emptyVisible(visible),
          ),
      ],
      body: trash.when(
        skipLoadingOnReload: true,
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(trashProvider)),
        data: (_) => _buildList(context, prefs.trashRetentionDays, visible, activeTree?.name),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    int retention,
    List<DeletionRecord> visible,
    String? treeName,
  ) {
    final pad = context.pagePadding;
    final items = <Object>[_Slot.retention];
    if (visible.isEmpty) {
      items.add(_Slot.empty);
    } else {
      items.add(_Slot.scope);
      final groups = <TrashEntity, List<DeletionRecord>>{};
      for (final r in visible) {
        (groups[r.entityType] ??= []).add(r);
      }
      for (final e in TrashEntity.values) {
        final g = groups[e];
        if (g == null || g.isEmpty) continue;
        items.add(e);
        items.addAll(g);
      }
    }

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, FTPage.bottomInset(context)),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final it = items[i];
        final Widget child = switch (it) {
          _Slot.retention => Padding(
              padding: const EdgeInsets.only(bottom: Gap.lg),
              child: _RetentionCard(days: retention, onChanged: _setRetention),
            ),
          _Slot.empty => EmptyState(
              icon: AppIcons.trash,
              title: 'Trash is empty',
              message: 'Deleted people, events, photos and stories wait here for '
                  '$retention days, so you can bring them back.',
            ),
          _Slot.scope => Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: Text(
                treeName == null
                    ? 'Showing deleted items and deleted trees.'
                    : 'Showing items deleted from $treeName, plus deleted trees.',
                style: context.tx.caption,
              ),
            ),
          final TrashEntity e => Padding(
              padding: EdgeInsets.only(top: i <= 2 ? 0 : Gap.md),
              child: SectionHeader(
                TrashScreen.groupLabel(e),
                // FTTag contains a Flexible, so it needs a bounded width here.
                trailing: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 96),
                  child: FTTag('${visible.where((r) => r.entityType == e).length}'),
                ),
              ),
            ),
          final DeletionRecord r => Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: _TrashRow(
                record: r,
                retentionDays: retention,
                busy: _emptying || _working.contains(r.id),
                onRestore: () => _restore(r),
                onDelete: () => _purge(r),
                onOptions: () => _options(r),
              ),
            ),
          _ => const SizedBox.shrink(),
        };
        return ContentWidth(
          child: i < 14 ? FadeSlideIn(index: i, child: child) : child,
        );
      },
    );
  }
}

enum _Slot { retention, empty, scope }

class _RetentionCard extends StatelessWidget {
  const _RetentionCard({required this.days, required this.onChanged});
  final int days;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final choices = TrashScreen.retentionChoices;
    final selected = choices.contains(days) ? days : choices[1];
    return FTCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const IconBadge(icon: AppIcons.hourglass),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Keep deleted items for', style: context.tx.section),
                    const SizedBox(height: 2),
                    Text('Items are permanently deleted after $days days.',
                        style: context.tx.caption),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.md),
          FTSegmented<int>(
            values: choices,
            selected: selected,
            labelOf: (d) => '$d days',
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _TrashRow extends StatelessWidget {
  const _TrashRow({
    required this.record,
    required this.retentionDays,
    required this.busy,
    required this.onRestore,
    required this.onDelete,
    required this.onOptions,
  });

  final DeletionRecord record;
  final int retentionDays;
  final bool busy;
  final VoidCallback onRestore;
  final VoidCallback onDelete;
  final VoidCallback onOptions;

  String _expiry() {
    final purgeAt = record.deletedAt.add(Duration(days: retentionDays));
    final left = purgeAt.difference(DateTime.now());
    if (left.inHours < 24) return 'deletes within a day';
    final d = left.inDays;
    return d == 1 ? 'deletes in 1 day' : 'deletes in $d days';
  }

  @override
  Widget build(BuildContext context) {
    final date = DateFormat.yMMMd().format(record.deletedAt.toLocal());
    final kind = record.entityType.label;
    return FTCard(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xxs, Gap.sm),
      onTap: busy ? null : onOptions,
      semanticLabel: '$kind ${record.label}, deleted $date',
      child: Row(
        children: [
          IconBadge(icon: TrashScreen.iconOf(record.entityType)),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(record.label,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                const SizedBox(height: 2),
                Text(
                  'Deleted ${timeAgo(record.deletedAt)} · ${_expiry()}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.tx.caption,
                ),
              ],
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: Gap.md),
              child: RowSpinner(),
            )
          else ...[
            FTIconButton(
              icon: AppIcons.restore,
              tooltip: 'Restore ${record.label}',
              size: 40,
              onTap: onRestore,
            ),
            FTIconButton(
              icon: AppIcons.delete,
              tooltip: 'Delete ${record.label} permanently',
              size: 40,
              onTap: onDelete,
            ),
          ],
        ],
      ),
    );
  }
}

/// Confirmation for permanent deletion. Returns null when cancelled,
/// otherwise whether photos linked only to the person should go too.
class _PurgeConfirm extends StatefulWidget {
  const _PurgeConfirm({required this.record, required this.exclusivePhotos});
  final DeletionRecord record;
  final int exclusivePhotos;

  @override
  State<_PurgeConfirm> createState() => _PurgeConfirmState();
}

class _PurgeConfirmState extends State<_PurgeConfirm> {
  bool _deleteMedia = false;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final r = widget.record;
    final n = widget.exclusivePhotos;
    final detail = switch (r.entityType) {
      TrashEntity.tree => ' This includes every person, event, photo and story in the tree.',
      TrashEntity.media => ' The photo file is removed from this device too.',
      _ => '',
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: IconBadge(
            icon: AppIcons.warning,
            size: 52,
            color: c.danger.withValues(alpha: 0.16),
          ),
        ),
        const SizedBox(height: Gap.md),
        Text('Delete permanently?', style: context.tx.title),
        const SizedBox(height: Gap.xs),
        Text('“${r.label}” will be erased from this device.$detail This can’t be undone.',
            style: context.tx.body),
        if (n > 0) ...[
          const SizedBox(height: Gap.md),
          FTSwitchRow(
            icon: AppIcons.photos,
            title: 'Also delete ${plural(n, 'photo')} linked only to this person',
            subtitle: _deleteMedia
                ? 'They’ll be removed from the gallery and this device'
                : 'Off: ${n == 1 ? 'it stays' : 'they stay'} in the gallery',
            value: _deleteMedia,
            onChanged: (v) => setState(() => _deleteMedia = v),
          ),
        ],
        const SizedBox(height: Gap.xl),
        Row(
          children: [
            Expanded(
              child: FTButton.secondary(
                label: 'Cancel',
                expand: true,
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: FTButton(
                label: 'Delete',
                expand: true,
                kind: FTButtonKind.danger,
                onTap: () => Navigator.of(context).pop(_deleteMedia),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
