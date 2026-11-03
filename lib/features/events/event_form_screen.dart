import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/repositories/family_repository.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../gallery/media_import.dart';
import '../members/widgets/person_widgets.dart';
import 'event_actions.dart';
import 'event_widgets.dart';

/// Create or edit a family event: type, fuzzy date, place, people with
/// roles, yearly reminder and photos.
class EventFormScreen extends ConsumerStatefulWidget {
  const EventFormScreen({super.key, this.eventId, this.personId});
  final String? eventId;

  /// Pre-selected participant when adding from a person's profile.
  final String? personId;

  @override
  ConsumerState<EventFormScreen> createState() => _EventFormScreenState();
}

class _EventFormScreenState extends ConsumerState<EventFormScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _custom = TextEditingController();
  final _location = TextEditingController();
  final _description = TextEditingController();

  EventType _type = EventType.custom;
  FuzzyDate? _date;
  bool _remind = false;

  /// Participants in display order → optional role.
  final Map<String, String?> _people = {};
  final Set<String> _mediaIds = {};
  bool _importAfterSave = false;

  FamilyEvent? _original;
  bool _loading = true;
  bool _missing = false;
  bool _saving = false;
  String? _snapshot;

  bool get _isEdit => widget.eventId != null;
  bool get _canRemind => _date?.hasMonthDay ?? false;
  bool get _dirty => _snapshot != null && _snapshot != _currentSnapshot();

  @override
  void initState() {
    super.initState();
    if (_isEdit) {
      _load();
    } else {
      final pid = widget.personId;
      if (pid != null && pid.isNotEmpty) _people[pid] = null;
      _loading = false;
      _snapshot = _currentSnapshot();
    }
  }

  @override
  void dispose() {
    for (final c in [_title, _custom, _location, _description]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final id = widget.eventId!;
      final ev = await ref.read(contentRepoProvider).watchEvent(id).first;
      final people = await ref.read(eventPeopleProvider.future);
      final links = await ref.read(mediaEventsProvider.future);
      if (!mounted) return;
      if (ev == null || ev.deletedAt != null) {
        setState(() {
          _missing = true;
          _loading = false;
        });
        return;
      }
      setState(() {
        _original = ev;
        _title.text = ev.title;
        _type = ev.type;
        _custom.text = ev.customLabel ?? '';
        _date = FuzzyDate.tryParse(ev.date);
        _location.text = ev.location ?? '';
        _description.text = ev.description ?? '';
        _remind = ev.remind;
        for (final p in people) {
          if (p.eventId == id) _people[p.personId] = p.role;
        }
        _mediaIds.addAll([for (final l in links) if (l.eventId == id) l.mediaId]);
        _loading = false;
        _snapshot = _currentSnapshot();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _missing = true;
        _loading = false;
      });
    }
  }

  String _currentSnapshot() => [
        _title.text.trim(),
        _type.name,
        _custom.text.trim(),
        _date?.serialize() ?? '',
        _location.text.trim(),
        _description.text.trim(),
        _remind && _canRemind,
        [for (final e in _people.entries) '${e.key}=${e.value?.trim() ?? ''}'].join(','),
        (_mediaIds.toList()..sort()).join(','),
        _importAfterSave,
      ].join('\u0001');

  static String? _nn(String? s) {
    final t = s?.trim();
    return t == null || t.isEmpty ? null : t;
  }

  // ------------------------------------------------------------- navigation

  void _close([Object? result]) {
    if (context.canPop()) {
      context.pop(result);
    } else {
      context.go(Routes.events);
    }
  }

  Future<void> _leave() async {
    FocusScope.of(context).unfocus();
    if (!_dirty) {
      _close();
      return;
    }
    final discard = await showFTConfirm(
      context,
      title: 'Discard changes?',
      message: _isEdit
          ? 'Your changes to this event haven’t been saved.'
          : 'This event hasn’t been saved yet.',
      confirmLabel: 'Discard',
      cancelLabel: 'Keep editing',
      destructive: true,
    );
    if (discard && mounted) _close();
  }

  // ---------------------------------------------------------------- pickers

  Future<void> _pickType() async {
    final r = await showFTOptions<EventType>(
      context,
      title: 'Event type',
      options: [
        for (final t in EventType.values)
          FTOption(t, t.label, icon: AppIcons.forEvent(t), selected: t == _type),
      ],
    );
    if (r != null && mounted) setState(() => _type = r);
  }

  Future<void> _pickPeople() async {
    final r = await pickPeople(
      context,
      title: 'Who was part of it?',
      initial: _people.keys.toSet(),
    );
    if (r == null || !mounted) return;
    setState(() {
      final keep = {for (final id in r) id: _people[id]};
      _people
        ..clear()
        ..addAll(keep);
    });
  }

  Future<void> _chooseExistingPhotos() async {
    final r = await pickExistingPhotos(context, initial: _mediaIds);
    if (r == null || !mounted) return;
    setState(() {
      _mediaIds
        ..clear()
        ..addAll(r);
    });
  }

  Future<void> _addNewPhotos() async {
    if (!_isEdit) {
      setState(() => _importAfterSave = true);
      showFTToast(context, 'You can pick new photos right after saving');
      return;
    }
    final wasDirty = _dirty;
    final ids = await importPhotosFlow(context, ref, eventIds: [widget.eventId!]);
    if (ids.isEmpty || !mounted) return;
    setState(() {
      _mediaIds.addAll(ids);
      // Imported photos are linked immediately; they are not unsaved edits.
      if (!wasDirty) _snapshot = _currentSnapshot();
    });
  }

  // ------------------------------------------------------------------ save

  Future<void> _save() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    if (!(_form.currentState?.validate() ?? false)) {
      showFTToast(context, 'Please check the highlighted fields', error: true);
      return;
    }
    final treeId = ref.read(activeTreeIdProvider);
    if (treeId == null) {
      showFTToast(context, 'Create a family tree first', error: true);
      return;
    }
    setState(() => _saving = true);
    var leaving = false;
    final repo = ref.read(contentRepoProvider);
    try {
      final id = await repo.saveEvent(
        id: widget.eventId,
        treeId: treeId,
        title: _title.text,
        type: _type,
        customLabel: _type == EventType.custom ? _nn(_custom.text) : null,
        date: (_date == null || _date!.isEmpty) ? null : _date!.serialize(),
        location: _nn(_location.text),
        description: _nn(_description.text),
        remind: _remind && _canRemind,
        people: {for (final e in _people.entries) e.key: _nn(e.value)},
      );
      await setEventPhotos(ref, id, _mediaIds);
      if (!mounted) return;
      _snapshot = _currentSnapshot();
      if (_importAfterSave) {
        await importPhotosFlow(context, ref, eventIds: [id]);
        if (!mounted) return;
      }
      showFTToast(context, _isEdit ? 'Event updated' : 'Event added');
      leaving = true;
      if (_isEdit) {
        _close();
      } else {
        context.pushReplacement(Routes.event(id));
      }
    } on ValidationException catch (e) {
      if (mounted) showFTToast(context, e.toString(), error: true);
    } catch (e) {
      if (mounted) showFTToast(context, friendlyError(e), error: true);
    } finally {
      // Stay disabled once saved: the screen is closing, and a late second
      // tap would otherwise add the event twice.
      if (mounted && !leaving) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ev = _original;
    if (ev == null) return;
    final done = await confirmTrashEvent(context, ref, ev);
    if (done && mounted) {
      _snapshot = null;
      _close('deleted');
    }
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final title = _isEdit ? 'Edit event' : 'New event';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: FTPage(
        title: title,
        onBack: _leave,
        actions: [
          if (_isEdit && _original != null)
            FTIconButton(icon: AppIcons.delete, tooltip: 'Move to trash', onTap: _delete),
          FTIconButton(
            icon: AppIcons.check,
            tooltip: 'Save event',
            accent: true,
            onTap: _loading || _missing || _saving ? null : _save,
          ),
        ],
        body: _loading
            ? const LoadingView()
            : _missing
                ? EmptyState(
                    icon: AppIcons.event,
                    title: 'Event not found',
                    message: 'It may have been moved to the trash.',
                    actionLabel: 'Back to events',
                    onAction: () => context.go(Routes.events),
                  )
                : _buildForm(context),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    final c = context.ft;
    final pad = context.pagePadding;
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final mediaById = ref.watch(mediaByIdProvider);
    final photos = [for (final id in _mediaIds) ?mediaById[id]];

    return Form(
      key: _form,
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, FTPage.bottomInset(context) + Gap.lg),
        children: [
          ContentWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FadeSlideIn(
                  child: FTCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            IconBadge(icon: AppIcons.forEvent(_type), size: 48, accent: true),
                            const SizedBox(width: Gap.md),
                            Expanded(
                              child: Text(
                                'What happened, when and where. Unknown parts can stay empty.',
                                style: context.tx.caption,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: Gap.lg),
                        FTTextField(
                          controller: _title,
                          label: 'Title',
                          hint: 'e.g. Wedding of Anna and Ravi',
                          icon: AppIcons.event,
                          autofocus: !_isEdit,
                          textInputAction: TextInputAction.next,
                          maxLength: 120,
                          validator: (v) =>
                              (v == null || v.trim().isEmpty) ? 'Please give the event a title' : null,
                        ),
                        const SizedBox(height: Gap.xs),
                        FTSelectField(
                          label: 'Type',
                          value: _type.label,
                          icon: AppIcons.forEvent(_type),
                          onTap: _pickType,
                        ),
                        if (_type == EventType.custom) ...[
                          const SizedBox(height: Gap.sm),
                          FTTextField(
                            controller: _custom,
                            label: 'Custom type (optional)',
                            hint: 'e.g. House warming',
                            icon: AppIcons.tag,
                            maxLength: 40,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Gap.lg),
                FadeSlideIn(
                  index: 1,
                  child: FTCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FuzzyDateField(
                          label: 'Date',
                          value: _date,
                          onChanged: (d) => setState(() {
                            _date = d;
                            if (!(d?.hasMonthDay ?? false)) _remind = false;
                          }),
                        ),
                        const SizedBox(height: Gap.sm),
                        FTTextField(
                          controller: _location,
                          label: 'Place',
                          hint: 'Town, venue or address',
                          icon: AppIcons.location,
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: Gap.sm),
                        FTSwitchRow(
                          icon: AppIcons.bellRinging,
                          title: 'Yearly reminder',
                          subtitle: _canRemind
                              ? 'Show this event in the calendar every year'
                              : 'Needs a known day and month',
                          value: _remind && _canRemind,
                          onChanged: _canRemind ? (v) => setState(() => _remind = v) : null,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Gap.lg),
                FadeSlideIn(
                  index: 2,
                  child: FTTextField(
                    controller: _description,
                    label: 'Description',
                    hint: 'What do people remember about it?',
                    icon: AppIcons.note,
                    maxLines: 8,
                    minLines: 3,
                    keyboardType: TextInputType.multiline,
                  ),
                ),
                const SizedBox(height: Gap.xl),
                SectionHeader(
                  'People',
                  action: _people.isEmpty ? null : 'Edit',
                  onAction: _pickPeople,
                ),
                FadeSlideIn(
                  index: 3,
                  child: FTCard(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final id in _people.keys)
                          if (g[id] != null) _participantRow(context, g[id]!),
                        FTListRow(
                          title: _people.isEmpty ? 'Add people' : 'Add or remove people',
                          subtitle: _people.isEmpty ? 'Who took part, hosted or was celebrated' : null,
                          icon: AppIcons.personAdd,
                          onTap: _pickPeople,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Gap.xl),
                SectionHeader('Photos', trailing: photos.isEmpty ? null : FTTag('${photos.length}')),
                FadeSlideIn(
                  index: 4,
                  child: FTCard(
                    padding: const EdgeInsets.all(Gap.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (photos.isNotEmpty) ...[
                          Wrap(
                            spacing: Gap.xs,
                            runSpacing: Gap.xs,
                            children: [
                              for (final m in photos)
                                SizedBox(
                                  width: 76,
                                  height: 76,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      MediaThumb(media: m),
                                      Positioned(
                                        top: 2,
                                        right: 2,
                                        child: Tooltip(
                                          message: 'Remove photo from event',
                                          child: Pressable(
                                            semanticLabel: 'Remove photo from event',
                                            onTap: () => setState(() => _mediaIds.remove(m.id)),
                                            child: Container(
                                              width: 24,
                                              height: 24,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: Colors.black.withValues(alpha: 0.55),
                                                border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
                                              ),
                                              child: const Icon(AppIcons.close, size: 13, color: Colors.white),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: Gap.md),
                        ],
                        if (_importAfterSave)
                          Padding(
                            padding: const EdgeInsets.only(bottom: Gap.sm),
                            child: Row(
                              children: [
                                Icon(AppIcons.info, size: 16, color: c.accent),
                                const SizedBox(width: Gap.xs),
                                Expanded(
                                  child: Text('The photo picker opens after you save.',
                                      style: context.tx.caption),
                                ),
                                FTTextAction('Cancel',
                                    onTap: () => setState(() => _importAfterSave = false)),
                              ],
                            ),
                          ),
                        Wrap(
                          spacing: Gap.xs,
                          runSpacing: Gap.xs,
                          children: [
                            FTButton.secondary(
                              label: 'From gallery',
                              icon: AppIcons.photos,
                              height: 46,
                              onTap: _chooseExistingPhotos,
                            ),
                            FTButton.secondary(
                              label: 'Add new',
                              icon: AppIcons.camera,
                              height: 46,
                              onTap: _importAfterSave ? null : _addNewPhotos,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Gap.xxl),
                FTButton(
                  label: _isEdit ? 'Save changes' : 'Save event',
                  icon: AppIcons.check,
                  expand: true,
                  loading: _saving,
                  onTap: _save,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _participantRow(BuildContext context, Person p) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: PersonAvatarFor(p, size: 40),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 6),
                  child: Text(p.displayName,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                ),
                FTTextField(
                  key: ValueKey('role-${p.id}'),
                  initialValue: _people[p.id] ?? '',
                  label: 'Role (optional)',
                  hint: 'e.g. Bride, Host, Graduate',
                  maxLength: 40,
                  onChanged: (v) => _people[p.id] = v,
                ),
              ],
            ),
          ),
          const SizedBox(width: Gap.xxs),
          FTIconButton(
            icon: AppIcons.close,
            tooltip: 'Remove ${p.displayName}',
            size: 36,
            onTap: () => setState(() => _people.remove(p.id)),
          ),
        ],
      ),
    );
  }
}
