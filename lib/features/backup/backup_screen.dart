import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/services/app_paths.dart';
import '../../core/widgets/widgets.dart';
import 'backup_service.dart';
import 'widgets/backup_widgets.dart';

/// Backup hub: create password-protected backups, see history, and reach
/// restore / GEDCOM import / export.
class BackupScreen extends ConsumerWidget {
  const BackupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pad = context.pagePadding;
    final prefs = ref.watch(settingsProvider);
    final history = ref.watch(backupHistoryProvider);
    final last = prefs.lastBackupAt;
    final days = last == null ? null : DateTime.now().difference(last).inDays;
    final freshness = days == null ? 0.0 : (1 - days / 30).clamp(0.06, 1.0);

    return FTPage(
      title: 'Backup & restore',
      actions: [
        FTIconButton(
          icon: AppIcons.info,
          tooltip: 'How backups work',
          onTap: () => _explain(context),
        ),
      ],
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(pad, Gap.sm, pad, FTPage.bottomInset(context)),
        child: ContentWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FadeSlideIn(
                child: FTCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const IconBadge(icon: AppIcons.shield, size: 48, accent: true),
                          const SizedBox(width: Gap.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Your family lives on this device', style: context.tx.title),
                                const SizedBox(height: Gap.xxs),
                                Text(
                                  'Family Tales has no cloud and no account. A backup file is the only way '
                                  'to keep a safe copy or move your family to a new phone.',
                                  style: context.tx.body,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Gap.lg),
                      StripedProgress(
                        value: freshness,
                        label: last == null ? 'No backup yet' : 'Last backup ${relativeTime(last)}',
                        trailing: days == null ? '—' : (days == 0 ? 'Today' : '${days}d'),
                      ),
                      if (days != null && days > 30) ...[
                        const SizedBox(height: Gap.xs),
                        Text('It has been a while – consider creating a fresh backup.',
                            style: context.tx.caption.copyWith(color: context.ft.warning)),
                      ],
                      const SizedBox(height: Gap.lg),
                      FTButton(
                        label: 'Create backup',
                        icon: AppIcons.backup,
                        expand: true,
                        onTap: () => _createBackup(context, ref),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Gap.xxl),
              const SectionHeader('Restore & move data'),
              FadeSlideIn(
                index: 1,
                child: FTCard(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
                  child: Column(
                    children: [
                      FTListRow(
                        title: 'Restore from a backup',
                        subtitle: 'Open a .ftbackup file – as a new tree or to replace one',
                        icon: AppIcons.restore,
                        onTap: () => context.push(Routes.restore),
                      ),
                      const HairLine(vertical: 2),
                      FTListRow(
                        title: 'Import GEDCOM',
                        subtitle: 'Bring in a family file from Ancestry, MyHeritage, Gramps…',
                        icon: AppIcons.upload,
                        onTap: () => context.push(Routes.gedcomImport),
                      ),
                      const HairLine(vertical: 2),
                      FTListRow(
                        title: 'Export & share',
                        subtitle: 'GEDCOM, JSON, spreadsheet or printable PDF',
                        icon: AppIcons.export,
                        onTap: () => context.push(Routes.export),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Gap.xxl),
              const SectionHeader('Moving to a new phone'),
              const FadeSlideIn(index: 2, child: _MoveSteps()),
              const SizedBox(height: Gap.xxl),
              const SectionHeader('History'),
              history.when(
                loading: () => const Padding(padding: EdgeInsets.all(Gap.xl), child: LoadingView()),
                error: (e, _) => ErrorView(error: e),
                data: (items) => items.isEmpty
                    ? const EmptyState(
                        icon: AppIcons.archive,
                        title: 'No backups yet',
                        message: 'Backups, restores, imports and exports will be listed here.',
                        compact: true,
                      )
                    : _HistoryList(items: items),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _explain(BuildContext context) {
    showFTSheet<void>(
      context,
      title: 'How backups work',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (icon, title, text) in const [
            (AppIcons.archive, 'One file, everything inside',
                'A .ftbackup file holds your trees, people, relationships, events, stories, sources and (optionally) photos.'),
            (AppIcons.lock, 'Optional password',
                'Password-protected backups are encrypted with AES-256. Without the password nobody – including you – can open them.'),
            (AppIcons.shield, 'Checked before restoring',
                'Every file inside a backup carries a checksum. Damaged or altered backups are rejected and nothing on your device changes.'),
            (AppIcons.restore, 'You decide what happens',
                'Restore a backup as a new, separate tree, or explicitly replace one tree. Nothing is overwritten silently.'),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.lg),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconBadge(icon: icon, size: 40),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: ctx.tx.bodyStrong),
                        const SizedBox(height: 2),
                        Text(text, style: ctx.tx.body),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _createBackup(BuildContext context, WidgetRef ref) async {
    final trees = ref.read(treesProvider).value ?? const <FamilyTree>[];
    if (trees.isEmpty) {
      showFTToast(context, 'There is no family tree to back up yet.', error: true);
      return;
    }
    final req = await showFTSheet<BackupRequest>(
      context,
      title: 'Create backup',
      builder: (_) => _CreateBackupForm(
        trees: trees,
        encryptByDefault: ref.read(settingsProvider).encryptBackupsByDefault,
      ),
    );
    if (req == null || !context.mounted) return;
    final service = BackupService(ref.read(databaseProvider), system: ref.read(systemRepoProvider));
    try {
      final result = await runWithProgressSheet<BackupResult>(
        context,
        title: 'Creating backup',
        subtitle: req.encrypted ? 'Encrypted with your password' : null,
        icon: AppIcons.backup,
        task: (progress) => service.createBackup(req, onProgress: progress),
      );
      await ref.read(settingsProvider.notifier).update((p) => p.copyWith(lastBackupAt: DateTime.now()));
      if (!context.mounted) return;
      await showFileReadySheet(
        context,
        title: 'Backup ready',
        path: result.path,
        mimeType: 'application/octet-stream',
        summary: '${result.summary}${result.encrypted ? ' · password protected' : ''}',
        notes: [
          'Store the file somewhere other than this phone – for example send it to yourself or save it to a computer.',
          if (result.missingFiles.isNotEmpty)
            '${result.missingFiles.length} photo file(s) could not be found on this device and were skipped.',
        ],
      );
    } catch (e) {
      if (context.mounted) await showBackupError(context, e, title: 'Backup failed');
    }
  }
}

class _MoveSteps extends StatelessWidget {
  const _MoveSteps();

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    const steps = [
      ('Create a backup', 'Include photos so they move too. A password is recommended.'),
      ('Get the file to your new phone', 'Share it to yourself, save it to a computer or a USB drive.'),
      ('Restore it', 'On the new phone open Family Tales → Backup & restore → Restore from a backup.'),
    ];
    return FTCard(
      child: Column(
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : Gap.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: c.accent.withValues(alpha: 0.6)),
                    ),
                    child: Text('${i + 1}', style: context.tx.label.copyWith(color: c.accent)),
                  ),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(steps[i].$1, style: context.tx.bodyStrong),
                        Text(steps[i].$2, style: context.tx.caption),
                      ],
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

class _HistoryList extends StatefulWidget {
  const _HistoryList({required this.items});
  final List<BackupRecord> items;

  @override
  State<_HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends State<_HistoryList> {
  bool _all = false;

  static (IconData, String) _kind(String k) => switch (k) {
        'backup' => (AppIcons.archive, 'Backup'),
        'restore' => (AppIcons.restore, 'Restore'),
        'import' => (AppIcons.upload, 'Import'),
        'export' => (AppIcons.export, 'Export'),
        _ => (AppIcons.document, k),
      };

  @override
  Widget build(BuildContext context) {
    final shown = _all ? widget.items : widget.items.take(8).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTCard(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
          child: Column(
            children: [
              for (var i = 0; i < shown.length; i++) ...[
                if (i > 0) const HairLine(vertical: Gap.xs),
                _row(context, shown[i]),
              ],
            ],
          ),
        ),
        if (widget.items.length > 8)
          Align(
            alignment: Alignment.centerRight,
            child: FTTextAction(_all ? 'Show less' : 'Show all ${widget.items.length}',
                onTap: () => setState(() => _all = !_all)),
          ),
      ],
    );
  }

  Widget _row(BuildContext context, BackupRecord r) {
    final (icon, label) = _kind(r.kind);
    final meta = [
      label,
      formatDateTime(r.createdAt),
      if (r.sizeBytes > 0) formatBytes(r.sizeBytes),
    ].join(' · ');
    return Semantics(
      label: '$label ${r.fileName}, $meta',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconBadge(icon: icon, size: 38),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.fileName, style: context.tx.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(meta, style: context.tx.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (r.summary != null && r.summary!.isNotEmpty)
                    Text(r.summary!, style: context.tx.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (r.encrypted) ...[
              const SizedBox(width: Gap.xs),
              const FTTag('Locked', icon: AppIcons.lock, accent: true),
            ],
          ],
        ),
      ),
    );
  }
}

class _CreateBackupForm extends StatefulWidget {
  const _CreateBackupForm({required this.trees, required this.encryptByDefault});
  final List<FamilyTree> trees;
  final bool encryptByDefault;

  @override
  State<_CreateBackupForm> createState() => _CreateBackupFormState();
}

class _CreateBackupFormState extends State<_CreateBackupForm> {
  final _form = GlobalKey<FormState>();
  late final Set<String> _trees = {for (final t in widget.trees) t.id};
  bool _media = true;
  bool _settings = false;
  late bool _encrypt = widget.encryptByDefault;
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    super.dispose();
  }

  void _submit() {
    if (_trees.isEmpty) {
      showFTToast(context, 'Choose at least one family tree.', error: true);
      return;
    }
    if (_encrypt && !(_form.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(BackupRequest(
      treeIds: [for (final t in widget.trees) if (_trees.contains(t.id)) t.id],
      includeMedia: _media,
      includeSettings: _settings,
      password: _encrypt ? _pw.text : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Family trees', style: context.tx.label),
          const SizedBox(height: Gap.xs),
          Wrap(
            spacing: Gap.xs,
            runSpacing: Gap.xs,
            children: [
              for (final t in widget.trees)
                FTChip(
                  label: t.name,
                  icon: _trees.contains(t.id) ? AppIcons.check : AppIcons.tree,
                  selected: _trees.contains(t.id),
                  onTap: () => setState(() {
                    if (!_trees.remove(t.id)) _trees.add(t.id);
                  }),
                ),
            ],
          ),
          const SizedBox(height: Gap.lg),
          FTSwitchRow(
            title: 'Include photos & documents',
            subtitle: 'Needed to move photos to another device. Makes the file larger.',
            icon: AppIcons.photos,
            value: _media,
            onChanged: (v) => setState(() => _media = v),
          ),
          FTSwitchRow(
            title: 'Include app preferences',
            subtitle: 'Theme, dashboard and reminder options. Security settings are never included.',
            icon: AppIcons.settings,
            value: _settings,
            onChanged: (v) => setState(() => _settings = v),
          ),
          FTSwitchRow(
            title: 'Protect with a password',
            subtitle: 'AES-256 encryption. Recommended if the file leaves this phone.',
            icon: AppIcons.lock,
            value: _encrypt,
            onChanged: (v) => setState(() => _encrypt = v),
          ),
          if (_encrypt) ...[
            const SizedBox(height: Gap.sm),
            PasswordFields(password: _pw, confirm: _pw2),
          ] else ...[
            const SizedBox(height: Gap.xs),
            Text('Without a password anyone who gets the file can read your family data.',
                style: context.tx.caption.copyWith(color: context.ft.warning)),
          ],
          const SizedBox(height: Gap.xl),
          FTButton(label: 'Create backup', icon: AppIcons.backup, expand: true, onTap: _submit),
        ],
      ),
    );
  }
}
