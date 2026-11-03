import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/models/enums.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../family/domain/occasions.dart';
import '../members/widgets/person_widgets.dart';
import 'family_stats.dart';
import 'insight_charts.dart';

/// Statistics for the active tree, recomputed whenever people, events,
/// media or stories change.
final familyStatsProvider = Provider.autoDispose<AsyncValue<FamilyStats>>((ref) {
  final g = ref.watch(familyGraphProvider);
  final ev = ref.watch(eventsWithPeopleProvider);
  final media = ref.watch(mediaProvider);
  final stories = ref.watch(storiesProvider);
  for (final a in <AsyncValue<Object?>>[g, ev, media, stories]) {
    if (a.hasError) return AsyncError(a.error!, a.stackTrace ?? StackTrace.empty);
  }
  if (!g.hasValue || !ev.hasValue || !media.hasValue || !stories.hasValue) {
    return const AsyncLoading();
  }
  final events = ev.value!;
  return AsyncData(FamilyStats.compute(
    graph: g.value!,
    events: [for (final e in events) e.event],
    eventPeople: {for (final e in events) e.event.id: e.personIds},
    media: media.value!,
    stories: stories.value!,
  ));
});

class InsightsScreen extends ConsumerStatefulWidget {
  const InsightsScreen({super.key});

  @override
  ConsumerState<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends ConsumerState<InsightsScreen> {
  bool _allMilestones = false;
  bool _allOldest = false;

  @override
  Widget build(BuildContext context) {
    final stats = ref.watch(familyStatsProvider);
    return FTPage(
      title: 'Family insights',
      body: stats.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(familyStatsProvider)),
        data: (s) {
          if (s.isEmpty) {
            return EmptyState(
              icon: AppIcons.stats,
              title: 'No insights yet',
              message: 'Add family members, dates and places to see statistics about your family.',
              actionLabel: 'Add a person',
              onAction: () => context.push(Routes.newPerson()),
            );
          }
          final graph = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
          final sections = _sections(context, s, graph);
          return ListView.builder(
            padding: EdgeInsets.fromLTRB(
                context.pagePadding, Gap.xs, context.pagePadding, FTPage.bottomInset(context)),
            itemCount: sections.length,
            itemBuilder: (context, i) => ContentWidth(
              child: Padding(
                padding: const EdgeInsets.only(bottom: Gap.lg),
                child: FadeSlideIn(index: i, child: sections[i]),
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _sections(BuildContext context, FamilyStats s, FamilyGraph g) {
    return [
      _HeroCard(stats: s),
      _MetricsGrid(stats: s),
      _HighlightsCard(stats: s),
      _ChartCard(
        icon: AppIcons.generations,
        title: 'Generations',
        subtitle: 'People per generation, oldest first',
        child: s.peoplePerGeneration.length < 2
            ? const ChartEmpty(hint: 'Link parents and children to see generations.')
            : InsightBarChart(
                semanticsLabel: 'People per generation',
                data: [
                  for (var i = 0; i < s.peoplePerGeneration.length; i++)
                    ChartDatum('Gen ${i + 1}', s.peoplePerGeneration[i]),
                ],
              ),
      ),
      _ChartCard(
        icon: AppIcons.baby,
        title: 'Births per decade',
        subtitle: '${s.knownBirthYears} of ${s.totalMembers} people have a recorded birth year',
        child: s.knownBirthYears < 2
            ? const ChartEmpty(hint: 'Add birth dates (a year is enough).')
            : InsightBarChart(
                semanticsLabel: 'Births per decade',
                data: [for (final d in s.birthsPerDecade) ChartDatum(d.label, d.count)],
              ),
      ),
      _ChartCard(
        icon: AppIcons.event,
        title: 'Events by type',
        subtitle: s.totalEvents == 1 ? '1 recorded event' : '${s.totalEvents} recorded events',
        child: s.eventCounts.isEmpty ? const ChartEmpty(hint: 'Record family events to see them here.') : _eventBars(s),
      ),
      _ChartCard(
        icon: AppIcons.pie,
        title: 'Gender split',
        subtitle: s.specifiedGenders == s.totalMembers
            ? 'Across all ${s.totalMembers} members'
            : '${s.specifiedGenders} of ${s.totalMembers} members have a gender recorded',
        child: s.specifiedGenders == 0
            ? const ChartEmpty(hint: 'Add gender on member profiles.')
            : InsightDonut(
                semanticsLabel: 'Gender split',
                centerLabel: 'members',
                data: [
                  for (final gnd in Gender.values)
                    if ((s.genders[gnd] ?? 0) > 0) ChartDatum(gnd.label, s.genders[gnd]!),
                ],
              ),
      ),
      _PlacesCard(stats: s),
      _MilestonesCard(
        stats: s,
        showAll: _allMilestones,
        onToggle: () => setState(() => _allMilestones = !_allMilestones),
      ),
      _OldestGenerationCard(
        ids: s.oldestGeneration,
        graph: g,
        showAll: _allOldest,
        onToggle: () => setState(() => _allOldest = !_allOldest),
      ),
    ];
  }

  Widget _eventBars(FamilyStats s) {
    const maxRows = 6;
    final top = s.eventCounts.take(maxRows).toList();
    final rest = s.eventCounts.skip(maxRows).fold<int>(0, (a, e) => a + e.$2);
    return InsightHBars(
      data: [
        for (final (t, n) in top) ChartDatum(t.label, n),
        if (rest > 0) ChartDatum('Other types', rest),
      ],
      icons: [
        for (final (t, _) in top) AppIcons.forEvent(t),
        if (rest > 0) AppIcons.moreHoriz,
      ],
    );
  }
}

// ================================================================ hero

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.stats});
  final FamilyStats stats;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final gens = s.generationCount;
    return FTCard(
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Your family at a glance', style: context.tx.title),
                    const SizedBox(height: Gap.xxs),
                    Text(
                      '${s.totalMembers} ${s.totalMembers == 1 ? 'member' : 'members'} across '
                      '$gens ${gens == 1 ? 'generation' : 'generations'}',
                      style: context.tx.body,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Gap.sm),
              const IconBadge(icon: AppIcons.sparkle, accent: true, size: 44),
            ],
          ),
          const SizedBox(height: Gap.lg),
          StripedProgress(
            value: s.totalMembers == 0 ? 0 : s.knownBirthYears / s.totalMembers,
            label: 'Birth years recorded',
          ),
        ],
      ),
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({required this.stats});
  final FamilyStats stats;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final fmt = NumberFormat.decimalPattern();
    final tiles = <(String, String, IconData)>[
      (fmt.format(s.totalMembers), 'Members', AppIcons.people),
      (fmt.format(s.generationCount), 'Generations', AppIcons.generations),
      (fmt.format(s.living), 'Living', AppIcons.heart),
      (fmt.format(s.deceased), 'Remembered', AppIcons.flower),
      (fmt.format(s.couples), 'Couples', AppIcons.heartFill),
      (fmt.format(s.totalEvents), 'Events', AppIcons.event),
      (fmt.format(s.photos), 'Photos', AppIcons.photos),
      (fmt.format(s.stories), 'Stories', AppIcons.story),
    ];
    return LayoutBuilder(builder: (context, cons) {
      final cols = cons.maxWidth >= 560 ? 4 : 2;
      const gap = Gap.sm;
      final w = (cons.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final (value, label, icon) in tiles)
            SizedBox(
              width: w,
              child: FTCard(
                padding: const EdgeInsets.all(Gap.md),
                radius: Radii.md,
                child: MetricTile(value: value, label: label, icon: icon),
              ),
            ),
        ],
      );
    });
  }
}

// ========================================================== highlights

class _HighlightsCard extends StatelessWidget {
  const _HighlightsCard({required this.stats});
  final FamilyStats stats;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final eb = s.earliestBirth;
    final newest = s.mostRecentlyAdded;
    final avg = s.averageChildrenPerCouple;
    final rows = <Widget>[
      if (eb != null)
        FTListRow(
          icon: AppIcons.hourglass,
          title: 'Earliest recorded birth',
          subtitle: '${eb.date.format()} · ${eb.person.displayName}',
          onTap: () => context.push(Routes.person(eb.person.id)),
        ),
      if (newest != null)
        FTListRow(
          icon: AppIcons.personAdd,
          title: 'Most recently added',
          subtitle: '${newest.displayName} · ${DateFormat('d MMM y').format(newest.createdAt)}',
          onTap: () => context.push(Routes.person(newest.id)),
        ),
      FTListRow(
        icon: AppIcons.family,
        title: 'Parents & children',
        subtitle: '${s.peopleWithChildren} ${s.peopleWithChildren == 1 ? 'person has' : 'people have'} children · '
            '${s.parentChildLinks} parent–child ${s.parentChildLinks == 1 ? 'link' : 'links'}',
      ),
      if (avg != null)
        FTListRow(
          icon: AppIcons.baby,
          title: 'Children per couple',
          subtitle: '${avg.toStringAsFixed(1)} on average across ${s.parentCouples} parent couples',
        ),
    ];
    return FTCard(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.md, Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader('Highlights'),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const HairLine(vertical: Gap.xxs),
            rows[i],
          ],
        ],
      ),
    );
  }
}

// =============================================================== charts

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.icon, required this.title, required this.subtitle, required this.child});
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FTCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconBadge(icon: icon, size: 40),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(header: true, child: Text(title, style: context.tx.section)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: context.tx.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.lg),
          child,
        ],
      ),
    );
  }
}

// =============================================================== places

class _PlacesCard extends StatelessWidget {
  const _PlacesCard({required this.stats});
  final FamilyStats stats;

  @override
  Widget build(BuildContext context) {
    final places = stats.topLocations;
    final c = context.ft;
    return FTCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader('Top places'),
          Text('Birth and death places and event locations', style: context.tx.caption),
          const SizedBox(height: Gap.md),
          if (places.isEmpty)
            const ChartEmpty(hint: 'Add birthplaces or event locations.')
          else
            for (var i = 0; i < places.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
                child: Row(
                  children: [
                    IconBadge(icon: AppIcons.location, size: 36, accent: i == 0),
                    const SizedBox(width: Gap.md),
                    Expanded(
                      child: Text(places[i].label,
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                    ),
                    const SizedBox(width: Gap.xs),
                    Text(
                      places[i].count == 1 ? '1 record' : '${places[i].count} records',
                      style: context.tx.caption.copyWith(color: c.text2),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

// =========================================================== milestones

class _MilestonesCard extends StatelessWidget {
  const _MilestonesCard({required this.stats, required this.showAll, required this.onToggle});
  final FamilyStats stats;
  final bool showAll;
  final VoidCallback onToggle;

  static const _collapsed = 6;

  @override
  Widget build(BuildContext context) {
    final all = stats.milestones;
    final shown = showAll ? all : all.take(_collapsed).toList();
    final rounds = all.where((m) => m.isRound).length;
    return FTCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            'Upcoming milestones',
            action: all.length > _collapsed ? (showAll ? 'Show less' : 'See all ${all.length}') : null,
            onAction: onToggle,
          ),
          Text(
            rounds > 0
                ? 'Next 120 days · $rounds special ${rounds == 1 ? 'milestone' : 'milestones'}'
                : 'Next 120 days',
            style: context.tx.caption,
          ),
          const SizedBox(height: Gap.md),
          if (all.isEmpty)
            const ChartEmpty(hint: 'Birthdays and anniversaries need a full day and month.')
          else
            for (var i = 0; i < shown.length; i++) ...[
              if (i > 0) const HairLine(vertical: Gap.xxs),
              _MilestoneRow(milestone: shown[i]),
            ],
        ],
      ),
    );
  }
}

class _MilestoneRow extends StatelessWidget {
  const _MilestoneRow({required this.milestone});
  final Milestone milestone;

  String _relative(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = DateTime(d.year, d.month, d.day).difference(today).inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return 'Tomorrow';
    return 'In $days days';
  }

  void _open(BuildContext context) {
    final o = milestone.occasion;
    final id = o.sourceId;
    switch (o.kind) {
      case OccasionKind.event:
        if (id != null) context.push(Routes.event(id));
      case OccasionKind.birthday || OccasionKind.memorial:
        if (id != null) context.push(Routes.person(id));
      case OccasionKind.anniversary || OccasionKind.reminder:
        if (o.personIds.isNotEmpty) context.push(Routes.person(o.personIds.first));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final o = milestone.occasion;
    final icon = switch (o.kind) {
      OccasionKind.birthday => AppIcons.cake,
      OccasionKind.anniversary => AppIcons.heart,
      OccasionKind.memorial => AppIcons.candle,
      OccasionKind.event => AppIcons.event,
      OccasionKind.reminder => AppIcons.bell,
    };
    final sub = [milestone.headline ?? o.subtitle, _relative(o.date)].whereType<String>().join(' · ');
    return Pressable(
      onTap: () => _open(context),
      scale: 0.985,
      semanticLabel: '${o.title}, ${DateFormat('d MMMM').format(o.date)}, $sub',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: Row(
          children: [
            Container(
              width: 52,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                gradient: milestone.isRound ? c.accentGradient : c.chipGradient,
                borderRadius: BorderRadius.circular(Radii.sm),
                border: milestone.isRound ? null : Border.all(color: c.border),
              ),
              child: Column(
                children: [
                  Text(
                    '${o.date.day}',
                    style: context.tx.section.copyWith(color: milestone.isRound ? c.onAccent : c.text),
                  ),
                  Text(
                    DateFormat('MMM').format(o.date).toUpperCase(),
                    style: context.tx.micro.copyWith(color: milestone.isRound ? c.onAccent : c.text3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 15, color: c.text3),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(o.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.caption),
                ],
              ),
            ),
            if (milestone.isRound && milestone.years != null) ...[
              const SizedBox(width: Gap.xs),
              FTTag(ordinal(milestone.years!), accent: true, icon: AppIcons.confetti),
            ],
          ],
        ),
      ),
    );
  }
}

// ===================================================== oldest generation

class _OldestGenerationCard extends StatelessWidget {
  const _OldestGenerationCard({
    required this.ids,
    required this.graph,
    required this.showAll,
    required this.onToggle,
  });

  final List<String> ids;
  final FamilyGraph graph;
  final bool showAll;
  final VoidCallback onToggle;

  static const _collapsed = 5;

  @override
  Widget build(BuildContext context) {
    final people = [for (final id in ids) ?graph[id]];
    final shown = showAll ? people : people.take(_collapsed).toList();
    return FTCard(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.md, Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            'Oldest recorded generation',
            action: people.length > _collapsed ? (showAll ? 'Show less' : 'See all ${people.length}') : null,
            onAction: onToggle,
          ),
          Text('The topmost generation of your main family line', style: context.tx.caption),
          const SizedBox(height: Gap.sm),
          if (people.isEmpty)
            const ChartEmpty()
          else
            for (final p in shown)
              PersonTile(
                person: p,
                onTap: () => context.push(Routes.person(p.id)),
                trailing: Icon(AppIcons.forward, size: 18, color: context.ft.text3),
              ),
        ],
      ),
    );
  }
}
