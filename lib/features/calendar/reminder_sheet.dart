import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/repositories/family_repository.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../members/widgets/person_widgets.dart';
import 'calendar_logic.dart';
import 'calendar_widgets.dart';

enum ReminderSheetAction { saved, deleted }

class ReminderSheetResult {
  const ReminderSheetResult(this.action, {this.deleted});
  final ReminderSheetAction action;

  /// The removed reminder (for Undo).
  final Reminder? deleted;
}

/// Opens the add / edit reminder sheet. Shows the result toast (with Undo
/// for deletions) on [context] after the sheet closes.
Future<ReminderSheetResult?> showReminderSheet(
  BuildContext context,
  WidgetRef ref, {
  Reminder? existing,
  DateTime? initialDate,
  String? personId,
}) async {
  final repo = ref.read(contentRepoProvider);
  final r = await showFTSheet<ReminderSheetResult>(
    context,
    title: existing == null ? 'New reminder' : 'Edit reminder',
    builder: (_) => _ReminderForm(existing: existing, initialDate: initialDate, personId: personId),
  );
  if (r == null || !context.mounted) return r;
  switch (r.action) {
    case ReminderSheetAction.saved:
      showFTToast(context, existing == null ? 'Reminder added' : 'Reminder updated');
    case ReminderSheetAction.deleted:
      final d = r.deleted;
      showFTToast(
        context,
        'Reminder deleted',
        actionLabel: d == null ? null : 'Undo',
        onAction: d == null
            ? null
            : () => repo.saveReminder(
                  treeId: d.treeId,
                  title: d.title,
                  date: d.date,
                  repeat: d.repeat,
                  notes: d.notes,
                  personId: d.personId,
                  enabled: d.enabled,
                ),
      );
  }
  return r;
}

class _ReminderForm extends ConsumerStatefulWidget {
  const _ReminderForm({this.existing, this.initialDate, this.personId});
  final Reminder? existing;
  final DateTime? initialDate;
  final String? personId;

  @override
  ConsumerState<_ReminderForm> createState() => _ReminderFormState();
}

class _ReminderFormState extends ConsumerState<_ReminderForm> {
  static const _quickHours = [7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21];

  final _form = GlobalKey<FormState>();
  late final TextEditingController _title = TextEditingController(text: widget.existing?.title ?? '');
  late final TextEditingController _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late DateTime _day;
  late int _hour;
  late int _minute;
  late ReminderRepeat _repeat = widget.existing?.repeat ?? ReminderRepeat.none;
  late String? _personId = widget.existing?.personId ?? widget.personId;
  late bool _enabled = widget.existing?.enabled ?? true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final base = widget.existing?.date ?? widget.initialDate ?? DateTime.now();
    _day = CalendarMath.dateOnly(base);
    if (widget.existing != null) {
      _hour = base.hour;
      _minute = base.minute;
    } else {
      _hour = ref.read(settingsProvider).notifyHour;
      _minute = 0;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  DateTime get _when => DateTime(_day.year, _day.month, _day.day, _hour, _minute);

  Future<void> _pickDate() async {
    final d = await showFTDatePicker(context, initial: _day, title: 'Reminder date');
    if (d != null && mounted) setState(() => _day = d);
  }

  Future<void> _pickTime() async {
    final r = await showFTSheet<(int, int)>(
      context,
      title: 'Time',
      builder: (_) => _TimePicker(hour: _hour, minute: _minute),
    );
    if (r != null && mounted) {
      setState(() {
        _hour = r.$1;
        _minute = r.$2;
      });
    }
  }

  Future<void> _pickPerson() async {
    final id = await pickPerson(context, title: 'Who is it about?');
    if (id != null && mounted) setState(() => _personId = id);
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_form.currentState?.validate() ?? false)) return;
    final treeId = ref.read(activeTreeIdProvider);
    if (treeId == null) {
      showFTToast(context, 'Create a family tree first', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final notes = _notes.text.trim();
      await ref.read(contentRepoProvider).saveReminder(
            id: widget.existing?.id,
            treeId: treeId,
            title: _title.text,
            date: _when,
            repeat: _repeat,
            notes: notes.isEmpty ? null : notes,
            personId: _personId,
            enabled: _enabled,
          );
      if (mounted) Navigator.of(context).pop(const ReminderSheetResult(ReminderSheetAction.saved));
    } on ValidationException catch (e) {
      if (mounted) showFTToast(context, e.toString(), error: true);
    } catch (e) {
      if (mounted) showFTToast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final r = widget.existing;
    if (r == null) return;
    final ok = await showFTConfirm(
      context,
      title: 'Delete reminder?',
      message: '“${r.title}” and its notifications will be removed.',
      confirmLabel: 'Delete',
      destructive: true,
      icon: AppIcons.delete,
    );
    if (!ok || !mounted) return;
    try {
      await ref.read(contentRepoProvider).deleteReminder(r.id);
      if (mounted) {
        Navigator.of(context).pop(ReminderSheetResult(ReminderSheetAction.deleted, deleted: r));
      }
    } catch (e) {
      if (mounted) showFTToast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final t = context.tx;
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final person = _personId == null ? null : g[_personId!];
    final today = CalendarMath.dateOnly(DateTime.now());
    final past = _repeat == ReminderRepeat.none && _when.isBefore(DateTime.now());
    final hours = [
      if (_minute != 0 || !_quickHours.contains(_hour)) (_hour, _minute),
      for (final h in _quickHours) (h, 0),
    ];

    return Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FTTextField(
            controller: _title,
            label: 'Title',
            hint: 'e.g. Call Grandma, Visit the cemetery',
            icon: AppIcons.bell,
            autofocus: widget.existing == null,
            maxLength: 80,
            textInputAction: TextInputAction.next,
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Please give the reminder a title' : null,
          ),
          const SizedBox(height: Gap.xs),
          FTSelectField(
            label: 'Date',
            icon: AppIcons.calendarBlank,
            value: DateFormat('EEEE, d MMMM y').format(_day) +
                (CalendarMath.sameDay(_day, today) ? ' · Today' : ''),
            onTap: _pickDate,
          ),
          if (past) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(AppIcons.warning, size: 15, color: c.warning),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('This time has already passed, so no notification will be sent.',
                      style: t.caption.copyWith(color: c.warning)),
                ),
              ],
            ),
          ],
          const SizedBox(height: Gap.md),
          Text('Time', style: t.caption),
          const SizedBox(height: Gap.xs),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final (h, m) in hours) ...[
                  FTChip(
                    label: formatClock(context, h, m),
                    selected: h == _hour && m == _minute,
                    onTap: () => setState(() {
                      _hour = h;
                      _minute = m;
                    }),
                  ),
                  const SizedBox(width: Gap.xs),
                ],
                FTChip(label: 'Other time', icon: AppIcons.clock, selected: false, onTap: _pickTime),
              ],
            ),
          ),
          const SizedBox(height: Gap.lg),
          Text('Repeat', style: t.caption),
          const SizedBox(height: Gap.xs),
          FTSegmented<ReminderRepeat>(
            values: ReminderRepeat.values,
            selected: _repeat,
            labelOf: (r) => r.label,
            onChanged: (r) => setState(() => _repeat = r),
          ),
          const SizedBox(height: Gap.lg),
          FTSelectField(
            label: 'Person (optional)',
            icon: AppIcons.person,
            value: person?.displayName,
            placeholder: 'Not linked to anyone',
            onTap: _pickPerson,
            onClear: () => setState(() => _personId = null),
          ),
          const SizedBox(height: Gap.sm),
          FTTextField(
            controller: _notes,
            label: 'Notes (optional)',
            icon: AppIcons.note,
            maxLines: 4,
            minLines: 2,
            keyboardType: TextInputType.multiline,
          ),
          if (widget.existing != null) ...[
            const SizedBox(height: Gap.xs),
            FTSwitchRow(
              title: 'Active',
              subtitle: _enabled ? 'Shown in the calendar and notified' : 'Paused – hidden from the calendar',
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
          ],
          const SizedBox(height: Gap.xl),
          Row(
            children: [
              if (widget.existing != null) ...[
                Expanded(
                  child: FTButton(
                    label: 'Delete',
                    icon: AppIcons.delete,
                    kind: FTButtonKind.danger,
                    expand: true,
                    onTap: _delete,
                  ),
                ),
                const SizedBox(width: Gap.sm),
              ],
              Expanded(
                child: FTButton(
                  label: 'Save',
                  icon: AppIcons.check,
                  expand: true,
                  loading: _saving,
                  onTap: _save,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Hour and minute chips (no Material dialogs).
class _TimePicker extends StatefulWidget {
  const _TimePicker({required this.hour, required this.minute});
  final int hour;
  final int minute;

  @override
  State<_TimePicker> createState() => _TimePickerState();
}

class _TimePickerState extends State<_TimePicker> {
  late int _h = widget.hour;
  late int _m = widget.minute - widget.minute % 5;

  @override
  Widget build(BuildContext context) {
    final t = context.tx;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: Text(formatClock(context, _h, _m), style: t.display)),
        const SizedBox(height: Gap.lg),
        Text('Hour', style: t.caption),
        const SizedBox(height: Gap.xs),
        Wrap(
          spacing: Gap.xs,
          runSpacing: Gap.xs,
          children: [
            for (var h = 0; h < 24; h++)
              FTChip(
                label: h.toString().padLeft(2, '0'),
                selected: h == _h,
                onTap: () => setState(() => _h = h),
              ),
          ],
        ),
        const SizedBox(height: Gap.lg),
        Text('Minute', style: t.caption),
        const SizedBox(height: Gap.xs),
        Wrap(
          spacing: Gap.xs,
          runSpacing: Gap.xs,
          children: [
            for (var m = 0; m < 60; m += 5)
              FTChip(
                label: ':${m.toString().padLeft(2, '0')}',
                selected: m == _m,
                onTap: () => setState(() => _m = m),
              ),
          ],
        ),
        const SizedBox(height: Gap.xl),
        FTButton(
          label: 'Use ${formatClock(context, _h, _m)}',
          expand: true,
          onTap: () => Navigator.of(context).pop((_h, _m)),
        ),
      ],
    );
  }
}
