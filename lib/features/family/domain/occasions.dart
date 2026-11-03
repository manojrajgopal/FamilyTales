import '../../../core/database/app_database.dart';
import '../../../core/models/enums.dart';
import '../../../core/models/fuzzy_date.dart';
import 'family_graph.dart';

enum OccasionKind {
  birthday('Birthday'),
  anniversary('Anniversary'),
  memorial('Memorial'),
  event('Family event'),
  reminder('Reminder');

  const OccasionKind(this.label);
  final String label;
}

/// A dated, possibly recurring family occasion (birthday, anniversary…)
/// occurring on [date].
class Occasion {
  const Occasion({
    required this.kind,
    required this.date,
    required this.title,
    this.subtitle,
    this.personIds = const [],
    this.sourceId,
    this.years,
  });

  final OccasionKind kind;
  final DateTime date;
  final String title;
  final String? subtitle;
  final List<String> personIds;

  /// Id of the person / partnership / event / reminder it comes from.
  final String? sourceId;

  /// Years since the original date (age turning, years married…), if known
  /// exactly.
  final int? years;

  String get key => '${kind.name}:$sourceId:${date.toIso8601String()}';
}

/// Expands people, partnerships, events and reminders into concrete
/// occasions within a date range. Only records whose month AND day are
/// known produce recurring occasions – year-only dates are never turned
/// into invented anniversaries.
class OccasionCalculator {
  OccasionCalculator({
    required this.graph,
    this.events = const [],
    this.eventPeople = const {},
    this.reminders = const [],
  });

  final FamilyGraph graph;
  final List<FamilyEvent> events;
  final Map<String, List<String>> eventPeople;
  final List<Reminder> reminders;

  List<Occasion> between(DateTime start, DateTime end) {
    final from = DateTime(start.year, start.month, start.day);
    final to = DateTime(end.year, end.month, end.day);
    final out = <Occasion>[];

    Iterable<DateTime> yearly(int month, int day) sync* {
      for (var y = from.year; y <= to.year; y++) {
        var d = day;
        // Feb 29 → Feb 28 in non-leap years.
        if (month == 2 && day == 29 && !_isLeap(y)) d = 28;
        final date = DateTime(y, month, d);
        if (!date.isBefore(from) && !date.isAfter(to)) yield date;
      }
    }

    for (final p in graph.people.values) {
      final b = p.birth;
      if (b != null && b.hasMonthDay) {
        for (final d in yearly(b.month!, b.day!)) {
          final years = (b.qualifier == DateQualifier.exact && b.year != null) ? d.year - b.year! : null;
          if (p.isLiving) {
            out.add(Occasion(
              kind: OccasionKind.birthday,
              date: d,
              title: '${p.displayName}’s birthday',
              subtitle: years != null && years >= 0 ? 'Turns $years' : null,
              personIds: [p.id],
              sourceId: p.id,
              years: years,
            ));
          }
        }
      }
      final de = p.death;
      if (!p.isLiving && de != null && de.hasMonthDay) {
        for (final d in yearly(de.month!, de.day!)) {
          final years = (de.qualifier == DateQualifier.exact && de.year != null) ? d.year - de.year! : null;
          if (years != null && years <= 0) continue;
          out.add(Occasion(
            kind: OccasionKind.memorial,
            date: d,
            title: 'Remembering ${p.displayName}',
            subtitle: years != null ? '$years ${years == 1 ? 'year' : 'years'} since passing' : null,
            personIds: [p.id],
            sourceId: p.id,
            years: years,
          ));
        }
      }
    }

    for (final s in graph.couples) {
      if (s.status != PartnerStatus.current) continue;
      if (s.type == PartnerType.engaged) continue;
      final start = FuzzyDate.tryParse(s.startDate);
      if (start == null || !start.hasMonthDay) continue;
      final a = graph[s.personAId], b = graph[s.personBId];
      if (a == null || b == null) continue;
      for (final d in yearly(start.month!, start.day!)) {
        final years = (start.qualifier == DateQualifier.exact && start.year != null) ? d.year - start.year! : null;
        if (years != null && years <= 0) continue;
        out.add(Occasion(
          kind: OccasionKind.anniversary,
          date: d,
          title: '${a.shortName} & ${b.shortName}',
          subtitle: years != null ? '$years ${years == 1 ? 'year' : 'years'} together' : 'Anniversary',
          personIds: [a.id, b.id],
          sourceId: s.id,
          years: years,
        ));
      }
    }

    for (final e in events) {
      final date = FuzzyDate.tryParse(e.date);
      if (date == null || !date.hasMonthDay) continue;
      if (e.remind) {
        for (final d in yearly(date.month!, date.day!)) {
          // Repeats start from the event itself, never the years before it.
          if (date.year != null && d.year < date.year!) continue;
          out.add(Occasion(
            kind: OccasionKind.event,
            date: d,
            title: e.title,
            subtitle: e.type.label,
            personIds: eventPeople[e.id] ?? const [],
            sourceId: e.id,
            years: date.year != null ? d.year - date.year! : null,
          ));
        }
      } else if (date.isExactDay) {
        final d = date.toDateTime()!;
        if (!d.isBefore(from) && !d.isAfter(to)) {
          out.add(Occasion(
            kind: OccasionKind.event,
            date: d,
            title: e.title,
            subtitle: e.type.label,
            personIds: eventPeople[e.id] ?? const [],
            sourceId: e.id,
          ));
        }
      }
    }

    for (final r in reminders) {
      if (!r.enabled) continue;
      final base = DateTime(r.date.year, r.date.month, r.date.day);
      switch (r.repeat) {
        case ReminderRepeat.none:
          if (!base.isBefore(from) && !base.isAfter(to)) {
            out.add(_reminderOccasion(r, base));
          }
        case ReminderRepeat.yearly:
          for (final d in yearly(base.month, base.day)) {
            if (!d.isBefore(base)) out.add(_reminderOccasion(r, d));
          }
        case ReminderRepeat.monthly:
          var cur = DateTime(from.year, from.month, 1);
          while (!cur.isAfter(to)) {
            final last = DateTime(cur.year, cur.month + 1, 0).day;
            final d = DateTime(cur.year, cur.month, base.day > last ? last : base.day);
            if (!d.isBefore(from) && !d.isAfter(to) && !d.isBefore(base)) {
              out.add(_reminderOccasion(r, d));
            }
            cur = DateTime(cur.year, cur.month + 1, 1);
          }
      }
    }

    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  Occasion _reminderOccasion(Reminder r, DateTime d) => Occasion(
        kind: OccasionKind.reminder,
        date: d,
        title: r.title,
        subtitle: r.notes,
        personIds: r.personId == null ? const [] : [r.personId!],
        sourceId: r.id,
      );

  /// Occasions in the next [days] days, starting today.
  List<Occasion> upcoming({int days = 60, DateTime? now}) {
    final t = now ?? DateTime.now();
    return between(t, t.add(Duration(days: days)));
  }

  static bool _isLeap(int y) => (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
}
