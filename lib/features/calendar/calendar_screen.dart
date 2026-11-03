import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/widgets/widgets.dart';
import '../events/event_widgets.dart';
import '../family/domain/family_graph.dart';
import '../family/domain/occasions.dart';
import 'calendar_logic.dart';
import 'calendar_widgets.dart';
import 'reminder_sheet.dart';

enum _CalView { month, agenda }

/// Family calendar: birthdays, anniversaries, memorials, events and custom
/// reminders in a month grid or agenda, with upcoming occasions.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  static const _upcomingDays = 60;
  static const _upcomingPreview = 6;

  late DateTime _month = CalendarMath.firstOfMonth(DateTime.now());
  late DateTime _selected = CalendarMath.dateOnly(DateTime.now());
  _CalView _view = _CalView.month;
  Set<OccasionKind> _kinds = OccasionKind.values.toSet();
  bool _showAllUpcoming = false;
  bool _showAllReminders = false;
  int _direction = 0;

  DateTime get _today => CalendarMath.dateOnly(DateTime.now());

  void _goMonth(DateTime m, {DateTime? select}) {
    final next = CalendarMath.firstOfMonth(m);
    setState(() {
      _direction = next.isAfter(_month) ? 1 : (next.isBefore(_month) ? -1 : 0);
      _month = next;
      if (select != null) {
        _selected = CalendarMath.dateOnly(select);
      } else if (_selected.year != next.year || _selected.month != next.month) {
        final t = _today;
        _selected = (t.year == next.year && t.month == next.month) ? t : next;
      }
    });
  }

  Future<void> _pickMonth() async {
    final r = await showMonthYearPicker(context, initial: _month);
    if (r != null && mounted) _goMonth(r);
  }

  void _select(DateTime d) {
    if (d.year != _month.year || d.month != _month.month) {
      _goMonth(d, select: d);
    } else {
      setState(() => _selected = CalendarMath.dateOnly(d));
    }
  }

  void _toggleKind(OccasionKind k) {
    setState(() {
      final all = OccasionKind.values.toSet();
      if (_kinds.length == all.length) {
        _kinds = {k};
      } else if (_kinds.contains(k)) {
        final next = {..._kinds}..remove(k);
        _kinds = next.isEmpty ? all : next;
      } else {
        _kinds = {..._kinds, k};
      }
    });
  }

  Future<void> _addReminder([DateTime? day]) async {
    final base = day ?? (_selected.isBefore(_today) ? _today : _selected);
    await showReminderSheet(context, ref, initialDate: base);
  }

  void _openOccasion(Occasion o, List<Reminder> reminders) {
    switch (o.kind) {
      case OccasionKind.birthday:
      case OccasionKind.memorial:
      case OccasionKind.anniversary:
        final id = o.personIds.firstOrNull;
        if (id != null) context.push(Routes.person(id));
      case OccasionKind.event:
        if (o.sourceId != null) context.push(Routes.event(o.sourceId!));
      case OccasionKind.reminder:
        final r = reminders.where((x) => x.id == o.sourceId).firstOrNull;
        if (r != null) showReminderSheet(context, ref, existing: r);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(occasionCalculatorProvider);
    final prefs = ref.watch(settingsProvider);
    return FTPage(
      title: 'Calendar',
      actions: [
        FTIconButton(icon: AppIcons.add, tooltip: 'Add reminder', onTap: () => _addReminder()),
        FTIconButton(
          icon: AppIcons.bell,
          tooltip: 'Notification settings',
          badge: prefs.notificationsEnabled,
          onTap: () => context.push(Routes.notifications),
        ),
      ],
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e),
        data: (calc) => _body(context, calc),
      ),
    );
  }

  Widget _body(BuildContext context, OccasionCalculator calc) {
    final pad = context.pagePadding;
    final today = _today;
    final reminders = ref.watch(remindersProvider).value ?? const <Reminder>[];
    bool keep(Occasion o) => _kinds.contains(o.kind);

    final grid = CalendarMath.gridDays(_month);
    final gridOccasions = calc.between(grid.first, grid.last).where(keep).toList();
    final byDay = CalendarMath.byDay(gridOccasions);
    final markers = {for (final e in byDay.entries) e.key: e.value.length};
    final dayList = byDay[_selected] ?? const <Occasion>[];
    final upcoming = calc
        .between(today, today.add(const Duration(days: _upcomingDays)))
        .where(keep)
        .toList();

    Widget box(Widget child, {double top = 0}) => SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(pad, top, pad, 0),
            child: ContentWidth(child: child),
          ),
        );

    final slivers = <Widget>[
      if (upcoming.isNotEmpty) box(_nextUp(context, upcoming.first), top: Gap.xs),
      box(
        FTSegmented<_CalView>(
          values: _CalView.values,
          selected: _view,
          labelOf: (v) => v == _CalView.month ? 'Month' : 'Agenda',
          onChanged: (v) => setState(() => _view = v),
        ),
        top: Gap.md,
      ),
      SliverToBoxAdapter(child: _kindChips(context)),
    ];

    if (_view == _CalView.month) {
      slivers.addAll([
        box(_monthCard(context, markers)),
        box(
          SectionHeader(
            DateFormat('EEEE, d MMMM').format(_selected),
            trailing: CalendarMath.sameDay(_selected, today)
                ? const FTTag('Today', accent: true)
                : null,
            action: 'Add',
            onAction: () => _addReminder(_selected),
          ),
          top: Gap.xl,
        ),
        if (dayList.isEmpty)
          box(Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            child: Text(
              'Nothing on this day${_kinds.length < OccasionKind.values.length ? ' for these filters' : ''}.',
              style: context.tx.body,
            ),
          ))
        else
          _rows(context, [
            for (final o in dayList)
              OccasionRow(
                occasion: o,
                onTap: () => _openOccasion(o, reminders),
                trailing: o.years != null && o.years! > 0 && o.kind != OccasionKind.reminder
                    ? '${o.years}'
                    : null,
              ),
          ]),
        ..._upcomingSection(context, upcoming, reminders),
      ]);
    } else {
      slivers.addAll(_agenda(context, byDay, reminders));
    }

    slivers.addAll(_remindersSection(context, reminders));
    slivers.add(SliverToBoxAdapter(child: SizedBox(height: FTPage.bottomInset(context))));
    return CustomScrollView(slivers: slivers);
  }

  // ------------------------------------------------------------ components

  Widget _nextUp(BuildContext context, Occasion o) {
    final c = context.ft;
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final avatars = avatarPairsFor(ref, g, o.personIds);
    final when = CalendarMath.relativeDay(o.date, _today);
    final sub = o.subtitle?.trim();
    return FTPill(
      padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
      semanticLabel: 'Up next: ${o.title}, $when. Show in calendar',
      onTap: () {
        setState(() => _view = _CalView.month);
        _select(o.date);
      },
      child: Row(
        children: [
          IconBadge(icon: occasionIcon(o.kind), size: 44, accent: true),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(o.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                const SizedBox(height: 1),
                Text(
                  [when, if (sub != null && sub.isNotEmpty) sub].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.tx.caption.copyWith(color: c.text2),
                ),
              ],
            ),
          ),
          if (avatars.isNotEmpty) ...[
            const SizedBox(width: Gap.xs),
            AvatarStack(people: avatars, size: 32, max: 3),
          ],
        ],
      ),
    );
  }

  Widget _kindChips(BuildContext context) {
    final pad = context.pagePadding;
    final all = _kinds.length == OccasionKind.values.length;
    return SizedBox(
      height: 60,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(pad, Gap.sm, pad, Gap.sm),
        children: [
          FTChip(
            label: 'All',
            selected: all,
            onTap: () => setState(() => _kinds = OccasionKind.values.toSet()),
          ),
          for (final k in OccasionKind.values) ...[
            const SizedBox(width: Gap.xs),
            FTChip(
              label: occasionFilterLabel(k),
              icon: occasionIcon(k),
              selected: !all && _kinds.contains(k),
              onTap: () => _toggleKind(k),
            ),
          ],
        ],
      ),
    );
  }

  Widget _monthCard(BuildContext context, Map<DateTime, int> markers) {
    final reduce = context.reduceMotion;
    final grid = MonthGrid(
      key: ValueKey(_month),
      month: _month,
      selected: _selected,
      today: _today,
      markers: markers,
      onSelect: _select,
    );
    return FTCard(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, Gap.md),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: Gap.xs),
            child: MonthHeader(
              month: _month,
              onPrev: () => _goMonth(CalendarMath.addMonths(_month, -1)),
              onNext: () => _goMonth(CalendarMath.addMonths(_month, 1)),
              onPick: _pickMonth,
            ),
          ),
          const SizedBox(height: Gap.md),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v < -250) _goMonth(CalendarMath.addMonths(_month, 1));
              if (v > 250) _goMonth(CalendarMath.addMonths(_month, -1));
            },
            child: AnimatedSwitcher(
              duration: reduce ? Duration.zero : Motion.medium,
              switchInCurve: Motion.curve,
              switchOutCurve: Curves.easeIn,
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                children: [...previous, ?current],
              ),
              transitionBuilder: (child, anim) {
                final incoming = child.key == ValueKey(_month);
                final dx = (incoming ? 0.08 : -0.08) * _direction;
                return FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween(begin: Offset(dx, 0), end: Offset.zero).animate(anim),
                    child: child,
                  ),
                );
              },
              child: grid,
            ),
          ),
        ],
      ),
    );
  }

  Widget _rows(BuildContext context, List<Widget> rows) {
    final pad = context.pagePadding;
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      sliver: SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, i) => ContentWidth(
          child: Padding(
            padding: const EdgeInsets.only(bottom: Gap.xs),
            child: FadeSlideIn(index: i < 10 ? i : 0, child: rows[i]),
          ),
        ),
      ),
    );
  }

  Widget _boxed(BuildContext context, Widget child, {double top = 0}) => SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(context.pagePadding, top, context.pagePadding, 0),
          child: ContentWidth(child: child),
        ),
      );

  List<Widget> _upcomingSection(BuildContext context, List<Occasion> upcoming, List<Reminder> reminders) {
    final today = _today;
    final shown = _showAllUpcoming ? upcoming : upcoming.take(_upcomingPreview).toList();
    return [
      _boxed(
        context,
        SectionHeader(
          'Upcoming',
          trailing: const FTTag('Next 60 days'),
          action: upcoming.length > _upcomingPreview ? (_showAllUpcoming ? 'Show less' : 'See all') : null,
          onAction: () => setState(() => _showAllUpcoming = !_showAllUpcoming),
        ),
        top: Gap.xl,
      ),
      if (upcoming.isEmpty)
        _boxed(
          context,
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            child: Text(
              'No occasions in the next 60 days. Birthdays and anniversaries appear once day and month are known.',
              style: context.tx.body,
            ),
          ),
        )
      else
        _rows(context, [
          for (final o in shown)
            OccasionRow(
              occasion: o,
              trailing: _upcomingLabel(o.date, today),
              onTap: () => _openOccasion(o, reminders),
            ),
        ]),
    ];
  }

  String _upcomingLabel(DateTime d, DateTime today) {
    final rel = CalendarMath.relativeDay(d, today);
    if (rel == 'Today' || rel == 'Tomorrow') return rel;
    return '${DateFormat('EEE d MMM').format(d)}\n${rel.toLowerCase()}';
  }

  List<Widget> _agenda(BuildContext context, Map<DateTime, List<Occasion>> byDay, List<Reminder> reminders) {
    final c = context.ft;
    final today = _today;
    final days = byDay.keys.where((d) => d.year == _month.year && d.month == _month.month).toList()..sort();
    final rows = <Widget>[];
    for (final d in days) {
      final isToday = CalendarMath.sameDay(d, today);
      rows.add(Padding(
        padding: EdgeInsets.only(top: rows.isEmpty ? 0 : Gap.md, bottom: 2),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: isToday ? c.accentGradient : c.chipGradient,
                border: isToday ? null : Border.all(color: c.border),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('${d.day}',
                    style: context.tx.bodyStrong.copyWith(color: isToday ? c.onAccent : c.text)),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(
                DateFormat('EEEE').format(d),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.tx.section,
              ),
            ),
            FTTag(CalendarMath.relativeDay(d, today), accent: isToday),
          ],
        ),
      ));
      for (final o in byDay[d]!) {
        rows.add(OccasionRow(
          occasion: o,
          dimmed: d.isBefore(today),
          onTap: () => _openOccasion(o, reminders),
        ));
      }
    }
    return [
      _boxed(
        context,
        FTPill(
          padding: const EdgeInsets.all(4),
          child: Row(
            children: [
              FTIconButton(
                icon: AppIcons.back,
                tooltip: 'Previous month',
                size: 40,
                onTap: () => _goMonth(CalendarMath.addMonths(_month, -1)),
              ),
              Expanded(
                child: Pressable(
                  onTap: _pickMonth,
                  semanticLabel: '${DateFormat('MMMM y').format(_month)}. Choose month',
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(DateFormat('MMMM y').format(_month),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.section),
                      ),
                      const SizedBox(width: 6),
                      Icon(AppIcons.chevronDown, size: 16, color: c.text2),
                    ],
                  ),
                ),
              ),
              FTIconButton(
                icon: AppIcons.forward,
                tooltip: 'Next month',
                size: 40,
                onTap: () => _goMonth(CalendarMath.addMonths(_month, 1)),
              ),
            ],
          ),
        ),
      ),
      if (rows.isEmpty)
        _boxed(
          context,
          EmptyState(
            icon: AppIcons.calendar,
            title: 'A quiet month',
            message: 'Nothing on the calendar for ${DateFormat('MMMM').format(_month)}.',
            actionLabel: 'Add reminder',
            onAction: () => _addReminder(),
            compact: true,
          ),
        )
      else ...[
        const SliverToBoxAdapter(child: SizedBox(height: Gap.lg)),
        _rows(context, rows),
      ],
    ];
  }

  List<Widget> _remindersSection(BuildContext context, List<Reminder> reminders) {
    final c = context.ft;
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final sorted = [...reminders]..sort((a, b) {
        if (a.enabled != b.enabled) return a.enabled ? -1 : 1;
        return a.date.compareTo(b.date);
      });
    final shown = _showAllReminders ? sorted : sorted.take(5).toList();
    return [
      _boxed(
        context,
        SectionHeader(
          'Your reminders',
          trailing: reminders.isEmpty ? null : FTTag('${reminders.length}'),
          action: sorted.length > 5 ? (_showAllReminders ? 'Show less' : 'See all') : 'Add',
          onAction: sorted.length > 5
              ? () => setState(() => _showAllReminders = !_showAllReminders)
              : () => _addReminder(),
        ),
        top: Gap.xl,
      ),
      if (reminders.isEmpty)
        _boxed(
          context,
          FTCard(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
            child: FTListRow(
              title: 'Add a reminder',
              subtitle: 'Visits, calls, family traditions – once, monthly or yearly',
              icon: AppIcons.bellRinging,
              onTap: () => _addReminder(),
            ),
          ),
        )
      else
        _rows(context, [
          for (final r in shown)
            Opacity(
              opacity: r.enabled ? 1 : 0.55,
              child: FTPill(
                padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
                semanticLabel: '${r.title}, ${_reminderWhen(context, r)}${r.enabled ? '' : ', paused'}. Edit',
                onTap: () => showReminderSheet(context, ref, existing: r),
                child: Row(
                  children: [
                    IconBadge(icon: r.enabled ? AppIcons.bellRinging : AppIcons.bell, size: 44, accent: r.enabled),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                          const SizedBox(height: 1),
                          Text(
                            [
                              _reminderWhen(context, r),
                              if (r.personId != null && g[r.personId!] != null) g[r.personId!]!.displayName,
                              if (!r.enabled) 'Paused',
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.tx.caption,
                          ),
                        ],
                      ),
                    ),
                    Icon(AppIcons.edit, size: 16, color: c.text3),
                  ],
                ),
              ),
            ),
        ]),
    ];
  }

  String _reminderWhen(BuildContext context, Reminder r) {
    final time = formatClock(context, r.date.hour, r.date.minute);
    return switch (r.repeat) {
      ReminderRepeat.none => '${DateFormat('d MMM y').format(r.date)}, $time',
      ReminderRepeat.yearly => 'Every ${DateFormat('d MMMM').format(r.date)}, $time',
      ReminderRepeat.monthly => 'Monthly on day ${r.date.day}, $time',
    };
  }
}
