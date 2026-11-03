import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/widgets/widgets.dart';
import '../members/widgets/person_widgets.dart';
import 'crop_editor.dart';
import 'media_tools.dart';
import 'media_widgets.dart';
import 'photo_actions.dart';

/// Edit a photo's (or document's) details: caption, description, historical
/// date, place, category, tagged people and linked events; rotate and crop
/// images; move to trash.
class MediaEditScreen extends ConsumerStatefulWidget {
  const MediaEditScreen({super.key, required this.mediaId});
  final String mediaId;

  @override
  ConsumerState<MediaEditScreen> createState() => _MediaEditScreenState();
}

class _MediaEditScreenState extends ConsumerState<MediaEditScreen> {
  final _form = GlobalKey<FormState>();
  final _caption = TextEditingController();
  final _desc = TextEditingController();
  final _location = TextEditingController();
  FuzzyDate? _date;
  String? _category;
  bool _private = false;
  List<String> _people = [];
  List<String> _events = [];

  bool _loaded = false;
  bool _missing = false;
  bool _dirty = false;
  bool _busy = false;
  bool _saving = false;

  /// Bumped after rotate / crop so the preview re-reads the file.
  int _rev = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _caption.dispose();
    _desc.dispose();
    _location.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(contentRepoProvider);
    try {
      final m = await repo.mediaAsset(widget.mediaId);
      final people = await ref.read(mediaPeopleProvider.future);
      final events = await ref.read(mediaEventsProvider.future);
      if (!mounted) return;
      setState(() {
        _loaded = true;
        if (m == null || m.deletedAt != null) {
          _missing = true;
          return;
        }
        _caption.text = m.caption ?? '';
        _desc.text = m.description ?? '';
        _location.text = m.location ?? '';
        _date = m.fuzzyDate;
        _category = (m.category?.trim().isEmpty ?? true) ? null : m.category!.trim();
        _private = m.isPrivate;
        _people = [for (final r in people) if (r.mediaId == m.id) r.personId];
        _events = [for (final r in events) if (r.mediaId == m.id) r.eventId];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _missing = true;
      });
      showFTToast(context, friendlyError(e), error: true);
    }
  }

  void _touch() {
    if (!_dirty) setState(() => _dirty = true);
  }

  String? _clean(String s) => s.trim().isEmpty ? null : s.trim();

  Future<void> _save() async {
    if (_saving || !(_form.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final repo = ref.read(contentRepoProvider);
    try {
      await repo.updateMedia(
        widget.mediaId,
        MediaAssetsCompanion(
          caption: Value(_clean(_caption.text)),
          description: Value(_clean(_desc.text)),
          date: Value(_date?.serialize()),
          location: Value(_clean(_location.text)),
          category: Value(_category),
          isPrivate: Value(_private),
        ),
      );
      await repo.setMediaPeople(widget.mediaId, _people);
      await repo.setMediaEvents(widget.mediaId, _events);
      if (!mounted) return;
      _dirty = false;
      showFTToast(context, 'Details saved');
      context.pop();
    } catch (e) {
      if (mounted) showFTToast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _leave() async {
    if (!_dirty) {
      context.pop();
      return;
    }
    final discard = await showFTConfirm(
      context,
      title: 'Discard changes?',
      message: 'Your edits to the details haven’t been saved.',
      confirmLabel: 'Discard',
      cancelLabel: 'Keep editing',
      destructive: true,
    );
    if (discard && mounted) {
      setState(() => _dirty = false);
      context.pop();
    }
  }

  Future<void> _rotate() async {
    if (_busy) return;
    setState(() => _busy = true);
    final repo = ref.read(contentRepoProvider);
    try {
      final m = await repo.mediaAsset(widget.mediaId);
      if (m == null) return;
      await repo.rotateMedia(m);
      evictImageCache();
      _rev++;
    } catch (e) {
      if (mounted) showFTToast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _crop() async {
    if (_busy) return;
    final repo = ref.read(contentRepoProvider);
    final m = await repo.mediaAsset(widget.mediaId);
    if (m == null || !mounted) return;
    final rect = await showCropEditor(context, m);
    if (rect == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await repo.cropMedia(m, rect.left.round(), rect.top.round(), rect.width.round(), rect.height.round());
      evictImageCache();
      _rev++;
      if (mounted) showFTToast(context, 'Photo cropped');
    } catch (e) {
      if (mounted) showFTToast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickCategory(List<MediaAsset> all) async {
    const custom = '\u0000custom';
    final r = await showFTOptions<String>(
      context,
      title: 'Category',
      options: [
        for (final c in categoryChoices(all))
          FTOption(c, c, icon: AppIcons.tag, selected: _category?.toLowerCase() == c.toLowerCase()),
        const FTOption(custom, 'Custom category…', icon: AppIcons.add),
      ],
    );
    if (r == null || !mounted) return;
    var value = r;
    if (r == custom) {
      final typed = await showFTTextPrompt(context, title: 'Custom category', label: 'Category', initial: _category);
      if (typed == null) return;
      value = typed;
    }
    setState(() {
      _category = value.trim();
      _dirty = true;
    });
  }

  Future<void> _delete(MediaAsset m) async {
    final done = await trashMediaFlow(context, ref, m);
    if (done && mounted) {
      _dirty = false;
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = ref.watch(mediaByIdProvider)[widget.mediaId];
    final all = ref.watch(mediaProvider).value ?? const <MediaAsset>[];
    final pad = context.pagePadding;
    Widget body;
    if (!_loaded) {
      body = const LoadingView();
    } else if (_missing || media == null) {
      body = const EmptyState(
        icon: AppIcons.photo,
        title: 'Not found',
        message: 'This item may have been moved to the trash.',
      );
    } else {
      final isPhoto = media.kind == MediaKind.photo;
      body = Form(
        key: _form,
        child: ListView(
          padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, FTPage.bottomInset(context)),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            ContentWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Preview(
                    media: media,
                    rev: _rev,
                    busy: _busy,
                    onRotate: media.isImage ? _rotate : null,
                    onCrop: media.isImage ? _crop : null,
                  ),
                  const SizedBox(height: Gap.xl),
                  const SectionHeader('Details'),
                  const SizedBox(height: Gap.xs),
                  FTTextField(
                    controller: _caption,
                    label: isPhoto ? 'Caption' : 'Name',
                    hint: isPhoto ? 'e.g. Grandma’s 80th birthday' : 'e.g. Birth certificate',
                    icon: AppIcons.note,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => _touch(),
                  ),
                  const SizedBox(height: Gap.sm),
                  FTTextField(
                    controller: _desc,
                    label: 'Description',
                    hint: 'Who, where, what happened…',
                    minLines: 3,
                    maxLines: 8,
                    onChanged: (_) => _touch(),
                  ),
                  const SizedBox(height: Gap.sm),
                  FuzzyDateField(
                    label: isPhoto ? 'Date taken' : 'Date',
                    value: _date,
                    onChanged: (d) => setState(() {
                      _date = d;
                      _dirty = true;
                    }),
                  ),
                  const SizedBox(height: Gap.sm),
                  FTTextField(
                    controller: _location,
                    label: 'Place',
                    hint: 'Town, venue or address',
                    icon: AppIcons.location,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => _touch(),
                  ),
                  if (isPhoto) ...[
                    const SizedBox(height: Gap.sm),
                    FTSelectField(
                      label: 'Category',
                      value: _category,
                      icon: AppIcons.tag,
                      placeholder: 'None',
                      onTap: () => _pickCategory(all),
                      onClear: () => setState(() {
                        _category = null;
                        _dirty = true;
                      }),
                    ),
                  ],
                  const SizedBox(height: Gap.xl),
                  SectionHeader(isPhoto ? 'People in this photo' : 'People mentioned'),
                  const SizedBox(height: Gap.xs),
                  PersonChips(
                    ids: _people,
                    addLabel: _people.isEmpty ? 'Tag people' : 'Add',
                    onRemove: (id) => setState(() {
                      _people = [..._people]..remove(id);
                      _dirty = true;
                    }),
                    onAdd: () async {
                      final r = await pickPeople(context, title: 'Tag people', initial: _people.toSet());
                      if (r == null || !mounted) return;
                      setState(() {
                        _people = r;
                        _dirty = true;
                      });
                    },
                  ),
                  const SizedBox(height: Gap.xl),
                  const SectionHeader('Linked events'),
                  const SizedBox(height: Gap.xs),
                  EventChips(
                    ids: _events,
                    addLabel: _events.isEmpty ? 'Link events' : 'Add',
                    onRemove: (id) => setState(() {
                      _events = [..._events]..remove(id);
                      _dirty = true;
                    }),
                    onAdd: () async {
                      final r = await pickEvents(context, initial: _events.toSet());
                      if (r == null || !mounted) return;
                      setState(() {
                        _events = r;
                        _dirty = true;
                      });
                    },
                  ),
                  const SizedBox(height: Gap.lg),
                  FTCard(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
                    child: FTSwitchRow(
                      title: 'Private',
                      subtitle: 'Leave out of shared exports and reports',
                      icon: AppIcons.lock,
                      value: _private,
                      onChanged: (v) => setState(() {
                        _private = v;
                        _dirty = true;
                      }),
                    ),
                  ),
                  const SizedBox(height: Gap.xl),
                  FTButton(label: 'Save details', icon: AppIcons.check, expand: true, loading: _saving, onTap: _save),
                  const SizedBox(height: Gap.sm),
                  FTButton(
                    label: 'Move to trash',
                    icon: AppIcons.trash,
                    kind: FTButtonKind.danger,
                    expand: true,
                    onTap: () => _delete(media),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: FTPage(
        title: media?.kind == MediaKind.document ? 'Edit document' : 'Edit photo',
        onBack: _leave,
        actions: [
          if (media != null && !_missing)
            FTIconButton(icon: AppIcons.check, tooltip: 'Save', accent: true, onTap: _saving ? null : _save),
        ],
        body: body,
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({
    required this.media,
    required this.rev,
    required this.busy,
    required this.onRotate,
    required this.onCrop,
  });

  final MediaAsset media;
  final int rev;
  final bool busy;
  final VoidCallback? onRotate;
  final VoidCallback? onCrop;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final w = media.width, h = media.height;
    final ratio = (w != null && h != null && h > 0) ? (w / h).clamp(0.6, 1.9) : 4 / 3;
    return FTCard(
      padding: const EdgeInsets.all(Gap.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.md),
            child: AspectRatio(
              aspectRatio: media.isImage ? ratio.toDouble() : 2.2,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Colors.black),
                  if (media.isImage)
                    LayoutBuilder(builder: (context, cons) {
                      return Image.file(
                        File(media.absolutePath),
                        key: ValueKey('${media.thumbPath}-$rev'),
                        fit: BoxFit.contain,
                        cacheWidth: (cons.maxWidth * dpr).round().clamp(200, 2000),
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => MediaPlaceholder(icon: media.kindIcon),
                      );
                    })
                  else
                    MediaPlaceholder(icon: media.kindIcon, label: media.originalName),
                  if (busy)
                    const ColoredBox(color: Color(0x88000000), child: LoadingView()),
                ],
              ),
            ),
          ),
          if (onRotate != null || onCrop != null) ...[
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                if (onRotate != null)
                  Expanded(
                    child: FTButton.secondary(
                      label: 'Rotate',
                      icon: AppIcons.rotate,
                      height: 46,
                      expand: true,
                      onTap: busy ? null : onRotate,
                    ),
                  ),
                if (onRotate != null && onCrop != null) const SizedBox(width: Gap.sm),
                if (onCrop != null)
                  Expanded(
                    child: FTButton.secondary(
                      label: 'Crop',
                      icon: AppIcons.crop,
                      height: 46,
                      expand: true,
                      onTap: busy ? null : onCrop,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text('Rotate and crop change the photo file right away.',
                textAlign: TextAlign.center, style: context.tx.caption),
          ],
        ],
      ),
    );
  }
}
