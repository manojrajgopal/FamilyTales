import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/models/fuzzy_date.dart';
import '../family/domain/family_graph.dart';
import '../family/domain/occasions.dart';
import '../search/text_normalize.dart';

/// A label with a count (locations, chart data…).
class LabeledCount {
  const LabeledCount(this.label, this.count);
  final String label;
  final int count;

  @override
  String toString() => '$label: $count';
}

/// Number of recorded births in one decade (e.g. 1950 → "1950s").
class DecadeCount {
  const DecadeCount(this.decade, this.count);
  final int decade;
  final int count;
  String get label => '${decade}s';
}

/// The earliest recorded birth in the tree.
class EarliestBirth {
  const EarliestBirth(this.person, this.date);
  final Person person;
  final FuzzyDate date;
  int get year => date.approxYear!;
}

/// An upcoming birthday / anniversary / memorial, with round-number
/// highlighting (50th birthday, 25th anniversary…).
class Milestone {
  const Milestone(this.occasion, {required this.isRound});
  final Occasion occasion;
  final bool isRound;
  int? get years => occasion.years;

  /// "50th birthday", "25th anniversary", "10 years since passing"…
  String? get headline {
    final y = years;
    if (y == null || y <= 0) return null;
    return switch (occasion.kind) {
      OccasionKind.birthday => '${ordinal(y)} birthday',
      OccasionKind.anniversary => '${ordinal(y)} anniversary',
      OccasionKind.memorial => '$y ${y == 1 ? 'year' : 'years'} since passing',
      OccasionKind.event => '${ordinal(y)} anniversary',
      OccasionKind.reminder => null,
    };
  }
}

/// "1st", "2nd", "3rd", "11th", "22nd"…
String ordinal(int n) {
  final mod100 = n % 100;
  if (mod100 >= 11 && mod100 <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  };
}

/// Whether [years] is a "round" milestone worth highlighting for [kind].
bool isRoundMilestone(OccasionKind kind, int? years) {
  if (years == null || years <= 0) return false;
  return switch (kind) {
    // 10th, 20th, 25th, 30th … 50th, 75th, 100th birthdays.
    OccasionKind.birthday => years >= 10 && (years % 10 == 0 || years % 25 == 0),
    // 1st, 5th, 10th, 15th … 25th, 40th, 50th anniversaries.
    OccasionKind.anniversary => years == 1 || years % 5 == 0,
    OccasionKind.memorial => years == 10 || years % 25 == 0,
    OccasionKind.event => years % 25 == 0,
    OccasionKind.reminder => false,
  };
}

/// Aggregated, read-only statistics for one family tree. Everything is
/// derived from recorded data – unknown values are left out, never guessed.
class FamilyStats {
  const FamilyStats({
    required this.totalMembers,
    required this.generationCount,
    required this.living,
    required this.deceased,
    required this.couples,
    required this.peopleWithChildren,
    required this.parentChildLinks,
    required this.parentCouples,
    required this.averageChildrenPerCouple,
    required this.earliestBirth,
    required this.mostRecentlyAdded,
    required this.topLocations,
    required this.eventCounts,
    required this.totalEvents,
    required this.photos,
    required this.documents,
    required this.stories,
    required this.peoplePerGeneration,
    required this.birthsPerDecade,
    required this.knownBirthYears,
    required this.genders,
    required this.milestones,
    required this.oldestGeneration,
  });

  final int totalMembers;
  final int generationCount;
  final int living;
  final int deceased;

  /// Recorded partnerships (any status).
  final int couples;

  /// People with at least one recorded child.
  final int peopleWithChildren;

  /// Number of parent → child links.
  final int parentChildLinks;

  /// Distinct pairs of parents sharing at least one child.
  final int parentCouples;

  /// Average children per parent couple; null unless at least two parent
  /// couples are recorded (a single family is not an "average").
  final double? averageChildrenPerCouple;
  final EarliestBirth? earliestBirth;
  final Person? mostRecentlyAdded;

  /// Up to five most frequent places (birth/death places and event
  /// locations), compared case- and accent-insensitively.
  final List<LabeledCount> topLocations;

  /// Events per type, most frequent first.
  final List<(EventType, int)> eventCounts;
  final int totalEvents;
  final int photos;
  final int documents;
  final int stories;

  /// Index = generation (0 = oldest).
  final List<int> peoplePerGeneration;

  /// Consecutive decades from the earliest to the latest recorded birth
  /// (decades without births are included with a zero count).
  final List<DecadeCount> birthsPerDecade;

  /// People whose birth year is known (at least approximately).
  final int knownBirthYears;
  final Map<Gender, int> genders;
  final List<Milestone> milestones;

  /// People in the topmost generation of the largest connected family,
  /// oldest recorded birth first.
  final List<String> oldestGeneration;

  bool get isEmpty => totalMembers == 0;

  int get specifiedGenders => genders.entries
      .where((e) => e.key != Gender.unknown)
      .fold(0, (a, e) => a + e.value);

  static FamilyStats compute({
    required FamilyGraph graph,
    List<FamilyEvent> events = const [],
    Map<String, List<String>> eventPeople = const {},
    List<MediaAsset> media = const [],
    List<Story> stories = const [],
    DateTime? now,
    int milestoneDays = 120,
  }) {
    final people = graph.people.values.toList();

    // ------------------------------------------------------------ basics
    var living = 0;
    var deceased = 0;
    final genders = <Gender, int>{};
    Person? newest;
    EarliestBirth? earliest;
    final decades = <int, int>{};
    var knownYears = 0;
    for (final p in people) {
      if (p.isLiving) {
        living++;
      } else {
        deceased++;
      }
      genders[p.gender] = (genders[p.gender] ?? 0) + 1;
      if (newest == null || p.createdAt.isAfter(newest.createdAt)) newest = p;
      final b = p.birth;
      final y = b?.approxYear;
      if (b != null && y != null) {
        knownYears++;
        final d = (y ~/ 10) * 10;
        decades[d] = (decades[d] ?? 0) + 1;
        if (earliest == null || b.sortKey < earliest.date.sortKey) {
          earliest = EarliestBirth(p, b);
        }
      }
    }

    // ------------------------------------------------------ relationships
    var withChildren = 0;
    for (final p in people) {
      if (graph.childIds(p.id, lineageOnly: true).isNotEmpty) withChildren++;
    }
    final perCouple = <String, int>{};
    for (final p in people) {
      final parents = graph.kinParents(p.id).toSet().toList()..sort();
      if (parents.length != 2) continue;
      final key = parents.join('|');
      perCouple[key] = (perCouple[key] ?? 0) + 1;
    }
    final avg = perCouple.length >= 2
        ? perCouple.values.fold<int>(0, (a, b) => a + b) / perCouple.length
        : null;

    // ------------------------------------------------------------ places
    final placeCounts = <String, Map<String, int>>{};
    void addPlace(String? raw) {
      if (raw == null) return;
      final label = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
      final key = normalizeKey(label);
      if (key.isEmpty) return;
      final variants = placeCounts[key] ??= {};
      variants[label] = (variants[label] ?? 0) + 1;
    }

    for (final p in people) {
      addPlace(p.birthPlace);
      addPlace(p.deathPlace);
    }
    for (final e in events) {
      addPlace(e.location);
    }
    final places = placeCounts.values.map((variants) {
      // Most frequent spelling; ties go to the first one recorded.
      var total = 0;
      MapEntry<String, int>? best;
      for (final e in variants.entries) {
        total += e.value;
        if (best == null || e.value > best.value) best = e;
      }
      return LabeledCount(best!.key, total);
    }).toList()
      ..sort((a, b) {
        final c = b.count.compareTo(a.count);
        return c != 0 ? c : a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });

    // ------------------------------------------------------------ events
    final byType = <EventType, int>{};
    for (final e in events) {
      byType[e.type] = (byType[e.type] ?? 0) + 1;
    }
    final eventCounts = byType.entries.map((e) => (e.key, e.value)).toList()
      ..sort((a, b) {
        final c = b.$2.compareTo(a.$2);
        return c != 0 ? c : a.$1.index.compareTo(b.$1.index);
      });

    // -------------------------------------------------------- generations
    final perGeneration = <int>[];
    if (people.isNotEmpty) {
      final gens = graph.generations();
      for (final g in gens.values) {
        while (perGeneration.length <= g) {
          perGeneration.add(0);
        }
        perGeneration[g]++;
      }
    }

    final oldest = <String>[];
    if (people.isNotEmpty) {
      final gens = graph.generations();
      final largest = graph.components().first;
      for (final id in largest) {
        if (gens[id] == 0) oldest.add(id);
      }
      oldest.sort((a, b) {
        final ka = graph[a]!.birth?.sortKey ?? double.infinity;
        final kb = graph[b]!.birth?.sortKey ?? double.infinity;
        final c = ka.compareTo(kb);
        return c != 0
            ? c
            : graph[a]!.displayName.toLowerCase().compareTo(graph[b]!.displayName.toLowerCase());
      });
    }

    // ------------------------------------------------------------ decades
    final birthsPerDecade = <DecadeCount>[];
    if (decades.isNotEmpty) {
      final keys = decades.keys.toList()..sort();
      for (var d = keys.first; d <= keys.last; d += 10) {
        birthsPerDecade.add(DecadeCount(d, decades[d] ?? 0));
      }
    }

    // --------------------------------------------------------- milestones
    final occasions = OccasionCalculator(
      graph: graph,
      events: events,
      eventPeople: eventPeople,
    ).upcoming(days: milestoneDays, now: now);
    final milestones = [
      for (final o in occasions)
        if (o.kind != OccasionKind.reminder)
          Milestone(o, isRound: isRoundMilestone(o.kind, o.years)),
    ];

    return FamilyStats(
      totalMembers: people.length,
      generationCount: graph.generationCount(),
      living: living,
      deceased: deceased,
      couples: graph.couples.length,
      peopleWithChildren: withChildren,
      parentChildLinks: graph.links.length,
      parentCouples: perCouple.length,
      averageChildrenPerCouple: avg,
      earliestBirth: earliest,
      mostRecentlyAdded: newest,
      topLocations: places.take(5).toList(),
      eventCounts: eventCounts,
      totalEvents: events.length,
      photos: media.where((m) => m.kind == MediaKind.photo).length,
      documents: media.where((m) => m.kind == MediaKind.document).length,
      stories: stories.length,
      peoplePerGeneration: perGeneration,
      birthsPerDecade: birthsPerDecade,
      knownBirthYears: knownYears,
      genders: genders,
      milestones: milestones,
      oldestGeneration: oldest,
    );
  }
}
