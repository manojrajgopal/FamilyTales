import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/widgets/widgets.dart';
import '../gallery/media_import.dart';
import '../gallery/media_tools.dart';
import '../gallery/media_widgets.dart';
import '../members/widgets/person_widgets.dart';
import 'story_text.dart';

enum _PhotoSource { gallery, import }

enum _ThumbAction { cover, view, remove }

/// Create or edit a story: title, markdown body with a formatting toolbar,
/// historical date, tags, people, events, photos, source and privacy.
class StoryEditorScreen extends ConsumerStatefulWidget {
  const StoryEditorScreen({super.key, this.storyId, this.personId});
  final String? storyId;

  /// Preselected related person for new stories.
  final String? personId;

  @override
  ConsumerState<StoryEditorScreen> createState() => _StoryEditorScreenState();
}

class _StoryEditorScreenState extends ConsumerState<StoryEditorScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _source = TextEditingController();
  final _bodyFocus = FocusNode();

  FuzzyDate? _date;
  Set<String> _tags = {};
  List<String> _people = [];
  List<String> _events = [];
  List<String> _photos = [];
  /// Photos linked when the story was opened (some may be in the trash).
  Set<String> _savedPhotos = {};
  String? _coverId;
  bool _private = false;

  bool _loaded = false;
  bool _missing = false;
  bool _dirty = false;
  bool _saving = false;

  bool get _isNew => widget.storyId == null;

  @override
  void initState() {
    super.initState();
    _bodyFocus.addListener(() {
      if (mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _source.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_isNew) {
      setState(() {
        if (widget.personId != null) _people = [widget.personId!];
        _loaded = true;
      });
      return;
    }
    final id = widget.storyId!;
    try {
      final stories = await ref.read(storiesProvider.future);
      final people = await ref.read(storyPeopleProvider.future);
      final events = await ref.read(storyEventsProvider.future);
      final media = await ref.read(storyMediaProvider.future);
      final tags = await ref.read(storyTagsProvider.future);
      if (!mounted) return;
      Story? s;
      for (final x in stories) {
        if (x.id == id) s = x;
      }
      setState(() {
        _loaded = true;
        if (s == null) {
          _missing = true;
          return;
        }
        _title.text = s.title;
        _body.text = s.body;
        _source.text = s.sourceText ?? '';
        _date = FuzzyDate.tryParse(s.historicalDate);
        _private = s.isPrivate;
        _coverId = s.coverMediaId;
        _people = [for (final x in people) if (x.storyId == id) x.personId];
        _events = [for (final x in events) if (x.storyId == id) x.eventId];
        final ordered = [for (final x in media) if (x.storyId == id) x]
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
        _photos = [for (final x in ordered) x.mediaId];
        _savedPhotos = _photos.toSet();
        _tags = {for (final x in tags) if (x.storyId == id) x.tagId};
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
    if (_saving) return;
    if (!(_form.currentState?.validate() ?? false)) {
      showFTToast(context, 'Please give the story a title.', error: true);
      return;
    }
    final treeId = ref.read(activeTreeIdProvider);
    if (treeId == null) {
      showFTToast(context, 'Create or choose a family tree first.', error: true);
      return;
    }
    setState(() => _saving = true);
    var leaving = false;
    final repo = ref.read(contentRepoProvider);
    final byId = ref.read(mediaByIdProvider);
    // Keep links to photos that are only in the trash, so restoring them
    // brings them back into the story.
    final photos = [for (final id in _photos) if (byId.containsKey(id) || _savedPhotos.contains(id)) id];
    try {
      final id = await repo.saveStory(
        id: widget.storyId,
        treeId: treeId,
        title: _title.text,
        body: _body.text.trimRight(),
        historicalDate: _date?.serialize(),
        sourceText: _clean(_source.text),
        coverMediaId: photos.contains(_coverId) ? _coverId : null,
        isPrivate: _private,
        personIds: _people,
        eventIds: _events,
        mediaIds: photos,
        tagIds: _tags.toList(),
      );
      if (!mounted) return;
      _dirty = false;
      showFTToast(context, _isNew ? 'Story saved' : 'Changes saved');
      leaving = true;
      if (_isNew) {
        context.pushReplacement(Routes.story(id));
      } else {
        context.pop();
      }
    } catch (e) {
      if (mounted) showFTToast(context, friendlyError(e), error: true);
    } finally {
      // Stay disabled once saved so a late second tap can't save twice.
      if (mounted && !leaving) setState(() => _saving = false);
    }
  }

  Future<void> _leave() async {
    FocusScope.of(context).unfocus();
    if (!_dirty) {
      context.pop();
      return;
    }
    final discard = await showFTConfirm(
      context,
      title: 'Discard changes?',
      message: _isNew ? 'This story hasn’t been saved yet.' : 'Your edits to this story haven’t been saved.',
      confirmLabel: 'Discard',
      cancelLabel: 'Keep writing',
      destructive: true,
    );
    if (discard && mounted) {
      setState(() => _dirty = false);
      context.pop();
    }
  }

  void _format(TextEditingValue Function(TextEditingValue) op) {
    _body.value = op(_body.value);
    if (!_bodyFocus.hasFocus) _bodyFocus.requestFocus();
    _touch();
  }

  Future<void> _newTag() async {
    final name = await showFTTextPrompt(context, title: 'New tag', label: 'Tag', hint: 'e.g. War years', confirmLabel: 'Add tag');
    if (name == null || !mounted) return;
    final treeId = ref.read(activeTreeIdProvider);
    if (treeId == null) return;
    try {
      final id = await ref.read(familyRepoProvider).ensureTag(treeId, name);
      if (!mounted) return;
      setState(() {
        _tags = {..._tags, id};
        _dirty = true;
      });
    } catch (e) {
      if (mounted) showFTToast(context, friendlyError(e), error: true);
    }
  }

  Future<void> _addPhotos() async {
    final src = await showFTOptions<_PhotoSource>(
      context,
      title: 'Add photos',
      options: const [
        FTOption(_PhotoSource.gallery, 'Choose from gallery', icon: AppIcons.photos),
        FTOption(_PhotoSource.import, 'Import new photos', icon: AppIcons.camera, subtitle: 'Camera, photo library or files'),
      ],
    );
    if (src == null || !mounted) return;
    final List<String>? added;
    switch (src) {
      case _PhotoSource.gallery:
        added = await pickMedia(context, title: 'Photos for this story', exclude: _photos.toSet());
      case _PhotoSource.import:
        added = await importPhotosFlow(context, ref);
    }
    if (added == null || added.isEmpty || !mounted) return;
    setState(() {
      _photos = [..._photos, ...added!.where((id) => !_photos.contains(id))];
      _dirty = true;
    });
  }

  Future<void> _thumbActions(MediaAsset m) async {
    final a = await showFTOptions<_ThumbAction>(
      context,
      title: m.displayTitle,
      options: [
        FTOption(_ThumbAction.cover, _coverId == m.id ? 'Cover photo' : 'Use as cover',
            icon: AppIcons.photo, selected: _coverId == m.id),
        const FTOption(_ThumbAction.view, 'View', icon: AppIcons.eye),
        const FTOption(_ThumbAction.remove, 'Remove from story',
            icon: AppIcons.remove, subtitle: 'The photo stays in your gallery'),
      ],
    );
    if (a == null || !mounted) return;
    switch (a) {
      case _ThumbAction.cover:
        setState(() {
          _coverId = m.id;
          _dirty = true;
        });
      case _ThumbAction.view:
        context.push(Routes.media(m.id), extra: List<String>.from(_photos));
      case _ThumbAction.remove:
        setState(() {
          _photos = [..._photos]..remove(m.id);
          if (_coverId == m.id) _coverId = null;
          _dirty = true;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = context.pagePadding;
    Widget body;
    if (!_loaded) {
      body = const LoadingView();
    } else if (_missing) {
      body = const EmptyState(
        icon: AppIcons.story,
        title: 'Story not found',
        message: 'It may have been moved to the trash.',
      );
    } else {
      body = Column(
        children: [
          Expanded(
            child: Form(
              key: _form,
              child: ListView(
                padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, FTPage.bottomInset(context, extra: 40)),
                children: [ContentWidth(maxWidth: 720, child: _fields(context))],
              ),
            ),
          ),
          if (_bodyFocus.hasFocus)
            TextFieldTapRegion(
              child: _FormatBar(
                controller: _body,
                onBold: () => _format((v) => MarkdownEditing.wrap(v, '**')),
                onItalic: () => _format((v) => MarkdownEditing.wrap(v, '_')),
                onHeading: () => _format((v) => MarkdownEditing.linePrefix(v, '## ')),
                onQuote: () => _format((v) => MarkdownEditing.linePrefix(v, '> ')),
                onBullet: () => _format((v) => MarkdownEditing.linePrefix(v, '- ')),
                onDone: () => _bodyFocus.unfocus(),
              ),
            ),
        ],
      );
    }
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: FTPage(
        title: _isNew ? 'New story' : 'Edit story',
        onBack: _leave,
        actions: [
          if (_loaded && !_missing)
            FTIconButton(icon: AppIcons.check, tooltip: 'Save story', accent: true, onTap: _saving ? null : _save),
        ],
        body: body,
      ),
    );
  }

  Widget _fields(BuildContext context) {
    final c = context.ft;
    final allTags = [...ref.watch(tagsProvider).value ?? const <Tag>[]]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final byId = ref.watch(mediaByIdProvider);
    final photos = [for (final id in _photos) if (byId[id] != null) byId[id]!];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTTextField(
          controller: _title,
          label: 'Title',
          hint: 'e.g. How Grandpa crossed the mountains',
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.sentences,
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Please give the story a title' : null,
          onChanged: (_) => _touch(),
        ),
        const SizedBox(height: Gap.sm),
        FTTextField(
          controller: _body,
          focusNode: _bodyFocus,
          label: 'Story',
          hint: 'Write freely. Select text and use the toolbar for bold, italic, headings, quotes and lists.',
          minLines: 10,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          onChanged: (_) => _touch(),
        ),
        const SizedBox(height: Gap.xs),
        Row(
          children: [
            Expanded(
              child: Text(
                _bodyFocus.hasFocus ? 'Formatting tools are above the keyboard' : 'Tap the text to show formatting tools',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.tx.caption,
              ),
            ),
            const SizedBox(width: Gap.sm),
            _WordCount(controller: _body),
          ],
        ),
        const SizedBox(height: Gap.lg),
        FuzzyDateField(
          label: 'When did it happen?',
          value: _date,
          icon: AppIcons.calendar,
          onChanged: (d) => setState(() {
            _date = d;
            _dirty = true;
          }),
        ),
        const SizedBox(height: Gap.xl),
        const SectionHeader('Tags'),
        Wrap(
          spacing: Gap.xs,
          runSpacing: Gap.xs,
          children: [
            for (final t in allTags)
              FTChip(
                label: t.name,
                selected: _tags.contains(t.id),
                onTap: () => setState(() {
                  _tags = _tags.contains(t.id) ? ({..._tags}..remove(t.id)) : {..._tags, t.id};
                  _dirty = true;
                }),
              ),
            FTChip(label: 'New tag', icon: AppIcons.add, selected: false, onTap: _newTag),
          ],
        ),
        const SizedBox(height: Gap.xl),
        const SectionHeader('People in this story'),
        PersonChips(
          ids: _people,
          addLabel: _people.isEmpty ? 'Add people' : 'Add',
          onRemove: (id) => setState(() {
            _people = [..._people]..remove(id);
            _dirty = true;
          }),
          onAdd: () async {
            final r = await pickPeople(context, title: 'People in this story', initial: _people.toSet());
            if (r == null || !mounted) return;
            setState(() {
              _people = r;
              _dirty = true;
            });
          },
        ),
        const SizedBox(height: Gap.xl),
        const SectionHeader('Related events'),
        EventChips(
          ids: _events,
          addLabel: _events.isEmpty ? 'Link events' : 'Add',
          onRemove: (id) => setState(() {
            _events = [..._events]..remove(id);
            _dirty = true;
          }),
          onAdd: () async {
            final r = await pickEvents(context, title: 'Related events', initial: _events.toSet());
            if (r == null || !mounted) return;
            setState(() {
              _events = r;
              _dirty = true;
            });
          },
        ),
        const SizedBox(height: Gap.xl),
        SectionHeader(photos.isEmpty ? 'Photos' : 'Photos · ${photos.length}'),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: photos.length + 1,
            separatorBuilder: (_, _) => const SizedBox(width: Gap.sm),
            itemBuilder: (context, i) {
              if (i == photos.length) {
                return Pressable(
                  onTap: _addPhotos,
                  semanticLabel: 'Add photos',
                  child: Container(
                    width: 96,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(Radii.md),
                      color: c.isDark ? Colors.white.withValues(alpha: 0.04) : c.surfaceHigh,
                      border: Border.all(color: c.borderStrong),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(AppIcons.add, color: c.accent),
                        const SizedBox(height: 4),
                        Text('Add', style: context.tx.caption),
                      ],
                    ),
                  ),
                );
              }
              final m = photos[i];
              final isCover = _coverId == m.id || (_coverId == null && i == 0);
              return SizedBox(
                width: 96,
                child: MediaThumb(
                  media: m,
                  radius: Radii.md,
                  badge: isCover ? 'Cover' : null,
                  onTap: () => _thumbActions(m),
                  onLongPress: () => _thumbActions(m),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: Gap.xl),
        FTTextField(
          controller: _source,
          label: 'Source',
          hint: 'Who told this story, or where it was found',
          icon: AppIcons.source,
          minLines: 1,
          maxLines: 4,
          onChanged: (_) => _touch(),
        ),
        const SizedBox(height: Gap.md),
        FTCard(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
          child: FTSwitchRow(
            title: 'Private story',
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
        FTButton(
          label: _isNew ? 'Save story' : 'Save changes',
          icon: AppIcons.check,
          expand: true,
          loading: _saving,
          onTap: _save,
        ),
      ],
    );
  }
}

class _WordCount extends StatelessWidget {
  const _WordCount({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, v, _) {
        final n = StoryText.wordCount(v.text);
        return Text('$n ${n == 1 ? 'word' : 'words'}',
            maxLines: 1, style: context.tx.caption.copyWith(color: context.ft.text2));
      },
    );
  }
}

/// Formatting toolbar docked above the keyboard while the body is focused.
class _FormatBar extends StatelessWidget {
  const _FormatBar({
    required this.controller,
    required this.onBold,
    required this.onItalic,
    required this.onHeading,
    required this.onQuote,
    required this.onBullet,
    required this.onDone,
  });

  final TextEditingController controller;
  final VoidCallback onBold;
  final VoidCallback onItalic;
  final VoidCallback onHeading;
  final VoidCallback onQuote;
  final VoidCallback onBullet;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final pad = context.pagePadding;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    Widget b(IconData i, String tip, VoidCallback f) =>
        FTIconButton(icon: i, tooltip: tip, size: 40, onTap: f);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c.cardTop, c.cardMid],
        ),
        border: Border(top: BorderSide(color: c.border)),
      ),
      padding: EdgeInsets.fromLTRB(
          pad - 8, 4, pad - 8, 4 + (keyboard ? 0 : MediaQuery.paddingOf(context).bottom)),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  b(AppIcons.bold, 'Bold', onBold),
                  b(AppIcons.italic, 'Italic', onItalic),
                  b(AppIcons.heading, 'Heading', onHeading),
                  b(AppIcons.quote, 'Quote', onQuote),
                  b(AppIcons.bullets, 'Bullet list', onBullet),
                  const SizedBox(width: Gap.xs),
                  _WordCount(controller: controller),
                ],
              ),
            ),
          ),
          FTIconButton(icon: AppIcons.chevronDown, tooltip: 'Hide keyboard', size: 40, onTap: onDone),
        ],
      ),
    );
  }
}
