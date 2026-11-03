import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/settings.dart';
import '../../core/database/app_database.dart';
import '../../core/services/app_paths.dart';
import '../../core/widgets/widgets.dart';
import 'backup_service.dart';
import 'widgets/backup_widgets.dart';
import 'widgets/file_actions.dart';

/// Pick → (unlock) → verify → preview → restore as new tree(s) or replace
/// one tree after an explicit destructive confirmation.
class RestoreScreen extends ConsumerStatefulWidget {
  const RestoreScreen({super.key});

  @override
  ConsumerState<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends ConsumerState<RestoreScreen> {
  String? _path;
  String? _name;
  bool _needsPassword = false;
  String? _passwordError;
  final _password = TextEditingController();
  Object? _error;
  BackupInspection? _insp;
  RestoreResult? _done;

  RestoreMode _mode = RestoreMode.asNew;
  Set<String> _selected = {};
  String? _source;
  String? _target;
  bool _restoreSettings = false;

  BackupService get _service =>
      BackupService(ref.read(databaseProvider), system: ref.read(systemRepoProvider));

  @override
  void dispose() {
    _password.dispose();
    _insp?.dispose();
    super.dispose();
  }

  void _reset() {
    _insp?.dispose();
    setState(() {
      _path = null;
      _name = null;
      _needsPassword = false;
      _passwordError = null;
      _password.clear();
      _error = null;
      _insp = null;
      _done = null;
    });
  }

  Future<void> _pick() async {
    try {
      final picked = await pickLocalFile(dialogTitle: 'Choose a Family Tales backup');
      if (picked == null || !mounted) return;
      _reset();
      setState(() {
        _path = picked.$1;
        _name = picked.$2;
      });
      await _inspect();
    } catch (e) {
      if (mounted) showFTToast(context, 'The file could not be opened: ${friendlyError(e)}', error: true);
    }
  }

  Future<void> _inspect({String? password}) async {
    final path = _path;
    if (path == null) return;
    try {
      final insp = await runWithProgressSheet<BackupInspection>(
        context,
        title: 'Checking backup',
        subtitle: _name,
        icon: AppIcons.shield,
        task: (progress) =>
            _service.inspect(path, password: password, displayName: _name, onProgress: progress),
      );
      if (!mounted) {
        await insp.dispose();
        return;
      }
      final trees = insp.manifest.trees;
      final existing = ref.read(treesProvider).value ?? const <FamilyTree>[];
      setState(() {
        _insp = insp;
        _needsPassword = false;
        _passwordError = null;
        _selected = {for (final t in trees) t.id};
        _source = trees.isEmpty ? null : trees.first.id;
        _target = existing.any((t) => t.id == _source)
            ? _source
            : (existing.isEmpty ? null : ref.read(activeTreeIdProvider) ?? existing.first.id);
        _mode = RestoreMode.asNew;
      });
    } on BackupPasswordRequired {
      if (mounted) setState(() => _needsPassword = true);
    } on BackupWrongPassword catch (e) {
      if (mounted) {
        setState(() {
          _needsPassword = true;
          _passwordError = e.message;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _restore() async {
    final insp = _insp;
    if (insp == null) return;
    final trees = ref.read(treesProvider).value ?? const <FamilyTree>[];
    RestoreRequest req;
    if (_mode == RestoreMode.asNew) {
      if (_selected.isEmpty) {
        showFTToast(context, 'Choose at least one tree to restore.', error: true);
        return;
      }
      req = RestoreRequest.asNew(treeIds: _selected.toList(), restoreSettings: _restoreSettings);
    } else {
      final target = trees.where((t) => t.id == _target).firstOrNull;
      final source = insp.manifest.trees.where((t) => t.id == _source).firstOrNull;
      if (target == null || source == null) {
        showFTToast(context, 'Choose the tree to replace.', error: true);
        return;
      }
      final ok = await showFTConfirm(
        context,
        title: 'Replace “${target.name}”?',
        message: 'Everything in “${target.name}” on this device – people, relationships, photos, '
            'stories and its trash – will be permanently deleted and replaced with '
            '“${source.name}” from the backup (${insp.treePeople[source.id] ?? 0} people). '
            'This cannot be undone. Consider creating a backup first.',
        confirmLabel: 'Replace tree',
        destructive: true,
      );
      if (!ok || !mounted) return;
      req = RestoreRequest.replace(
          sourceTreeId: source.id, targetTreeId: target.id, restoreSettings: _restoreSettings);
    }
    try {
      final result = await runWithProgressSheet<RestoreResult>(
        context,
        title: _mode == RestoreMode.asNew ? 'Restoring backup' : 'Replacing tree',
        subtitle: insp.fileName,
        icon: AppIcons.restore,
        task: (progress) => _service.restore(insp, req, onProgress: progress),
      );
      final notifier = ref.read(settingsProvider.notifier);
      if (result.settings.isNotEmpty) {
        await notifier.update((p) => AppPrefs.fromMap({...p.toMap(), ...result.settings}));
      }
      if (result.treeIds.isNotEmpty) await notifier.setActiveTree(result.treeIds.first);
      await insp.dispose();
      if (!mounted) return;
      setState(() {
        _insp = null;
        _done = result;
      });
      showFTToast(context, 'Restore complete');
    } catch (e) {
      if (mounted) await showBackupError(context, e, title: 'Restore failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = context.pagePadding;
    Widget body;
    if (_done != null) {
      body = _successCard(_done!);
    } else if (_error != null) {
      body = ErrorReportCard.of(_error!, actions: [
        FTButton.secondary(label: 'Choose another file', icon: AppIcons.archive, onTap: _pick),
      ]);
    } else if (_needsPassword) {
      body = _passwordCard();
    } else if (_insp != null) {
      body = _preview(_insp!);
    } else {
      body = _intro();
    }
    return FTPage(
      title: 'Restore backup',
      actions: [
        if (_path != null)
          FTIconButton(icon: AppIcons.refresh, tooltip: 'Choose another file', onTap: _pick),
      ],
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(pad, Gap.sm, pad, FTPage.bottomInset(context)),
        child: ContentWidth(child: FadeSlideIn(key: ValueKey(body.runtimeType.toString() + (_name ?? '')), child: body)),
      ),
    );
  }

  Widget _intro() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const IconBadge(icon: AppIcons.restore, size: 52, accent: true),
              const SizedBox(height: Gap.md),
              Text('Restore a backup', style: context.tx.title),
              const SizedBox(height: Gap.xs),
              Text(
                'Choose a .ftbackup file. It is checked first and you will see what is inside '
                'before anything on this device changes.',
                style: context.tx.body,
              ),
              const SizedBox(height: Gap.xl),
              FTButton(label: 'Choose backup file', icon: AppIcons.archive, expand: true, onTap: _pick),
            ],
          ),
        ),
        const SizedBox(height: Gap.lg),
        _hint(AppIcons.shield, 'Nothing is overwritten silently',
            'By default a backup is added as a new, separate tree. Replacing a tree always asks first.'),
        _hint(AppIcons.lock, 'Password-protected backups',
            'You will be asked for the password that was chosen when the backup was created.'),
      ],
    );
  }

  Widget _hint(IconData icon, String title, String text) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconBadge(icon: icon, size: 38),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: context.tx.bodyStrong),
                  Text(text, style: context.tx.caption),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _passwordCard() {
    return FTCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const IconBadge(icon: AppIcons.lock, size: 52, accent: true),
          const SizedBox(height: Gap.md),
          Text('This backup is password-protected', style: context.tx.title),
          const SizedBox(height: Gap.xxs),
          Text(_name ?? '', style: context.tx.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: Gap.lg),
          FTTextField(
            controller: _password,
            label: 'Password',
            icon: AppIcons.key,
            obscure: true,
            autofocus: true,
            textCapitalization: TextCapitalization.none,
            onSubmitted: (_) => _unlock(),
          ),
          if (_passwordError != null) ...[
            const SizedBox(height: Gap.xs),
            Text(_passwordError!, style: context.tx.caption.copyWith(color: context.ft.danger)),
          ],
          const SizedBox(height: Gap.lg),
          FTButton(label: 'Unlock', icon: AppIcons.key, expand: true, onTap: _unlock),
          const SizedBox(height: Gap.sm),
          FTButton.secondary(label: 'Choose another file', expand: true, onTap: _pick),
        ],
      ),
    );
  }

  void _unlock() {
    if (_password.text.isEmpty) {
      setState(() => _passwordError = 'Enter the backup password.');
      return;
    }
    _inspect(password: _password.text);
  }

  Widget _preview(BackupInspection insp) {
    final c = context.ft;
    final m = insp.manifest;
    final n = insp.counts;
    final existing = ref.watch(treesProvider).value ?? const <FamilyTree>[];
    final targetTree = existing.where((t) => t.id == _target).firstOrNull;
    final sourceTree = m.trees.where((t) => t.id == _source).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const IconBadge(icon: AppIcons.archive, size: 48, accent: true),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(insp.fileName, style: context.tx.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
                        Text('Created ${formatDateTime(m.createdAt)} · ${formatBytes(insp.sizeBytes)}',
                            style: context.tx.caption),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gap.md),
              Wrap(
                spacing: Gap.xs,
                runSpacing: Gap.xs,
                children: [
                  const FTTag('Verified', icon: AppIcons.checkCircle, accent: true),
                  if (insp.encrypted) const FTTag('Encrypted', icon: AppIcons.lock),
                  FTTag(m.includesMedia ? 'With photos' : 'Without photos', icon: AppIcons.photos),
                  FTTag('App ${m.appVersion}', icon: AppIcons.info),
                ],
              ),
              const HairLine(vertical: Gap.lg),
              Wrap(
                spacing: Gap.lg,
                runSpacing: Gap.lg,
                children: [
                  PreviewMetric(value: n.trees, label: n.trees == 1 ? 'Tree' : 'Trees', icon: AppIcons.tree),
                  PreviewMetric(value: n.people, label: 'People', icon: AppIcons.people),
                  PreviewMetric(value: n.relationships, label: 'Relationships', icon: AppIcons.heart),
                  PreviewMetric(value: n.photos, label: 'Photos', icon: AppIcons.photos),
                  PreviewMetric(value: n.events, label: 'Events', icon: AppIcons.event),
                  PreviewMetric(value: n.stories, label: 'Stories', icon: AppIcons.story),
                  PreviewMetric(value: n.sources, label: 'Sources', icon: AppIcons.source),
                  PreviewMetric(value: n.albums, label: 'Albums', icon: AppIcons.album),
                ],
              ),
            ],
          ),
        ),
        if (insp.warnings.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          FTCard(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final w in insp.warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(AppIcons.info, size: 16, color: c.warning),
                        const SizedBox(width: Gap.xs),
                        Expanded(child: Text(w, style: context.tx.caption)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: Gap.xxl),
        const SectionHeader('How should it be restored?'),
        FTSegmented<RestoreMode>(
          values: RestoreMode.values,
          selected: _mode,
          labelOf: (v) => v == RestoreMode.asNew ? 'As new tree' : 'Replace a tree',
          onChanged: (v) => setState(() => _mode = v),
        ),
        const SizedBox(height: Gap.md),
        if (_mode == RestoreMode.asNew) ...[
          Text(
            'The backup is added as separate tree(s) with fresh identifiers. Your current trees stay exactly as they are.',
            style: context.tx.body,
          ),
          const SizedBox(height: Gap.md),
          FTCard(
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
            child: Column(
              children: [
                for (final t in m.trees)
                  if (m.trees.length == 1)
                    FTListRow(
                      title: t.name,
                      subtitle: '${insp.treePeople[t.id] ?? t.people} people',
                      icon: AppIcons.tree,
                      trailing: Icon(AppIcons.checkCircle, color: c.accent, size: 22),
                    )
                  else
                    FTSwitchRow(
                      title: t.name,
                      subtitle: '${insp.treePeople[t.id] ?? t.people} people',
                      icon: AppIcons.tree,
                      value: _selected.contains(t.id),
                      onChanged: (v) => setState(() => v ? _selected.add(t.id) : _selected.remove(t.id)),
                    ),
              ],
            ),
          ),
        ] else ...[
          if (existing.isEmpty)
            Text('There is no tree on this device to replace. Restore as a new tree instead.',
                style: context.tx.body)
          else ...[
            if (m.trees.length > 1) ...[
              FTSelectField(
                label: 'Tree from the backup',
                value: sourceTree?.name,
                icon: AppIcons.archive,
                onTap: () async {
                  final v = await showFTOptions<String>(context, title: 'Tree from the backup', options: [
                    for (final t in m.trees)
                      FTOption(t.id, t.name,
                          subtitle: '${insp.treePeople[t.id] ?? t.people} people', selected: t.id == _source),
                  ]);
                  if (v != null) setState(() => _source = v);
                },
              ),
              const SizedBox(height: Gap.sm),
            ],
            FTSelectField(
              label: 'Tree to replace on this device',
              value: targetTree?.name,
              icon: AppIcons.tree,
              onTap: () async {
                final v = await showFTOptions<String>(context, title: 'Tree to replace', options: [
                  for (final t in existing) FTOption(t.id, t.name, selected: t.id == _target),
                ]);
                if (v != null) setState(() => _target = v);
              },
            ),
            const SizedBox(height: Gap.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(AppIcons.warning, size: 18, color: c.danger),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                    targetTree == null
                        ? 'Choose which tree to replace.'
                        : 'Everything currently in “${targetTree.name}” will be deleted and replaced. '
                            'You will be asked to confirm.',
                    style: context.tx.caption.copyWith(color: c.danger),
                  ),
                ),
              ],
            ),
          ],
        ],
        if (insp.hasSettings) ...[
          const SizedBox(height: Gap.md),
          FTSwitchRow(
            title: 'Also restore app preferences',
            subtitle: 'Theme, dashboard and reminder options. Security settings stay as they are.',
            icon: AppIcons.settings,
            value: _restoreSettings,
            onChanged: (v) => setState(() => _restoreSettings = v),
          ),
        ],
        const SizedBox(height: Gap.xl),
        FTButton(
          label: _mode == RestoreMode.asNew ? 'Restore' : 'Replace tree',
          icon: _mode == RestoreMode.asNew ? AppIcons.restore : AppIcons.warning,
          kind: _mode == RestoreMode.asNew ? FTButtonKind.primary : FTButtonKind.danger,
          expand: true,
          onTap: (_mode == RestoreMode.replace && (existing.isEmpty || targetTree == null)) ? null : _restore,
        ),
      ],
    );
  }

  Widget _successCard(RestoreResult r) {
    return FTCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const IconBadge(icon: AppIcons.checkCircle, size: 52, accent: true),
          const SizedBox(height: Gap.md),
          Text('Your family is back', style: context.tx.title),
          const SizedBox(height: Gap.xs),
          Text(r.summary, style: context.tx.body),
          if (r.missingMedia > 0) ...[
            const SizedBox(height: Gap.xs),
            Text('${r.missingMedia} photo record(s) had no file in the backup.',
                style: context.tx.caption.copyWith(color: context.ft.warning)),
          ],
          if (r.settings.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text('App preferences were restored.', style: context.tx.caption),
          ],
          const SizedBox(height: Gap.xl),
          FTButton(
            label: 'Open family tree',
            icon: AppIcons.tree,
            expand: true,
            onTap: () => context.go(Routes.tree),
          ),
          const SizedBox(height: Gap.sm),
          FTButton.secondary(label: 'Done', expand: true, onTap: () => context.pop()),
        ],
      ),
    );
  }
}
