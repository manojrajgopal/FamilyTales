import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/repositories/content_repository.dart';
import '../events/event_logic.dart';
import '../family/domain/family_graph.dart';

/// Kinds of milestones shown on the family timeline (also the filters).
enum TimelineCategory {
  birth('Births'),
  marriage('Marriages'),
  death('Deaths'),
  event('Events'),
  story('Stories'),
  photo('Photos');

  const TimelineCategory(this.label);
  final String label;
}

/// What a timeline item opens when tapped.
enum TimelineTarget { person, event, story, media }

/// One milestone on the timeline. Dates are kept as [FuzzyDate]s so their
/// precision and qualifier ("c.", "before", ranges) are never lost.
class TimelineItem {
  const TimelineItem({
    required this.key,
    required this.category,
    required this.date,
    required this.title,
    required this.target,
    required this.targetId,
    this.subtitle,
    this.location,
    this.personIds = const [],
    this.eventType,
  });

  /// Stable unique key (category + source id).
  final String key;
  final TimelineCategory category;
  final FuzzyDate? date;
  final String title;
  final String? subtitle;
  final String? location;
  final List<String> personIds;
  final TimelineTarget target;

  /// Person / event / story / media id to open.
  final String targetId;

  /// Event type (for the icon) when [category] is [TimelineCategory.event].
  final EventType? eventType;

  /// The (approximate) year, or null when the date has no usable year.
  int? get year => date?.approxYear;

  /// Start year of the decade, or null for undated items.
  int? get decade {
    final y = year;
    return y == null ? null : y - (y % 10);
  }

  bool get isDated => year != null;

  double get sortKey => isDated ? date!.sortKey : double.infinity;

  /// Display date with its qualifier, e.g. "c. 1920", "before Mar 1931".
  String get dateLabel {
    final d = date;
    if (d == null || d.isEmpty) return 'Date unknown';
    final s = d.format();
    return s.isEmpty ? 'Date unknown' : s;
  }

  @override
  String toString() => 'TimelineItem($key, $dateLabel, $title)';
}

enum TimelineScopeKind {
  family('Entire family'),
  person('One person'),
  branch('Branch'),
  generation('Generation');

  const TimelineScopeKind(this.label);
  final String label;
}

/// Which part of the family the timeline covers.
class TimelineScope {
  const TimelineScope.family()
      : kind = TimelineScopeKind.family,
        id = null,
        generation = null;
  const TimelineScope.person(String personId)
      : kind = TimelineScopeKind.person,
        id = personId,
        generation = null;
  const TimelineScope.branch(String branchId)
      : kind = TimelineScopeKind.branch,
        id = branchId,
        generation = null;
  const TimelineScope.generation(int this.generation)
      : kind = TimelineScopeKind.generation,
        id = null;

  final TimelineScopeKind kind;

  /// Person id or branch id.
  final String? id;

  /// 0-based generation index (see [FamilyGraph.generations]).
  final int? generation;

  @override
  bool operator ==(Object other) =>
      other is TimelineScope &&
      other.kind == kind &&
      other.id == id &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(kind, id, generation);
}

/// A row of the grouped timeline.
sealed class TimelineRow {
  const TimelineRow();
}

class TimelineYearRow extends TimelineRow {
  const TimelineYearRow(this.year, this.count);
  final int year;
  final int count;
}

class TimelineItemRow extends TimelineRow {
  const TimelineItemRow(this.item, {required this.lastInGroup});
  final TimelineItem item;

  /// True for the last item before the next year header / section end.
  final bool lastInGroup;
}

/// A decade of the timeline (or the trailing "Undated" section when
/// [decade] is null), already flattened into year headers and items.
class TimelineSection {
  const TimelineSection(this.decade, this.rows, this.itemCount);
  final int? decade;
  final List<TimelineRow> rows;
  final int itemCount;

  String get label => decade == null ? 'Undated' : '${decade}s';
}

/// Derives a chronological family timeline from people, partnerships,
/// events, stories and photos. Pure Dart (no widgets) so it can be tested.
class TimelineBuilder {
  TimelineBuilder({
    required this.graph,
    this.events = const [],
    this.stories = const [],
    this.storyPeople = const [],
    this.media = const [],
    this.mediaPeople = const [],
    this.branches = const [],
    this.branchMembers = const [],
  });

  final FamilyGraph graph;
  final List<EventWithPeople> events;
  final List<Story> stories;
  final List<StoryPerson> storyPeople;
  final List<MediaAsset> media;
  final List<MediaPerson> mediaPeople;
  final List<FamilyBranch> branches;
  final List<PersonBranch> branchMembers;

  /// Members of a branch: explicit members ∪ the root person and all of the
  /// root's descendants.
  static Set<String> membersOfBranch(
    FamilyBranch branch,
    List<PersonBranch> links,
    FamilyGraph graph,
  ) {
    final out = <String>{
      for (final l in links)
        if (l.branchId == branch.id && graph.contains(l.personId)) l.personId,
    };
    final root = branch.rootPersonId;
    if (root != null && graph.contains(root)) {
      out
        ..add(root)
        ..addAll(graph.descendants(root));
    }
    return out;
  }

  /// Distinct generation indexes present in the graph, oldest first.
  List<int> generationIndexes() =>
      graph.generations().values.toSet().toList()..sort();

  /// The people covered by [scope], or null for the entire family.
  Set<String>? peopleIn(TimelineScope scope) {
    switch (scope.kind) {
      case TimelineScopeKind.family:
        return null;
      case TimelineScopeKind.person:
        final id = scope.id;
        return id != null && graph.contains(id) ? {id} : <String>{};
      case TimelineScopeKind.branch:
        final b = branches.where((x) => x.id == scope.id).firstOrNull;
        return b == null ? <String>{} : membersOfBranch(b, branchMembers, graph);
      case TimelineScopeKind.generation:
        final gen = graph.generations();
        return {
          for (final e in gen.entries)
            if (e.value == scope.generation) e.key,
        };
    }
  }

  /// All items for [scope] and [categories], sorted chronologically with
  /// undated items last.
  List<TimelineItem> build({
    TimelineScope scope = const TimelineScope.family(),
    Set<TimelineCategory>? categories,
  }) {
    final cats = categories ?? TimelineCategory.values.toSet();
    final who = peopleIn(scope);
    bool inScope(Iterable<String> ids) =>
        who == null || ids.any(who.contains);
    final out = <TimelineItem>[];

    // ------------------------------------------------ births and deaths
    if (cats.contains(TimelineCategory.birth) ||
        cats.contains(TimelineCategory.death)) {
      for (final p in graph.people.values) {
        if (who != null && !who.contains(p.id)) continue;
        final b = p.birth;
        if (cats.contains(TimelineCategory.birth) && b != null && !b.isEmpty) {
          out.add(TimelineItem(
            key: 'birth:${p.id}',
            category: TimelineCategory.birth,
            date: b,
            title: p.displayName,
            subtitle: _place('Born', p.birthPlace),
            location: _clean(p.birthPlace),
            personIds: [p.id],
            target: TimelineTarget.person,
            targetId: p.id,
          ));
        }
        final d = p.death;
        if (cats.contains(TimelineCategory.death) &&
            !p.isLiving &&
            d != null &&
            !d.isEmpty) {
          final age = AgeSpan.between(b, d);
          final base = _place('Passed away', p.deathPlace);
          out.add(TimelineItem(
            key: 'death:${p.id}',
            category: TimelineCategory.death,
            date: d,
            title: p.displayName,
            subtitle: age == null ? base : '$base, aged ${age.format()}',
            location: _clean(p.deathPlace),
            personIds: [p.id],
            target: TimelineTarget.person,
            targetId: p.id,
          ));
        }
      }
    }

    // ------------------------------------------- marriages / partnerships
    if (cats.contains(TimelineCategory.marriage)) {
      for (final s in graph.couples) {
        if (!inScope([s.personAId, s.personBId])) continue;
        final start = FuzzyDate.tryParse(s.startDate);
        if (start == null || start.isEmpty) continue;
        final a = graph[s.personAId], b = graph[s.personBId];
        if (a == null || b == null) continue;
        final verb = switch (s.type) {
          PartnerType.marriage => 'Married',
          PartnerType.civilUnion => 'Civil union',
          PartnerType.partner => 'Became partners',
          PartnerType.engaged => 'Engaged',
        };
        out.add(TimelineItem(
          key: 'partnership:${s.id}',
          category: TimelineCategory.marriage,
          date: start,
          title: '${a.displayName} & ${b.displayName}',
          subtitle: _place(verb, s.place),
          location: _clean(s.place),
          personIds: [a.id, b.id],
          // Opens the person in scope (or the first partner).
          target: TimelineTarget.person,
          targetId: who != null && !who.contains(a.id) ? b.id : a.id,
        ));
      }
    }

    // ------------------------------------------------------------ events
    if (cats.contains(TimelineCategory.event)) {
      for (final e in events) {
        if (who != null && !inScope(e.personIds)) continue;
        final ev = e.event;
        final d = ev.fuzzyDate;
        out.add(TimelineItem(
          key: 'event:${ev.id}',
          category: TimelineCategory.event,
          date: d == null || d.isEmpty ? null : d,
          title: ev.title,
          subtitle: _place(ev.typeLabel, ev.location),
          location: _clean(ev.location),
          personIds: [for (final id in e.personIds) if (graph.contains(id)) id],
          target: TimelineTarget.event,
          targetId: ev.id,
          eventType: ev.type,
        ));
      }
    }

    // ----------------------------------------------------------- stories
    if (cats.contains(TimelineCategory.story)) {
      final byStory = <String, List<String>>{};
      for (final sp in storyPeople) {
        (byStory[sp.storyId] ??= []).add(sp.personId);
      }
      for (final s in stories) {
        final d = FuzzyDate.tryParse(s.historicalDate);
        if (d == null || d.isEmpty) continue;
        final people = [
          for (final id in byStory[s.id] ?? const <String>[])
            if (graph.contains(id)) id,
        ];
        if (who != null && !inScope(people)) continue;
        out.add(TimelineItem(
          key: 'story:${s.id}',
          category: TimelineCategory.story,
          date: d,
          title: s.title,
          subtitle: 'Story',
          personIds: people,
          target: TimelineTarget.story,
          targetId: s.id,
        ));
      }
    }

    // ------------------------------------------------------------ photos
    if (cats.contains(TimelineCategory.photo)) {
      final byMedia = <String, List<String>>{};
      for (final mp in mediaPeople) {
        (byMedia[mp.mediaId] ??= []).add(mp.personId);
      }
      for (final m in media) {
        if (m.kind != MediaKind.photo || m.deletedAt != null) continue;
        final d = FuzzyDate.tryParse(m.date);
        if (d == null || d.isEmpty) continue;
        final people = [
          for (final id in byMedia[m.id] ?? const <String>[])
            if (graph.contains(id)) id,
        ];
        if (who != null && !inScope(people)) continue;
        final caption = _clean(m.caption);
        out.add(TimelineItem(
          key: 'photo:${m.id}',
          category: TimelineCategory.photo,
          date: d,
          title: caption ?? 'Photo',
          subtitle: _place('Photo', m.location),
          location: _clean(m.location),
          personIds: people,
          target: TimelineTarget.media,
          targetId: m.id,
        ));
      }
    }

    out.sort(compare);
    return out;
  }

  /// Chronological order; undated last; ties by category then title.
  static int compare(TimelineItem a, TimelineItem b) {
    final c = a.sortKey.compareTo(b.sortKey);
    if (c != 0) return c;
    final k = a.category.index.compareTo(b.category.index);
    if (k != 0) return k;
    return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  }

  /// Groups sorted [items] into decades with year headers. Undated items
  /// form a final section with no year headers.
  static List<TimelineSection> group(List<TimelineItem> items) {
    final dated = <int, List<TimelineItem>>{};
    final undated = <TimelineItem>[];
    for (final i in items) {
      final d = i.decade;
      if (d == null) {
        undated.add(i);
      } else {
        (dated[d] ??= []).add(i);
      }
    }
    final sections = <TimelineSection>[];
    for (final decade in dated.keys.toList()..sort()) {
      final list = dated[decade]!;
      final rows = <TimelineRow>[];
      for (var i = 0; i < list.length; i++) {
        final y = list[i].year!;
        if (i == 0 || list[i - 1].year != y) {
          rows.add(TimelineYearRow(y, list.where((x) => x.year == y).length));
        }
        final last = i == list.length - 1 || list[i + 1].year != y;
        rows.add(TimelineItemRow(list[i], lastInGroup: last));
      }
      sections.add(TimelineSection(decade, rows, list.length));
    }
    if (undated.isNotEmpty) {
      sections.add(TimelineSection(null, [
        for (var i = 0; i < undated.length; i++)
          TimelineItemRow(undated[i], lastInGroup: i == undated.length - 1),
      ], undated.length));
    }
    return sections;
  }

  static String? _clean(String? s) {
    final t = s?.trim();
    return t == null || t.isEmpty ? null : t;
  }

  static String _place(String verb, String? place) {
    final p = _clean(place);
    return p == null ? verb : '$verb · $p';
  }
}
