import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/widgets/widgets.dart';
import 'backup_format.dart';
import 'gedcom/gedcom_importer.dart';
import 'gedcom/gedcom_parser.dart';
import 'isolate_task.dart';
import 'widgets/backup_widgets.dart';
import 'widgets/file_actions.dart';

/// Parsed file + plan, produced in a background isolate.
class _ParsedGedcom {
  const _ParsedGedcom(this.plan, this.program, this.encoding, this.version);
  final GedcomImportPlan plan;
  final String? program;
  final String encoding;
  final String? version;
}

Future<_ParsedGedcom> _parseInBackground(String path, String name, ProgressCallback onProgress) =>
    runInBackground((progress) {
      progress(0.1, 'Reading file…');
      final bytes = File(path).readAsBytesSync();
      progress(0.3, 'Reading GEDCOM records…');
      final doc = GedcomParser.parseBytes(bytes);
      progress(0.6, 'Matching people and families…');
      final plan = GedcomImporter(doc, fileName: name).analyze();
      final head = doc.head;
      final sour = head?.first('SOUR');
      progress(1, 'Ready');
      return _ParsedGedcom(
        plan,
        sour == null ? null : (sour.valueOf('NAME') ?? sour.value),
        doc.encoding,
        head?.first('GEDC')?.valueOf('VERS'),
      );
    }, onProgress: onProgress);

class GedcomImportScreen extends ConsumerStatefulWidget {
  const GedcomImportScreen({super.key});

  @override
  ConsumerState<GedcomImportScreen> createState() => _GedcomImportScreenState();
}

class _GedcomImportScreenState extends ConsumerState<GedcomImportScreen> {
  String? _fileName;
  _ParsedGedcom? _parsed;
  Object? _error;
  final _name = TextEditingController();
  GedcomImportReport? _done;
  String? _doneTreeName;
  bool _showWarnings = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    try {
      final picked = await pickLocalFile(dialogTitle: 'Choose a GEDCOM file (.ged)');
      if (picked == null || !mounted) return;
      final (path, name) = picked;
      setState(() {
        _fileName = name;
        _parsed = null;
        _error = null;
        _done = null;
      });
      final size = await File(path).length();
      if (size > 300 * 1024 * 1024) {
        throw BackupFormatException('This file is too large to import (over 300 MB).');
      }
      if (!mounted) return;
      final parsed = await runWithProgressSheet<_ParsedGedcom>(
        context,
        title: 'Reading GEDCOM',
        subtitle: name,
        icon: AppIcons.upload,
        task: (progress) => _parseInBackground(path, name, progress),
      );
      if (!mounted) return;
      if (parsed.plan.isEmpty) {
        setState(() => _error = BackupFormatException(
              'No people were found in this file.',
              [
                'Make sure it is a GEDCOM (.ged) family tree file.',
                ...parsed.plan.report.warnings.take(10),
              ],
            ));
        return;
      }
      _name.text = parsed.plan.suggestedName;
      setState(() => _parsed = parsed);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _import() async {
    final parsed = _parsed;
    if (parsed == null) return;
    final name = _name.text.trim().isEmpty ? parsed.plan.suggestedName : _name.text.trim();
    try {
      final db = ref.read(databaseProvider);
      final treeId = await runWithProgressSheet<String>(
        context,
        title: 'Importing family',
        subtitle: name,
        icon: AppIcons.upload,
        task: (progress) async {
          progress(0.2, 'Saving ${parsed.plan.report.people} people…');
          final id = await parsed.plan.write(db, treeName: name);
          progress(1, 'Done');
          return id;
        },
      );
      final r = parsed.plan.report;
      await ref.read(systemRepoProvider).logBackup(
            kind: 'import',
            fileName: _fileName ?? 'family.ged',
            summary: 'GEDCOM → “$name” · ${r.people} people, ${r.parentLinks + r.partnerships} relationships'
                '${r.unsupportedTotal > 0 ? ', ${r.unsupportedTotal} unmapped items kept in notes' : ''}',
          );
      await ref.read(settingsProvider.notifier).setActiveTree(treeId);
      if (!mounted) return;
      setState(() {
        _done = r;
        _doneTreeName = name;
        _parsed = null;
      });
    } catch (e) {
      if (mounted) await showBackupError(context, e, title: 'Import failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = context.pagePadding;
    Widget body;
    if (_done != null) {
      body = _success(_done!);
    } else if (_error != null) {
      body = ErrorReportCard.of(_error!,
          title: 'This file can’t be imported',
          actions: [FTButton.secondary(label: 'Choose another file', icon: AppIcons.document, onTap: _pick)]);
    } else if (_parsed != null) {
      body = _preview(_parsed!);
    } else {
      body = _intro();
    }
    return FTPage(
      title: 'Import GEDCOM',
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(pad, Gap.sm, pad, FTPage.bottomInset(context)),
        child: ContentWidth(
          child: FadeSlideIn(key: ValueKey('${body.runtimeType}$_fileName${_done != null}'), child: body),
        ),
      ),
    );
  }

  Widget _intro() => FTCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const IconBadge(icon: AppIcons.upload, size: 52, accent: true),
            const SizedBox(height: Gap.md),
            Text('Import a GEDCOM file', style: context.tx.title),
            const SizedBox(height: Gap.xs),
            Text(
              'GEDCOM (.ged) is the standard family-tree format used by Ancestry, MyHeritage, FamilySearch, '
              'Gramps and most genealogy programs. The file is imported as a new tree – your existing trees '
              'are not changed.',
              style: context.tx.body,
            ),
            const SizedBox(height: Gap.sm),
            Text(
              'Anything Family Tales cannot map is listed before importing and kept word-for-word in the '
              'person’s notes, so no information is lost.',
              style: context.tx.caption,
            ),
            const SizedBox(height: Gap.xl),
            FTButton(label: 'Choose GEDCOM file', icon: AppIcons.document, expand: true, onTap: _pick),
          ],
        ),
      );

  Widget _preview(_ParsedGedcom parsed) {
    final c = context.ft;
    final r = parsed.plan.report;
    final unsupported = r.unsupported.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const IconBadge(icon: AppIcons.document, size: 48, accent: true),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_fileName ?? 'GEDCOM file',
                            style: context.tx.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
                        Text(
                          [
                            if (parsed.program != null) 'From ${parsed.program}',
                            if (parsed.version != null) 'GEDCOM ${parsed.version}',
                            parsed.encoding,
                          ].join(' · '),
                          style: context.tx.caption,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const HairLine(vertical: Gap.lg),
              Wrap(
                spacing: Gap.lg,
                runSpacing: Gap.lg,
                children: [
                  PreviewMetric(value: r.people, label: 'People', icon: AppIcons.people),
                  PreviewMetric(value: r.families, label: 'Families', icon: AppIcons.family),
                  PreviewMetric(value: r.parentLinks, label: 'Parent links', icon: AppIcons.branch),
                  PreviewMetric(value: r.partnerships, label: 'Couples', icon: AppIcons.heart),
                  PreviewMetric(value: r.events, label: 'Events', icon: AppIcons.event),
                  PreviewMetric(value: r.sources, label: 'Sources', icon: AppIcons.source),
                ],
              ),
              if (r.inferredDeceased > 0) ...[
                const SizedBox(height: Gap.md),
                Text(
                  '${r.inferredDeceased} people born more than 110 years ago have no death record and will be marked as deceased.',
                  style: context.tx.caption,
                ),
              ],
            ],
          ),
        ),
        if (unsupported.isNotEmpty) ...[
          const SizedBox(height: Gap.xxl),
          SectionHeader('Kept in notes (${r.unsupportedTotal})'),
          FTCard(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'These GEDCOM items have no matching field. Their original lines are saved under '
                  '“$unmappedNotesHeading” in the person’s notes (or in the tree description for '
                  'records that belong to nobody).',
                  style: context.tx.caption,
                ),
                const SizedBox(height: Gap.sm),
                for (final e in unsupported.take(12))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FTTag('${e.value}×'),
                        const SizedBox(width: Gap.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.key, style: context.tx.label),
                              for (final ex in r.examples[e.key] ?? const <String>[])
                                Text(ex,
                                    style: context.tx.caption,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                if (unsupported.length > 12)
                  Text('…and ${unsupported.length - 12} more kinds', style: context.tx.caption),
              ],
            ),
          ),
        ],
        if (r.skippedMetadata.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          Text(
            'Skipped bookkeeping data: ${r.skippedMetadata.entries.map((e) => '${e.key} (${e.value})').join(', ')}',
            style: context.tx.caption,
          ),
        ],
        if (r.warnings.isNotEmpty) ...[
          const SizedBox(height: Gap.xxl),
          SectionHeader(
            'Warnings (${r.warnings.length})',
            action: _showWarnings ? 'Hide' : 'Show',
            onAction: () => setState(() => _showWarnings = !_showWarnings),
          ),
          if (_showWarnings)
            FTCard(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final w in r.warnings.take(50))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(AppIcons.info, size: 15, color: c.warning),
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
        FTTextField(controller: _name, label: 'Name of the new tree', icon: AppIcons.tree, maxLength: 120),
        const SizedBox(height: Gap.md),
        FTButton(label: 'Import as new tree', icon: AppIcons.upload, expand: true, onTap: _import),
        const SizedBox(height: Gap.sm),
        FTButton.secondary(label: 'Choose another file', expand: true, onTap: _pick),
      ],
    );
  }

  Widget _success(GedcomImportReport r) => FTCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const IconBadge(icon: AppIcons.checkCircle, size: 52, accent: true),
            const SizedBox(height: Gap.md),
            Text('“${_doneTreeName ?? ''}” imported', style: context.tx.title),
            const SizedBox(height: Gap.xs),
            Text(
              '${r.people} people, ${r.parentLinks} parent links, ${r.partnerships} couples, '
              '${r.events} events and ${r.sources} sources were added.',
              style: context.tx.body,
            ),
            if (r.unsupportedTotal > 0) ...[
              const SizedBox(height: Gap.xs),
              Text(
                '${r.unsupportedTotal} unmapped items were kept in notes under “$unmappedNotesHeading”.',
                style: context.tx.caption,
              ),
            ],
            const SizedBox(height: Gap.xl),
            FTButton(label: 'Open family tree', icon: AppIcons.tree, expand: true, onTap: () => context.go(Routes.tree)),
            const SizedBox(height: Gap.sm),
            FTButton.secondary(label: 'Done', expand: true, onTap: () => context.pop()),
          ],
        ),
      );
}
