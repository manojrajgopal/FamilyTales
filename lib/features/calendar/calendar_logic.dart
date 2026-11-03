import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/database/app_database.dart';
import '../../core/repositories/content_repository.dart';
import '../family/domain/family_graph.dart';
import '../family/domain/occasions.dart';

/// Builds an [OccasionCalculator] from the app's data streams.
OccasionCalculator buildOccasionCalculator(
  FamilyGraph graph,
  List<EventWithPeople> events,
  List<Reminder> reminders,
) =>
    OccasionCalculator(
      graph: graph,
      events: [for (final e in events) e.event],
      eventPeople: {for (final e in events) e.event.id: e.personIds},
      reminders: reminders,
    );

/// The occasion calculator for the active tree; loading until people,
/// events and reminders are available.
final occasionCalculatorProvider = Provider<AsyncValue<OccasionCalculator>>((ref) {
  final g = ref.watch(familyGraphProvider);
  final e = ref.watch(eventsWithPeopleProvider);
  final r = ref.watch(remindersProvider);
  for (final a in <AsyncValue<Object?>>[g, e, r]) {
    if (a.hasError) return AsyncError(a.error!, a.stackTrace ?? StackTrace.current);
  }
  if (!g.hasValue || !e.hasValue || !r.hasValue) return const AsyncLoading();
  return AsyncData(buildOccasionCalculator(g.value!, e.value!, r.value!));
});

/// Plural filter labels used by the calendar chips.
String occasionFilterLabel(OccasionKind k) => switch (k) {
      OccasionKind.birthday => 'Birthdays',
      OccasionKind.anniversary => 'Anniversaries',
      OccasionKind.memorial => 'Memorials',
      OccasionKind.event => 'Events',
      OccasionKind.reminder => 'Reminders',
    };

/// Date-only helpers for the month grid. Weeks start on Monday, matching
/// the MON … SUN header of the design.
abstract final class CalendarMath {
  static DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime firstOfMonth(DateTime d) => DateTime(d.year, d.month);

  static DateTime addMonths(DateTime month, int n) =>
      DateTime(month.year, month.month + n);

  static bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

  /// Every day shown in the month grid: whole weeks from the Monday on or
  /// before the 1st to the Sunday on or after the last day (5 or 6 weeks).
  static List<DateTime> gridDays(DateTime month) {
    final first = firstOfMonth(month);
    final lead = (first.weekday - DateTime.monday) % 7;
    final count = lead + daysInMonth(first.year, first.month);
    final weeks = (count / 7).ceil();
    return [
      for (var i = 0; i < weeks * 7; i++) DateTime(first.year, first.month, 1 - lead + i),
    ];
  }

  /// Occasions keyed by their (date-only) day.
  static Map<DateTime, List<Occasion>> byDay(Iterable<Occasion> occasions) {
    final out = <DateTime, List<Occasion>>{};
    for (final o in occasions) {
      (out[dateOnly(o.date)] ??= []).add(o);
    }
    return out;
  }

  /// "Today", "Tomorrow", "In 5 days", "Yesterday", "3 days ago".
  static String relativeDay(DateTime day, DateTime today) {
    final d = DateTime.utc(day.year, day.month, day.day)
        .difference(DateTime.utc(today.year, today.month, today.day))
        .inDays;
    if (d == 0) return 'Today';
    if (d == 1) return 'Tomorrow';
    if (d == -1) return 'Yesterday';
    if (d > 1) return 'In $d days';
    return '${-d} days ago';
  }
}
