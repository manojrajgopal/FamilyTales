import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../gallery/media_import.dart';
import '../gallery/media_tools.dart';
import '../gallery/media_widgets.dart';

// ================================================================== logic

/// Labels for the stored `fact` keys; free text is shown as typed.
String factLabel(String fact) => switch (fact) {
      'general' => 'General',
      'name' => 'Name',
      'birth' => 'Birth',
      'death' => 'Death',
      'marriage' => 'Marriage',
      'date' => 'Date',
      'place' => 'Place',
      _ => fact.isEmpty ? 'General' : fact[0].toUpperCase() + fact.substring(1),
    };

/// Fact choices offered for an entity type.
List<String> factChoices(String entityType) => switch (entityType) {
      'person' => const ['general', 'name', 'birth', 'death', 'marriage'],
      'event' => const ['general', 'date', 'place'],
      'partnership' => const ['general', 'marriage'],
      _ => const ['general'],
    };

const confidenceLabels = ['Unreliable', 'Questionable', 'Secondary evidence', 'Primary evidence'];

String confidenceLabel(int c) => confidenceLabels[c.clamp(0, 3)];

/// "Birth · p. 12" style summary of a citation.
String citationSummary(Citation c) {
  final d = c.detail?.trim() ?? '';
  return d.isEmpty ? factLabel(c.fact) : '${factLabel(c.fact)} · $d';
}

/// Subtitle line for a source: author · date · repository.
String sourceSubtitle(Source s) {
  final parts = <String>[
    s.type.label,
    if ((s.author ?? '').trim().isNotEmpty) s.author!.trim(),
    ?FuzzyDate.tryParse(s.date)?.format(),
    if ((s.repository ?? '').trim().isNotEmpty) s.repository!.trim(),
  ];
  return parts.join(' · ');
}

/// What a citation points at, resolved against the live data.
class CitationTarget {
  const CitationTarget({required this.label, required this.kind, this.person, this.event, this.route});
  final String label;

  /// 'person' | 'event' | 'partnership'
  final String kind;
  final Person? person;
  final FamilyEvent? event;

  /// Person id to open for person / partnership targets, event id for events.
  final String? route;

  /// Resolves [c] or returns null when the target is missing (e.g. trashed).
  static CitationTarget? resolve(Citation c, FamilyGraph g, Map<String, FamilyEvent> events) {
    switch (c.entityType) {
      case 'person':
        final p = g[c.entityId];
        return p == null ? null : CitationTarget(label: p.displayName, kind: 'person', person: p, route: p.id);
      case 'event':
        final e = events[c.entityId];
        return e == null ? null : CitationTarget(label: e.title, kind: 'event', event: e, route: e.id);
      case 'partnership':
        for (final s in g.couples) {
          if (s.id == c.entityId) {
            final a = g[s.personAId]!, b = g[s.personBId]!;
            return CitationTarget(
              label: '${a.shortName} & ${b.shortName} (${s.type.label.toLowerCase()})',
              kind: 'partnership',
              person: a,
              route: a.id,
            );
          }
        }
        return null;
    }
    return null;
  }
}

// ================================================================ widgets

/// Confidence 0–3 shown as three dots (filled = stronger evidence).
class ConfidenceDots extends StatelessWidget {
  const ConfidenceDots(this.value, {super.key, this.size = 7});
  final int value;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final v = value.clamp(0, 3);
    return Tooltip(
      message: confidenceLabel(v),
      excludeFromSemantics: true,
      child: Semantics(
        label: 'Confidence: ${confidenceLabel(v)}',
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) SizedBox(width: size * 0.6),
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < v ? (v == 0 ? c.danger : c.accent) : Colors.transparent,
                  border: Border.all(color: i < v ? Colors.transparent : (v == 0 ? c.danger : c.borderStrong), width: 1.2),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ========================================================= citation form

class CitationDraft {
  const CitationDraft({required this.fact, this.detail, this.confidence = 2});
  final String fact;
  final String? detail;
  final int confidence;
}

/// Asks which fact a source supports, a page / detail and the confidence.
Future<CitationDraft?> showCitationForm(
  BuildContext context, {
  required String entityType,
  String? subjectLabel,
  CitationDraft? initial,
}) {
  return showFTSheet<CitationDraft>(
    context,
    title: subjectLabel == null ? 'Citation' : 'Evidence for $subjectLabel',
    builder: (_) => _CitationForm(entityType: entityType, initial: initial),
  );
}

class _CitationForm extends StatefulWidget {
  const _CitationForm({required this.entityType, this.initial});
  final String entityType;
  final CitationDraft? initial;

  @override
  State<_CitationForm> createState() => _CitationFormState();
}

class _CitationFormState extends State<_CitationForm> {
  static const _other = '\u0000other';
  final _formKey = GlobalKey<FormState>();
  late final List<String> _choices = factChoices(widget.entityType);
  late String _fact;
  late final TextEditingController _otherCtl;
  late final TextEditingController _detail = TextEditingController(text: widget.initial?.detail ?? '');
  late int _confidence = widget.initial?.confidence ?? 2;

  @override
  void initState() {
    super.initState();
    final f = widget.initial?.fact ?? 'general';
    _fact = _choices.contains(f) ? f : _other;
    _otherCtl = TextEditingController(text: _choices.contains(f) ? '' : f);
  }

  @override
  void dispose() {
    _otherCtl.dispose();
    _detail.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final fact = _fact == _other ? _otherCtl.text.trim() : _fact;
    final d = _detail.text.trim();
    Navigator.of(context).pop(CitationDraft(fact: fact, detail: d.isEmpty ? null : d, confidence: _confidence));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('What does this source support?', style: context.tx.label.copyWith(color: c.text2)),
          const SizedBox(height: Gap.xs),
          Wrap(
            spacing: Gap.xs,
            runSpacing: Gap.xs,
            children: [
              for (final f in _choices)
                FTChip(label: factLabel(f), selected: _fact == f, onTap: () => setState(() => _fact = f)),
              FTChip(label: 'Other…', selected: _fact == _other, onTap: () => setState(() => _fact = _other)),
            ],
          ),
          if (_fact == _other) ...[
            const SizedBox(height: Gap.sm),
            FTTextField(
              controller: _otherCtl,
              label: 'Fact',
              hint: 'e.g. Occupation, Residence',
              autofocus: true,
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Describe the fact' : null,
            ),
          ],
          const SizedBox(height: Gap.md),
          FTTextField(
            controller: _detail,
            label: 'Detail (optional)',
            hint: 'Page, entry number or a short quote',
            icon: AppIcons.note,
            maxLines: 3,
          ),
          const SizedBox(height: Gap.lg),
          Text('How reliable is it?', style: context.tx.label.copyWith(color: c.text2)),
          const SizedBox(height: Gap.xs),
          for (var i = 3; i >= 0; i--)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Semantics(
                selected: _confidence == i,
                child: Pressable(
                  onTap: () => setState(() => _confidence = i),
                  semanticLabel: confidenceLabels[i],
                  scale: 0.985,
                  child: AnimatedContainer(
                    duration: Motion.fast,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: _confidence == i ? c.accent.withValues(alpha: 0.10) : Colors.transparent,
                      borderRadius: BorderRadius.circular(Radii.md),
                      border: Border.all(color: _confidence == i ? c.accent.withValues(alpha: 0.55) : c.border),
                    ),
                    child: Row(
                      children: [
                        ConfidenceDots(i, size: 8),
                        const SizedBox(width: Gap.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(confidenceLabels[i], style: context.tx.bodyStrong),
                              Text(
                                switch (i) {
                                  3 => 'Original record made at the time (certificate, register)',
                                  2 => 'Later copy, index or reliable family record',
                                  1 => 'Hearsay or conflicting information',
                                  _ => 'Doubtful – kept for reference',
                                },
                                style: context.tx.caption,
                              ),
                            ],
                          ),
                        ),
                        if (_confidence == i) Icon(AppIcons.checkCircle, color: c.accent, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: Gap.md),
          FTButton(label: 'Save citation', expand: true, onTap: _save),
        ],
      ),
    );
  }
}

// =========================================================== source form

/// Add / edit a source in a sheet. Returns the source id when saved.
Future<String?> showSourceForm(BuildContext context, {Source? existing}) {
  return showFTSheet<String>(
    context,
    title: existing == null ? 'New source' : 'Edit source',
    builder: (_) => _SourceForm(existing: existing),
  );
}

class _SourceForm extends ConsumerStatefulWidget {
  const _SourceForm({this.existing});
  final Source? existing;

  @override
  ConsumerState<_SourceForm> createState() => _SourceFormState();
}

enum _Attach { file, photo, remove }

class _SourceFormState extends ConsumerState<_SourceForm> {
  final _formKey = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _author = TextEditingController(text: widget.existing?.author ?? '');
  late final _repo = TextEditingController(text: widget.existing?.repository ?? '');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late SourceType _type = widget.existing?.type ?? SourceType.document;
  late FuzzyDate? _date = FuzzyDate.tryParse(widget.existing?.date);
  late String? _mediaId = widget.existing?.mediaId;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _author.dispose();
    _repo.dispose();
    _notes.dispose();
    super.dispose();
  }

  String? _clean(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _pickType() async {
    final t = await showFTOptions<SourceType>(
      context,
      title: 'Type of source',
      options: [
        for (final t in SourceType.values)
          FTOption(t, t.label, icon: AppIcons.forSource(t), selected: t == _type),
      ],
    );
    if (t != null && mounted) setState(() => _type = t);
  }

  Future<void> _attach() async {
    final a = await showFTOptions<_Attach>(
      context,
      title: 'Attach a copy',
      options: [
        const FTOption(_Attach.file, 'Document or scan', icon: AppIcons.document, subtitle: 'PDF, image or any file'),
        const FTOption(_Attach.photo, 'Photo', icon: AppIcons.camera, subtitle: 'Camera or photo library'),
        if (_mediaId != null)
          const FTOption(_Attach.remove, 'Remove attachment',
              icon: AppIcons.close, danger: true, subtitle: 'The file stays in the gallery'),
      ],
    );
    if (a == null || !mounted) return;
    List<String> ids;
    switch (a) {
      case _Attach.file:
        ids = await importFilesFlow(context, ref, kind: null, single: true, dialogTitle: 'Choose a document');
      case _Attach.photo:
        ids = await importPhotosFlow(context, ref, single: true, title: 'Attach a photo');
      case _Attach.remove:
        setState(() => _mediaId = null);
        return;
    }
    if (ids.isNotEmpty && mounted) setState(() => _mediaId = ids.first);
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    final treeId = ref.read(activeTreeIdProvider);
    if (treeId == null) return;
    setState(() => _saving = true);
    try {
      final id = await ref.read(contentRepoProvider).saveSource(
            id: widget.existing?.id,
            treeId: treeId,
            title: _title.text,
            type: _type,
            author: _clean(_author),
            repository: _clean(_repo),
            date: _date?.serialize(),
            notes: _clean(_notes),
            mediaId: _mediaId,
          );
      if (mounted) Navigator.of(context).pop(id);
    } catch (e) {
      if (mounted) {
        showFTToast(context, friendlyError(e), error: true);
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = _mediaId == null ? null : ref.watch(mediaByIdProvider)[_mediaId];
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FTTextField(
            controller: _title,
            label: 'Title',
            hint: 'e.g. Birth certificate of Rosa Keller',
            textInputAction: TextInputAction.next,
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Please give the source a title' : null,
          ),
          const SizedBox(height: Gap.sm),
          FTSelectField(label: 'Type', value: _type.label, icon: AppIcons.forSource(_type), onTap: _pickType),
          const SizedBox(height: Gap.sm),
          FTTextField(
            controller: _author,
            label: 'Author / informant',
            hint: 'Who created or told it',
            icon: AppIcons.person,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: Gap.sm),
          FTTextField(
            controller: _repo,
            label: 'Repository / location',
            hint: 'Archive, parish, family box…',
            icon: AppIcons.archive,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: Gap.sm),
          FuzzyDateField(label: 'Date of the source', value: _date, onChanged: (d) => setState(() => _date = d)),
          const SizedBox(height: Gap.sm),
          FTTextField(controller: _notes, label: 'Notes', hint: 'Transcription, remarks…', minLines: 2, maxLines: 6),
          const SizedBox(height: Gap.md),
          if (media != null)
            FTCard(
              padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
              child: Row(
                children: [
                  SizedBox(width: 52, height: 52, child: MediaThumb(media: media, radius: Radii.sm)),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Attached', style: context.tx.caption),
                        Text(media.displayTitle,
                            maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                      ],
                    ),
                  ),
                  FTIconButton(icon: AppIcons.edit, tooltip: 'Change attachment', size: 40, onTap: _attach),
                ],
              ),
            )
          else
            FTButton.secondary(label: 'Attach a copy', icon: AppIcons.link, expand: true, onTap: _attach),
          const SizedBox(height: Gap.lg),
          FTButton(
            label: widget.existing == null ? 'Add source' : 'Save changes',
            expand: true,
            loading: _saving,
            onTap: _save,
          ),
        ],
      ),
    );
  }
}

// ========================================================= source picker

const _newSource = '\u0000new';

/// Lets the user choose an existing source or create a new one. Returns the
/// source id or null.
Future<String?> pickOrCreateSource(BuildContext context, {String title = 'Choose a source'}) async {
  final r = await showFTSheet<String>(
    context,
    title: title,
    scrollable: false,
    builder: (_) => const _SourcePicker(),
  );
  if (r == _newSource) {
    if (!context.mounted) return null;
    return showSourceForm(context);
  }
  return r;
}

class _SourcePicker extends ConsumerStatefulWidget {
  const _SourcePicker();

  @override
  ConsumerState<_SourcePicker> createState() => _SourcePickerState();
}

class _SourcePickerState extends ConsumerState<_SourcePicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final all = ref.watch(sourcesProvider).value ?? const <Source>[];
    final shown = [
      for (final s in all)
        if (q.isEmpty || '${s.title} ${sourceSubtitle(s)}'.toLowerCase().contains(q)) s,
    ];
    final mq = MediaQuery.of(context);
    return SizedBox(
      height: (mq.size.height - mq.viewInsets.bottom) * 0.72,
      child: Column(
        children: [
          if (all.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.xl, Gap.sm),
              child: FTSearchField(hint: 'Search sources', onChanged: (v) => setState(() => _q = v)),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
            child: FTListRow(
              title: 'Create a new source',
              subtitle: 'Certificate, letter, census record, interview…',
              icon: AppIcons.add,
              onTap: () => Navigator.of(context).pop(_newSource),
            ),
          ),
          Expanded(
            child: shown.isEmpty
                ? EmptyState(
                    icon: AppIcons.source,
                    title: all.isEmpty ? 'No sources yet' : 'No matching sources',
                    compact: true,
                  )
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.xl, mq.padding.bottom + Gap.md),
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final s = shown[i];
                      return FTListRow(
                        title: s.title,
                        subtitle: sourceSubtitle(s),
                        icon: AppIcons.forSource(s.type),
                        onTap: () => Navigator.of(context).pop(s.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ======================================================= shared flows

/// Edits a citation's fact, detail and confidence. The repository has no
/// update call, so the citation is re-created with the new values.
Future<void> editCitationFlow(BuildContext context, WidgetRef ref, Citation c, {String? subjectLabel}) async {
  final draft = await showCitationForm(
    context,
    entityType: c.entityType,
    subjectLabel: subjectLabel,
    initial: CitationDraft(fact: c.fact, detail: c.detail, confidence: c.confidence),
  );
  if (draft == null) return;
  final repo = ref.read(contentRepoProvider);
  try {
    await repo.addCitation(
      sourceId: c.sourceId,
      entityType: c.entityType,
      entityId: c.entityId,
      fact: draft.fact,
      detail: draft.detail,
      confidence: draft.confidence,
    );
    await repo.deleteCitation(c.id);
    if (context.mounted) showFTToast(context, 'Citation updated');
  } catch (e) {
    if (context.mounted) showFTToast(context, friendlyError(e), error: true);
  }
}

/// Confirms and removes a citation, with Undo.
Future<void> removeCitationFlow(BuildContext context, WidgetRef ref, Citation c, {String? subjectLabel}) async {
  final ok = await showFTConfirm(
    context,
    title: 'Remove citation?',
    message: 'The source will no longer be listed as evidence${subjectLabel == null ? '' : ' for $subjectLabel'}. '
        'The source itself is kept.',
    confirmLabel: 'Remove',
    destructive: true,
  );
  if (!ok || !context.mounted) return;
  final repo = ref.read(contentRepoProvider);
  try {
    await repo.deleteCitation(c.id);
    if (context.mounted) {
      showFTToast(
        context,
        'Citation removed',
        actionLabel: 'Undo',
        onAction: () => repo.addCitation(
          sourceId: c.sourceId,
          entityType: c.entityType,
          entityId: c.entityId,
          fact: c.fact,
          detail: c.detail,
          confidence: c.confidence,
        ),
      );
    }
  } catch (e) {
    if (context.mounted) showFTToast(context, friendlyError(e), error: true);
  }
}
