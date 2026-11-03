import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/repositories/content_repository.dart';
import '../family/domain/family_graph.dart';

/// Display helpers for the generated [FamilyEvent] data class.
extension FamilyEventX on FamilyEvent {
  FuzzyDate? get fuzzyDate => FuzzyDate.tryParse(date);

  /// The type label, or the user's own label for [EventType.custom].
  String get typeLabel {
    final custom = customLabel?.trim();
    if (type == EventType.custom && custom != null && custom.isNotEmpty) {
      return custom;
    }
    return type.label;
  }

  /// Formatted date, or null when unknown.
  String? get dateLabel {
    final d = fuzzyDate;
    if (d == null || d.isEmpty) return null;
    final s = d.format();
    return s.isEmpty ? null : s;
  }
}

/// A year bucket of the event list. [year] is null for undated events.
class EventYearGroup {
  const EventYearGroup(this.year, this.events);
  final int? year;
  final List<EventWithPeople> events;

  String get label => year?.toString() ?? 'Undated';
}

/// Searching, filtering, grouping and sharing of family events. Pure Dart so
/// it can be unit tested without widgets.
abstract final class EventQuery {
  /// Events matching [query] (title, type, place, description, date and
  /// participant names) and, when given, of [type].
  static List<EventWithPeople> filter(
    List<EventWithPeople> all, {
    String query = '',
    EventType? type,
    FamilyGraph? graph,
  }) {
    final q = query.trim().toLowerCase();
    return [
      for (final e in all)
        if ((type == null || e.event.type == type) &&
            (q.isEmpty || _haystack(e, graph).contains(q)))
          e,
    ];
  }

  static String _haystack(EventWithPeople e, FamilyGraph? graph) {
    final ev = e.event;
    return [
      ev.title,
      ev.typeLabel,
      ev.location,
      ev.description,
      ev.dateLabel,
      for (final id in e.personIds) graph?[id]?.displayName,
      for (final r in e.roles.values) r,
    ].whereType<String>().join(' ').toLowerCase();
  }

  /// Groups by (approximate) year, newest year first, undated last. Within a
  /// year events are ordered newest first by their fuzzy sort key.
  static List<EventYearGroup> groupByYear(List<EventWithPeople> events) {
    final byYear = <int?, List<EventWithPeople>>{};
    for (final e in events) {
      (byYear[e.event.fuzzyDate?.approxYear] ??= []).add(e);
    }
    final years = byYear.keys.whereType<int>().toList()
      ..sort((a, b) => b.compareTo(a));
    int byKey(EventWithPeople a, EventWithPeople b) {
      final ka = a.event.fuzzyDate?.sortKey ?? double.infinity;
      final kb = b.event.fuzzyDate?.sortKey ?? double.infinity;
      final c = kb.compareTo(ka);
      return c != 0
          ? c
          : a.event.title.toLowerCase().compareTo(b.event.title.toLowerCase());
    }

    return [
      for (final y in years) EventYearGroup(y, byYear[y]!..sort(byKey)),
      if (byYear.containsKey(null))
        EventYearGroup(
          null,
          byYear[null]!
            ..sort((a, b) => a.event.title
                .toLowerCase()
                .compareTo(b.event.title.toLowerCase())),
        ),
    ];
  }

  /// The event types that occur in [events], in enum order.
  static List<EventType> typesIn(List<EventWithPeople> events) {
    final present = {for (final e in events) e.event.type};
    return [for (final t in EventType.values) if (present.contains(t)) t];
  }

  /// Plain-text summary used by the share sheet.
  static String shareText(EventWithPeople e, FamilyGraph? graph) {
    final ev = e.event;
    final b = StringBuffer(ev.title.trim());
    b.writeln();
    b.writeln(ev.typeLabel);
    final date = ev.fuzzyDate;
    if (date != null && !date.isEmpty) b.writeln(date.format(long: true));
    final loc = ev.location?.trim();
    if (loc != null && loc.isNotEmpty) b.writeln(loc);
    final names = [
      for (final id in e.personIds)
        if (graph?[id] != null)
          _withRole(graph![id]!.displayName, e.roles[id]),
    ];
    if (names.isNotEmpty) {
      b.writeln();
      b.writeln('With ${names.join(', ')}');
    }
    final desc = ev.description?.trim();
    if (desc != null && desc.isNotEmpty) {
      b.writeln();
      b.writeln(desc);
    }
    b.writeln();
    b.write('Shared from Family Tales');
    return b.toString();
  }

  static String _withRole(String name, String? role) {
    final r = role?.trim();
    return r == null || r.isEmpty ? name : '$name ($r)';
  }
}
