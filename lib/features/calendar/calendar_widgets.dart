import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/widgets/widgets.dart';
import '../events/event_widgets.dart';
import '../family/domain/family_graph.dart';
import '../family/domain/occasions.dart';
import '../members/widgets/person_widgets.dart';
import 'calendar_logic.dart';

IconData occasionIcon(OccasionKind k) => switch (k) {
      OccasionKind.birthday => AppIcons.cake,
      OccasionKind.anniversary => AppIcons.heart,
      OccasionKind.memorial => AppIcons.candle,
      OccasionKind.event => AppIcons.event,
      OccasionKind.reminder => AppIcons.bell,
    };

/// Localised time label honouring the device's 24-hour setting.
String formatClock(BuildContext context, int hour, int minute) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay(hour: hour, minute: minute),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

/// The reference calendar grid: MON…SUN header, filled graphite day
/// circles, dashed circles for neighbouring months, mint selected day and
/// small dots under days with occasions.
class MonthGrid extends StatelessWidget {
  const MonthGrid({
    super.key,
    required this.month,
    required this.selected,
    required this.onSelect,
    this.markers = const {},
    this.today,
  });

  final DateTime month;
  final DateTime? selected;
  final ValueChanged<DateTime> onSelect;

  /// Number of occasions per (date-only) day.
  final Map<DateTime, int> markers;
  final DateTime? today;

  static final _weekdays = [
    for (var i = 0; i < 7; i++)
      DateFormat('EEE').format(DateTime(2024, 1, 1 + i)).toUpperCase(),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final days = CalendarMath.gridDays(month);
    return LayoutBuilder(builder: (context, cons) {
      final cellW = cons.maxWidth / 7;
      final d = math.min(cellW - 6, 46.0).clamp(26.0, 46.0);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              for (final w in _weekdays)
                Expanded(
                  child: Center(
                    child: Text(
                      w,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: context.tx.micro.copyWith(letterSpacing: 0.8, color: c.text3),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Gap.sm),
          for (var w = 0; w < days.length ~/ 7; w++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(child: _cell(context, days[w * 7 + i], d)),
                ],
              ),
            ),
        ],
      );
    });
  }

  Widget _cell(BuildContext context, DateTime day, double size) {
    final c = context.ft;
    final inMonth = day.month == month.month;
    final isSel = selected != null && CalendarMath.sameDay(day, selected!);
    final isToday = today != null && CalendarMath.sameDay(day, today!);
    final count = markers[CalendarMath.dateOnly(day)] ?? 0;

    final textStyle = context.tx.label.copyWith(
      fontSize: 14,
      fontWeight: isSel || isToday ? FontWeight.w600 : FontWeight.w500,
      color: isSel
          ? c.onAccent
          : !inMonth
              ? c.text3
              : isToday
                  ? c.accent
                  : c.text,
    );
    final label = Padding(
      padding: const EdgeInsets.all(5),
      child: FittedBox(fit: BoxFit.scaleDown, child: Text('${day.day}', style: textStyle)),
    );

    Widget circle;
    if (isSel) {
      circle = Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: c.accentGradient,
          boxShadow: [BoxShadow(color: c.accent.withValues(alpha: 0.35), blurRadius: 14, spreadRadius: -2)],
        ),
        child: label,
      );
    } else if (inMonth) {
      circle = Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: c.isDark
                ? const [Color(0xFF2E2F35), Color(0xFF1A1B1F)]
                : [Colors.white, c.surfaceHigh],
          ),
          border: Border.all(
            color: isToday ? c.accent.withValues(alpha: 0.8) : c.border,
            width: isToday ? 1.4 : 1,
          ),
        ),
        child: label,
      );
    } else {
      circle = SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: DashedCirclePainter(c.text3.withValues(alpha: 0.55)),
          child: Center(child: label),
        ),
      );
    }

    final dots = SizedBox(
      height: 8,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < math.min(count, 3); i++)
            Container(
              width: 4,
              height: 4,
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: inMonth ? c.accent : c.accent.withValues(alpha: 0.45),
              ),
            ),
        ],
      ),
    );

    final semantic = StringBuffer(DateFormat('EEEE d MMMM y').format(day));
    if (isToday) semantic.write(', today');
    if (count > 0) semantic.write(', $count ${count == 1 ? 'occasion' : 'occasions'}');
    return Semantics(
      selected: isSel,
      child: Pressable(
        onTap: () => onSelect(day),
        scale: 0.9,
        semanticLabel: semantic.toString(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 2),
            circle,
            const SizedBox(height: 3),
            dots,
          ],
        ),
      ),
    );
  }
}

/// Month title row of the calendar card: "November ˅" (opens the picker),
/// previous / next buttons and the year on the right.
class MonthHeader extends StatelessWidget {
  const MonthHeader({
    super.key,
    required this.month,
    required this.onPrev,
    required this.onNext,
    required this.onPick,
  });

  final DateTime month;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final name = DateFormat('MMMM').format(month);
    return Row(
      children: [
        Expanded(
          child: Pressable(
            onTap: onPick,
            semanticLabel: '$name ${month.year}. Choose month and year',
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.xs),
              child: Row(
                children: [
                  Flexible(
                    child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.title),
                  ),
                  const SizedBox(width: 6),
                  Icon(AppIcons.chevronDown, size: 18, color: c.text2),
                ],
              ),
            ),
          ),
        ),
        FTIconButton(icon: AppIcons.back, tooltip: 'Previous month', size: 36, onTap: onPrev),
        Pressable(
          onTap: onPick,
          semanticLabel: 'Year ${month.year}. Choose year',
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Center(
              widthFactor: 1,
              child: Text('${month.year}', style: context.tx.title.copyWith(color: c.text2)),
            ),
          ),
        ),
        FTIconButton(icon: AppIcons.forward, tooltip: 'Next month', size: 36, onTap: onNext),
      ],
    );
  }
}

/// Sheet with year navigation and a month grid. Returns the first day of
/// the chosen month.
Future<DateTime?> showMonthYearPicker(BuildContext context, {required DateTime initial}) {
  return showFTSheet<DateTime>(
    context,
    title: 'Go to month',
    builder: (_) => _MonthYearPicker(initial: initial),
  );
}

class _MonthYearPicker extends StatefulWidget {
  const _MonthYearPicker({required this.initial});
  final DateTime initial;

  @override
  State<_MonthYearPicker> createState() => _MonthYearPickerState();
}

class _MonthYearPickerState extends State<_MonthYearPicker> {
  late int _year = widget.initial.year;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            FTIconButton(
              icon: AppIcons.back,
              tooltip: 'Previous year',
              size: 40,
              onTap: _year > 1 ? () => setState(() => _year--) : null,
            ),
            Expanded(
              child: Center(child: Text('$_year', style: context.tx.headline)),
            ),
            FTIconButton(
              icon: AppIcons.forward,
              tooltip: 'Next year',
              size: 40,
              onTap: () => setState(() => _year++),
            ),
          ],
        ),
        const SizedBox(height: Gap.md),
        LayoutBuilder(builder: (context, cons) {
          final w = (cons.maxWidth - 2 * Gap.xs) / 3;
          return Wrap(
            spacing: Gap.xs,
            runSpacing: Gap.xs,
            children: [
              for (var m = 1; m <= 12; m++)
                _monthPill(
                  context,
                  w,
                  DateFormat('MMM').format(DateTime(2000, m)),
                  selected: _year == widget.initial.year && m == widget.initial.month,
                  current: _year == now.year && m == now.month,
                  onTap: () => Navigator.of(context).pop(DateTime(_year, m)),
                ),
            ],
          );
        }),
        const SizedBox(height: Gap.md),
        Center(
          child: FTTextAction(
            'Go to today',
            accent: true,
            onTap: () => Navigator.of(context).pop(DateTime(now.year, now.month)),
          ),
        ),
      ],
    );
  }

  Widget _monthPill(BuildContext context, double width, String label,
      {required bool selected, required bool current, required VoidCallback onTap}) {
    final c = context.ft;
    return Semantics(
      selected: selected,
      child: Pressable(
        onTap: onTap,
        semanticLabel: label,
        child: Container(
          width: width,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: selected ? c.accentGradient : null,
            color: selected ? null : (c.isDark ? Colors.white.withValues(alpha: 0.05) : c.surfaceHigh),
            borderRadius: BorderRadius.circular(Radii.pill),
            border: Border.all(
              color: selected ? Colors.transparent : (current ? c.accent.withValues(alpha: 0.7) : c.border),
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.tx.label.copyWith(
              color: selected ? c.onAccent : (current ? c.accent : c.text),
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// Calendar-style date picker sheet (same grid as the calendar screen).
Future<DateTime?> showFTDatePicker(
  BuildContext context, {
  required DateTime initial,
  String title = 'Choose a date',
}) {
  return showFTSheet<DateTime>(
    context,
    title: title,
    builder: (_) => _DatePickerSheet(initial: CalendarMath.dateOnly(initial)),
  );
}

class _DatePickerSheet extends StatefulWidget {
  const _DatePickerSheet({required this.initial});
  final DateTime initial;

  @override
  State<_DatePickerSheet> createState() => _DatePickerSheetState();
}

class _DatePickerSheetState extends State<_DatePickerSheet> {
  late DateTime _month = CalendarMath.firstOfMonth(widget.initial);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MonthHeader(
          month: _month,
          onPrev: () => setState(() => _month = CalendarMath.addMonths(_month, -1)),
          onNext: () => setState(() => _month = CalendarMath.addMonths(_month, 1)),
          onPick: () async {
            final r = await showMonthYearPicker(context, initial: _month);
            if (r != null && mounted) setState(() => _month = r);
          },
        ),
        const SizedBox(height: Gap.md),
        MonthGrid(
          month: _month,
          selected: widget.initial,
          today: CalendarMath.dateOnly(DateTime.now()),
          onSelect: (d) => Navigator.of(context).pop(d),
        ),
      ],
    );
  }
}

/// Pill row for an occasion: avatar(s) or icon, title, subtitle and a
/// trailing label or kind icon (the reference "API Expert … 100%" rows).
class OccasionRow extends ConsumerWidget {
  const OccasionRow({
    super.key,
    required this.occasion,
    required this.onTap,
    this.trailing,
    this.dimmed = false,
  });

  final Occasion occasion;
  final VoidCallback onTap;
  final String? trailing;
  final bool dimmed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ft;
    final t = context.tx;
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final people = [for (final id in occasion.personIds) ?g[id]];
    Widget leading;
    if (people.length == 1) {
      leading = PersonAvatarFor(people.first, size: 44);
    } else if (people.length > 1) {
      leading = AvatarStack(
        people: avatarPairsFor(ref, g, [for (final p in people) p.id]),
        size: 44,
        max: 2,
      );
    } else {
      leading = IconBadge(
        icon: occasionIcon(occasion.kind),
        size: 44,
        accent: occasion.kind == OccasionKind.reminder,
      );
    }
    final sub = occasion.subtitle?.trim();
    return Opacity(
      opacity: dimmed ? 0.55 : 1,
      child: FTPill(
        onTap: onTap,
        semanticLabel: [
          occasion.title,
          if (sub != null && sub.isNotEmpty) sub,
          occasion.kind.label,
          ?trailing,
        ].join(', '),
        padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
        child: Row(
          children: [
            leading,
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(occasion.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStrong),
                  const SizedBox(height: 1),
                  Text(
                    sub == null || sub.isEmpty ? occasion.kind.label : sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(width: Gap.xs),
            if (trailing != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 96),
                child: Text(
                  trailing!,
                  maxLines: 2,
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: t.label.copyWith(color: c.text2),
                ),
              )
            else
              Icon(occasionIcon(occasion.kind), size: 18, color: c.text3),
          ],
        ),
      ),
    );
  }
}
