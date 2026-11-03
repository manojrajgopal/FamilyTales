import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/widgets/widgets.dart';
import '../members/widgets/person_widgets.dart';
import 'export/export_privacy.dart';
import 'export/export_providers.dart';
import 'export/export_service.dart';
import 'widgets/backup_widgets.dart';

/// Export the active tree as GEDCOM, JSON, CSV or PDF, optionally with
/// privacy filters for sharing outside the family.
class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  String? _busy;

  ExportService get _service =>
      ExportService(ref.read(databaseProvider), system: ref.read(systemRepoProvider));

  Future<void> _run(String kind, Future<ExportFile> Function(String treeId, ExportPrivacy p) task) async {
    final treeId = ref.read(activeTreeIdProvider);
    if (treeId == null) {
      showFTToast(context, 'Create a family tree first.', error: true);
      return;
    }
    if (_busy != null) return;
    setState(() => _busy = kind);
    try {
      final privacy = ref.read(exportPrivacyProvider);
      final file = await task(treeId, privacy);
      if (!mounted) return;
      setState(() => _busy = null);
      await showFileReadySheet(
        context,
        title: '$kind export ready',
        path: file.path,
        mimeType: file.mimeType,
        summary: file.summary,
        notes: [
          if (privacy.enabled) 'Sharing filters applied: ${privacy.summary.toLowerCase()}.',
        ],
      );
    } catch (e) {
      if (mounted) await showBackupError(context, e, title: 'Export failed');
    } finally {
      if (mounted && _busy != null) setState(() => _busy = null);
    }
  }

  Future<void> _chooseTree() async {
    final trees = ref.read(treesProvider).value ?? const [];
    if (trees.length < 2) return;
    final active = ref.read(activeTreeIdProvider);
    final id = await showFTOptions<String>(context, title: 'Tree to export', options: [
      for (final t in trees) FTOption(t.id, t.name, icon: AppIcons.tree, selected: t.id == active),
    ]);
    if (id != null) await ref.read(settingsProvider.notifier).setActiveTree(id);
  }

  Future<void> _profilePdf() async {
    final id = await pickPerson(context, title: 'Profile PDF for…');
    if (id != null && mounted) context.push(Routes.pdf(kind: 'profile', personId: id));
  }

  @override
  Widget build(BuildContext context) {
    final pad = context.pagePadding;
    final tree = ref.watch(activeTreeProvider);
    final trees = ref.watch(treesProvider).value ?? const [];
    final people = ref.watch(peopleProvider).value?.length;
    final privacy = ref.watch(exportPrivacyProvider);
    final setPrivacy = ref.read(exportPrivacyProvider.notifier).set;

    Widget row(String kind, String title, String subtitle, IconData icon, VoidCallback onTap) => FTListRow(
          title: title,
          subtitle: subtitle,
          icon: icon,
          onTap: _busy == null ? onTap : null,
          trailing: _busy == kind
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: context.ft.accent),
                )
              : null,
        );

    return FTPage(
      title: 'Export & share',
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(pad, Gap.sm, pad, FTPage.bottomInset(context)),
        child: ContentWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FadeSlideIn(
                child: FTCard(
                  onTap: trees.length > 1 ? _chooseTree : null,
                  semanticLabel: 'Tree to export: ${tree?.name ?? 'none'}',
                  child: Row(
                    children: [
                      const IconBadge(icon: AppIcons.tree, size: 48, accent: true),
                      const SizedBox(width: Gap.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(tree?.name ?? 'No family tree', style: context.tx.title,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            Text(people == null ? 'Loading…' : '$people people · exports stay on this device until you share them',
                                style: context.tx.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                      if (trees.length > 1) ...[
                        const SizedBox(width: Gap.xs),
                        FTTextAction('Change', accent: true, onTap: _chooseTree),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Gap.xxl),
              const SectionHeader('Privacy'),
              FadeSlideIn(
                index: 1,
                child: FTCard(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
                  child: Column(
                    children: [
                      FTSwitchRow(
                        title: 'Sharing filters',
                        subtitle: privacy.enabled
                            ? 'For files that leave the family. ${privacy.summary}.'
                            : 'Off – exports are complete. Turn on before sharing publicly.',
                        icon: AppIcons.shield,
                        value: privacy.enabled,
                        onChanged: (v) => setPrivacy(privacy.copyWith(enabled: v)),
                      ),
                      if (privacy.enabled) ...[
                        const HairLine(vertical: 2),
                        FTSwitchRow(
                          title: 'Hide birth dates of living people',
                          value: privacy.hideLivingBirthDates,
                          onChanged: (v) => setPrivacy(privacy.copyWith(hideLivingBirthDates: v)),
                        ),
                        FTSwitchRow(
                          title: 'Hide contact details',
                          subtitle: 'Email, phone and address',
                          value: privacy.hideContactDetails,
                          onChanged: (v) => setPrivacy(privacy.copyWith(hideContactDetails: v)),
                        ),
                        FTSwitchRow(
                          title: 'Hide personal notes',
                          value: privacy.hidePersonalNotes,
                          onChanged: (v) => setPrivacy(privacy.copyWith(hidePersonalNotes: v)),
                        ),
                        FTSwitchRow(
                          title: 'Leave out private people',
                          subtitle: 'People marked as private',
                          value: privacy.excludePrivatePeople,
                          onChanged: (v) => setPrivacy(privacy.copyWith(excludePrivatePeople: v)),
                        ),
                        FTSwitchRow(
                          title: 'Hide private fields, photos & stories',
                          value: privacy.hidePrivateFieldsAndMedia,
                          onChanged: (v) => setPrivacy(privacy.copyWith(hidePrivateFieldsAndMedia: v)),
                        ),
                        FTSwitchRow(
                          title: 'GEDCOM: show living people as “Living”',
                          subtitle: 'No names, dates, places or notes for living relatives',
                          value: privacy.anonymizeLivingInGedcom,
                          onChanged: (v) => setPrivacy(privacy.copyWith(anonymizeLivingInGedcom: v)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Gap.xxl),
              const SectionHeader('Data files'),
              FadeSlideIn(
                index: 2,
                child: FTCard(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
                  child: Column(
                    children: [
                      row('GEDCOM', 'GEDCOM (.ged)', 'Standard format for Ancestry, MyHeritage, Gramps and others',
                          AppIcons.document, () => _run('GEDCOM', _service.gedcom)),
                      const HairLine(vertical: 2),
                      row('JSON', 'JSON (.json)', 'Complete structured data for developers and archives',
                          AppIcons.database, () => _run('JSON', _service.json)),
                      const HairLine(vertical: 2),
                      row('CSV', 'Spreadsheet (.csv)', 'Members with dates, places, parents, partners and children',
                          AppIcons.fields, () => _run('CSV', _service.csv)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Gap.xxl),
              const SectionHeader('Printable PDF'),
              FadeSlideIn(
                index: 3,
                child: FTCard(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
                  child: Column(
                    children: [
                      row('tree', 'Family tree poster', 'The whole tree on one large page – print or share',
                          AppIcons.tree, () => context.push(Routes.pdf(kind: 'tree'))),
                      const HairLine(vertical: 2),
                      row('profile', 'Member profile', 'A biography page for one person',
                          AppIcons.pdf, _profilePdf),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Gap.lg),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(AppIcons.info, size: 16, color: context.ft.text3),
                  const SizedBox(width: Gap.xs),
                  Expanded(
                    child: Text(
                      'To move everything – including photos – to another device, use a backup instead.',
                      style: context.tx.caption,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
