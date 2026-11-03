import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:printing/printing.dart';

import '../../app/providers.dart';
import '../../core/services/app_paths.dart';
import '../../core/widgets/widgets.dart';
import '../family_tree/layout/tree_layout.dart';
import '../members/widgets/person_widgets.dart';
import 'export/export_data.dart';
import 'export/export_privacy.dart';
import 'export/export_providers.dart';
import 'pdf/pdf_theme.dart';
import 'pdf/profile_pdf.dart';
import 'pdf/tree_pdf.dart';
import 'widgets/backup_widgets.dart';
import 'widgets/file_actions.dart';

/// Offline PDF preview (tree poster or member profile) with share / print.
class PdfPreviewScreen extends ConsumerStatefulWidget {
  const PdfPreviewScreen({super.key, this.kind = 'tree', this.personId});

  /// 'tree' | 'profile'
  final String kind;
  final String? personId;

  @override
  ConsumerState<PdfPreviewScreen> createState() => _PdfPreviewScreenState();
}

class _PdfPreviewScreenState extends ConsumerState<PdfPreviewScreen> {
  late String? _personId = widget.personId;
  TreePdfOptions _options = const TreePdfOptions();
  Uint8List? _bytes;
  String? _bytesKey;
  bool _scaleWarned = false;

  bool get _isProfile => widget.kind == 'profile';

  String _key(String treeId, ExportPrivacy privacy) =>
      '$treeId|$_personId|${_options.hashCode}|${privacy.enabled}|${privacy.hideLivingBirthDates}|'
      '${privacy.hideContactDetails}|${privacy.hidePersonalNotes}|${privacy.excludePrivatePeople}|'
      '${privacy.hidePrivateFieldsAndMedia}';

  Future<String?> _treeId() async {
    if (_isProfile && _personId != null) {
      final person = await ref.read(familyRepoProvider).person(_personId!);
      return person?.treeId;
    }
    return ref.read(activeTreeIdProvider);
  }

  Future<Uint8List> _generate() async {
    final treeId = await _treeId();
    if (treeId == null) throw StateError('This person or tree no longer exists.');
    final privacy = ref.read(exportPrivacyProvider);
    final key = _key(treeId, privacy);
    if (_bytes != null && _bytesKey == key) return _bytes!;
    final db = ref.read(databaseProvider);
    final fonts = await PdfFonts.load();
    final data = await TreeExportData.load(db, treeId, privacy: privacy);
    Uint8List bytes;
    if (_isProfile) {
      final person = data.byId[_personId];
      Uint8List? photo;
      final mid = person?.profileMediaId;
      final media = mid == null ? null : data.mediaById[mid];
      if (media != null) photo = await readPdfImage(media, preferOriginal: true);
      bytes = await buildProfilePdf(data: data, personId: _personId!, fonts: fonts, photo: photo);
    } else {
      final photos = <String, Uint8List>{};
      if (data.people.length <= 400) {
        for (final person in data.people) {
          final m = person.profileMediaId == null ? null : data.mediaById[person.profileMediaId];
          if (m == null) continue;
          final b = await readPdfImage(m);
          if (b != null) photos[person.id] = b;
        }
      }
      final focus = _options.focusId ?? ref.read(homePersonIdProvider) ?? data.tree.homePersonId;
      final opts = TreePdfOptions(
        mode: _options.mode,
        pageSize: _options.pageSize,
        generations: _options.generations,
        focusId: focus,
      );
      final r = await buildTreePdf(data: data, fonts: fonts, options: opts, photos: photos);
      bytes = r.bytes;
      if (r.scale < 0.3 && !_scaleWarned && mounted) {
        _scaleWarned = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            showFTToast(context,
                'This tree is large for ${_options.pageSize.label}. Choose “Fit tree” for readable names.');
          }
        });
      }
    }
    _bytes = bytes;
    _bytesKey = key;
    return bytes;
  }

  String get _fileName {
    final tree = ref.read(activeTreeProvider)?.name ?? 'Family';
    var base = _isProfile ? 'Profile' : '${tree}_tree';
    base = base.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    return '$base.pdf';
  }

  Future<void> _share(BuildContext anchor) async {
    try {
      final bytes = await _generate();
      final dir = AppPaths.I.exportsDir();
      final file = File(p.join(dir.path, _fileName));
      await file.writeAsBytes(bytes, flush: true);
      await ref.read(systemRepoProvider).logBackup(
            kind: 'export',
            fileName: p.basename(file.path),
            sizeBytes: bytes.length,
            summary: _isProfile ? 'PDF profile' : 'PDF family tree',
          );
      if (!anchor.mounted) return;
      final ok = await shareFile(anchor, file.path, mimeType: 'application/pdf');
      if (!ok && anchor.mounted) showFTToast(anchor, 'Sharing is not available on this device.', error: true);
    } catch (e) {
      if (mounted) await showBackupError(context, e, title: 'PDF could not be shared');
    }
  }

  Future<void> _print() async {
    try {
      final bytes = await _generate();
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: _fileName);
    } catch (e) {
      if (mounted) showFTToast(context, 'Printing is not available: ${friendlyError(e)}', error: true);
    }
  }

  Future<void> _saveToDevice() async {
    try {
      final bytes = await _generate();
      final file = File(p.join(AppPaths.I.exportsDir().path, _fileName));
      await file.writeAsBytes(bytes, flush: true);
      final ok = await saveFileToDevice(file.path, mimeType: 'application/pdf');
      if (ok && mounted) showFTToast(context, 'PDF saved');
    } catch (e) {
      if (mounted) showFTToast(context, 'The PDF could not be saved: ${friendlyError(e)}', error: true);
    }
  }

  Future<void> _shareMenu(BuildContext anchor) async {
    final choice = await showFTOptions<String>(context, title: 'PDF', options: const [
      FTOption('share', 'Share', subtitle: 'Send with another app', icon: AppIcons.share),
      FTOption('print', 'Print', subtitle: 'Use a printer or print service', icon: AppIcons.document),
      FTOption('save', 'Save to device', subtitle: 'Choose a folder', icon: AppIcons.download),
    ]);
    if (!mounted || !anchor.mounted) return;
    switch (choice) {
      case 'share':
        await _share(anchor);
      case 'print':
        await _print();
      case 'save':
        await _saveToDevice();
    }
  }

  Future<void> _choosePerson() async {
    final id = await pickPerson(context, title: 'Profile PDF for…');
    if (id != null && mounted) setState(() => _personId = id);
  }

  Future<void> _openOptions() async {
    final result = await showFTSheet<(TreePdfOptions, ExportPrivacy)>(
      context,
      title: 'PDF options',
      builder: (_) => _OptionsSheet(
        options: _options,
        privacy: ref.read(exportPrivacyProvider),
        showTreeOptions: !_isProfile,
      ),
    );
    if (result == null || !mounted) return;
    ref.read(exportPrivacyProvider.notifier).set(result.$2);
    setState(() {
      _options = result.$1;
      _scaleWarned = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final privacy = ref.watch(exportPrivacyProvider);
    final treeId = ref.watch(activeTreeIdProvider);
    final title = _isProfile ? 'Profile PDF' : 'Family tree PDF';
    if (_isProfile && _personId == null) {
      return FTPage(
        title: title,
        body: EmptyState(
          icon: AppIcons.pdf,
          title: 'Choose a family member',
          message: 'Create a printable biography page for one person.',
          actionLabel: 'Choose person',
          onAction: _choosePerson,
        ),
      );
    }
    final previewKey = ValueKey('${treeId ?? ''}|${_personId ?? ''}|${_options.hashCode}|${privacy.hashCode}'
        '${privacy.enabled}${privacy.hideLivingBirthDates}${privacy.hideContactDetails}'
        '${privacy.hidePersonalNotes}${privacy.excludePrivatePeople}${privacy.hidePrivateFieldsAndMedia}');
    return FTPage(
      title: title,
      actions: [
        FTIconButton(icon: AppIcons.sliders, tooltip: 'PDF options', onTap: _openOptions),
        Builder(
          builder: (anchor) => FTIconButton(
            icon: AppIcons.share,
            tooltip: 'Share, print or save',
            accent: true,
            onTap: () => _shareMenu(anchor),
          ),
        ),
      ],
      headerBottom: Padding(
        padding: EdgeInsets.fromLTRB(context.pagePadding, 0, context.pagePadding, Gap.xs),
        child: Wrap(
          spacing: Gap.xs,
          runSpacing: Gap.xs,
          children: [
            if (!_isProfile) FTTag(_options.mode.label, icon: AppIcons.layout),
            if (!_isProfile) FTTag(_options.pageSize.label, icon: AppIcons.fit),
            FTTag(privacy.enabled ? 'Sharing filters on' : 'Complete',
                icon: privacy.enabled ? AppIcons.shield : AppIcons.eye, accent: privacy.enabled),
            if (_isProfile) FTTextAction('Change person', accent: true, onTap: _choosePerson),
          ],
        ),
      ),
      body: PdfPreview(
        key: previewKey,
        build: (_) => _generate(),
        useActions: false,
        allowPrinting: false,
        allowSharing: false,
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
        maxPageWidth: 1000,
        pdfFileName: _fileName,
        scrollViewDecoration: const BoxDecoration(color: Colors.transparent),
        pdfPreviewPageDecoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          boxShadow: c.softShadow,
        ),
        padding: EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, FTPage.bottomInset(context)),
        loadingWidget: const LoadingView(),
        onError: (context, error) => ErrorView(error: error),
      ),
    );
  }
}

class _OptionsSheet extends StatefulWidget {
  const _OptionsSheet({required this.options, required this.privacy, required this.showTreeOptions});
  final TreePdfOptions options;
  final ExportPrivacy privacy;
  final bool showTreeOptions;

  @override
  State<_OptionsSheet> createState() => _OptionsSheetState();
}

class _OptionsSheetState extends State<_OptionsSheet> {
  late TreePdfOptions _o = widget.options;
  late ExportPrivacy _p = widget.privacy;

  static const _modes = [TreeViewMode.full, TreeViewMode.descendants, TreeViewMode.ancestors, TreeViewMode.focus];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTreeOptions) ...[
          Text('Page', style: context.tx.label),
          const SizedBox(height: Gap.xs),
          FTSegmented<TreePdfPageSize>(
            values: TreePdfPageSize.values,
            selected: _o.pageSize,
            labelOf: (v) => v.label,
            onChanged: (v) => setState(() => _o = _o.copyWith(pageSize: v)),
          ),
          const SizedBox(height: Gap.xs),
          Text(_o.pageSize.description, style: context.tx.caption),
          const SizedBox(height: Gap.lg),
          Text('What to show', style: context.tx.label),
          const SizedBox(height: Gap.xs),
          Wrap(
            spacing: Gap.xs,
            runSpacing: Gap.xs,
            children: [
              for (final m in _modes)
                FTChip(
                  label: m.label,
                  selected: _o.mode == m,
                  onTap: () => setState(() => _o = _o.copyWith(mode: m)),
                ),
            ],
          ),
          const SizedBox(height: Gap.xs),
          Text(_o.mode.description, style: context.tx.caption),
          if (_o.mode != TreeViewMode.full) ...[
            const SizedBox(height: Gap.md),
            Row(
              children: [
                Expanded(child: Text('Generations', style: context.tx.bodyStrong)),
                FTStepper(
                  value: _o.generations,
                  min: 1,
                  max: 10,
                  onChanged: (v) => setState(() => _o = _o.copyWith(generations: v)),
                ),
              ],
            ),
          ],
          const HairLine(vertical: Gap.lg),
        ],
        FTSwitchRow(
          title: 'Sharing filters',
          subtitle: _p.enabled ? _p.summary : 'Off – everything is included',
          icon: AppIcons.shield,
          value: _p.enabled,
          onChanged: (v) => setState(() => _p = _p.copyWith(enabled: v)),
        ),
        const SizedBox(height: Gap.xl),
        FTButton(
          label: 'Apply',
          icon: AppIcons.check,
          expand: true,
          onTap: () => Navigator.of(context).pop((_o, _p)),
        ),
      ],
    );
  }
}
