import '../../app/settings.dart';
import '../../core/database/app_database.dart';
import '../family/domain/occasions.dart';

/// A one-shot local notification to schedule.
class PlannedNotification {
  const PlannedNotification({
    required this.id,
    required this.when,
    required this.title,
    required this.body,
    required this.occasion,
    required this.leadDays,
    this.payload,
  });

  /// Platform notification id (unique within one plan).
  final int id;

  /// Local wall-clock time to deliver at.
  final DateTime when;
  final String title;
  final String body;
  final Occasion occasion;

  /// Days before the occasion (0 = on the day).
  final int leadDays;

  /// Navigation hint handled when the notification is tapped:
  /// `person:<id>`, `event:<id>` or `calendar`.
  final String? payload;

  /// Compact identity used to skip redundant reschedules.
  String get signature => '$id|${when.toIso8601String()}|$title|$body|$payload';
}

/// Turns family occasions into the next batch of one-shot notifications
/// according to the user's notification preferences. Pure Dart.
abstract final class NotificationPlanner {
  /// How far ahead notifications are scheduled.
  static const horizonDays = 60;

  /// Pending notification cap (iOS allows 64 per app).
  static const maxPending = 60;

  /// First id used for planned notifications.
  static const firstId = 1000;

  static bool kindEnabled(OccasionKind k, AppPrefs p) => switch (k) {
        OccasionKind.birthday => p.notifyBirthdays,
        OccasionKind.anniversary => p.notifyAnniversaries,
        OccasionKind.memorial => p.notifyMemorials,
        OccasionKind.event => p.notifyEvents,
        OccasionKind.reminder => p.notifyCustom,
      };

  /// Notifications due after [now] and within [horizonDays], ordered by time
  /// and capped at [max]. Ignores `notificationsEnabled` so the settings
  /// screen can preview the plan; callers decide whether to schedule it.
  static List<PlannedNotification> plan({
    required OccasionCalculator calculator,
    required AppPrefs prefs,
    DateTime? now,
    int horizon = horizonDays,
    int max = maxPending,
  }) =>
      planAll(calculators: [calculator], prefs: prefs, now: now, horizon: horizon, max: max);

  /// Like [plan], across several trees (one calculator each), so switching
  /// trees never drops another tree's notifications.
  static List<PlannedNotification> planAll({
    required List<OccasionCalculator> calculators,
    required AppPrefs prefs,
    DateTime? now,
    int horizon = horizonDays,
    int max = maxPending,
  }) {
    final t = now ?? DateTime.now();
    final leads = prefs.reminderLeads.toList()..sort((a, b) => a.days.compareTo(b.days));
    if (leads.isEmpty) return const [];
    final maxLead = leads.last.days;
    final today = DateTime(t.year, t.month, t.day);
    final limit = t.add(Duration(days: horizon));
    final hour = prefs.notifyHour.clamp(0, 23);
    final reminders = <String, Reminder>{
      for (final c in calculators)
        for (final r in c.reminders) r.id: r,
    };

    final occasions = [
      for (final c in calculators)
        ...c.between(today, DateTime(today.year, today.month, today.day + horizon + maxLead)),
    ];

    final draft = <(DateTime, String, String, Occasion, int, String?)>[];
    for (final o in occasions) {
      if (!kindEnabled(o.kind, prefs)) continue;
      for (final lead in leads) {
        final day = DateTime(o.date.year, o.date.month, o.date.day - lead.days);
        final r = o.kind == OccasionKind.reminder ? reminders[o.sourceId] : null;
        // Custom reminders keep their own time on the day itself.
        final when = (r != null && lead.days == 0)
            ? DateTime(day.year, day.month, day.day, r.date.hour, r.date.minute)
            : DateTime(day.year, day.month, day.day, hour);
        if (!when.isAfter(t) || when.isAfter(limit)) continue;
        draft.add((when, titleFor(o), bodyFor(o, lead.days), o, lead.days, payloadFor(o)));
      }
    }
    draft.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
    final out = <PlannedNotification>[];
    for (var i = 0; i < draft.length && out.length < max; i++) {
      final d = draft[i];
      out.add(PlannedNotification(
        id: firstId + out.length,
        when: d.$1,
        title: d.$2,
        body: d.$3,
        occasion: d.$4,
        leadDays: d.$5,
        payload: d.$6,
      ));
    }
    return out;
  }

  static String titleFor(Occasion o) => switch (o.kind) {
        OccasionKind.anniversary => 'Anniversary: ${o.title}',
        _ => o.title,
      };

  static String leadLabel(int days) => switch (days) {
        0 => 'Today',
        1 => 'Tomorrow',
        7 => 'In one week',
        _ => 'In $days days',
      };

  static String bodyFor(Occasion o, int leadDays) {
    var sub = o.subtitle?.trim();
    if (sub != null && sub.length > 120) sub = '${sub.substring(0, 117)}…';
    final lead = leadLabel(leadDays);
    return sub == null || sub.isEmpty ? lead : '$lead · $sub';
  }

  static String? payloadFor(Occasion o) {
    switch (o.kind) {
      case OccasionKind.birthday:
      case OccasionKind.memorial:
      case OccasionKind.anniversary:
        return o.personIds.isEmpty ? 'calendar' : 'person:${o.personIds.first}';
      case OccasionKind.event:
        return o.sourceId == null ? 'calendar' : 'event:${o.sourceId}';
      case OccasionKind.reminder:
        return 'calendar';
    }
  }
}
