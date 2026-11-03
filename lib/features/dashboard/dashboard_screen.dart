import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/navigation/app_shell.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/settings.dart';
import '../../core/database/app_database.dart';
import '../../core/services/app_paths.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../family/domain/occasions.dart';
import '../gallery/media_import.dart';
import '../members/widgets/person_widgets.dart';

/// Profile completeness (0..1) used for the striped progress bars.
double profileCompleteness(Person p, FamilyGraph g) {
  var score = 0;
  const total = 6;
  if (p.birth != null) score++;
  if ((p.birthPlace ?? '').isNotEmpty) score++;
  if (p.profileMediaId != null) score++;
  if (g.parentIds(p.id).isNotEmpty) score++;
  if ((p.biography ?? '').isNotEmpty || (p.occupation ?? '').isNotEmpty) score++;
  if (!p.isLiving ? p.death != null : true) score++;
  return score / total;
}

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(settingsProvider);
    final graphAsync = ref.watch(familyGraphProvider);
    final pad = context.pagePadding;

    final sections = <DashboardSection, Widget Function()>{
      DashboardSection.overview: () => const _OverviewCard(),
      DashboardSection.quickActions: () => const _QuickActions(),
      DashboardSection.recent: () => const _RecentAdditions(),
      DashboardSection.upcoming: () => const _Upcoming(),
      DashboardSection.memories: () => const _Memories(),
    };
    final visible = prefs.dashboardOrder.where((s) => !prefs.dashboardHidden.contains(s)).toList();

    return FTPage(
      showBack: false,
      body: graphAsync.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e),
        data: (g) => ListView(
          padding: EdgeInsets.fromLTRB(0, 4, 0, AppShell.contentInset(context)),
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: const FadeSlideIn(child: _Header()),
            ),
            const SizedBox(height: Gap.xl),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: const FadeSlideIn(index: 1, child: _Headline()),
            ),
            if (g.size == 0) ...[
              const SizedBox(height: Gap.xl),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: pad),
                child: FTCard(
                  child: EmptyState(
                    icon: AppIcons.personAdd,
                    title: 'Your tree is empty',
                    message: 'Add the first person – yourself, a parent or an ancestor.',
                    actionLabel: 'Add a person',
                    onAction: () => context.push(Routes.newPerson()),
                    compact: true,
                  ),
                ),
              ),
            ],
            for (var i = 0; i < visible.length; i++) ...[
              const SizedBox(height: Gap.xl),
              FadeSlideIn(index: i + 2, child: sections[visible[i]]!()),
            ],
            const SizedBox(height: Gap.xl),
            Center(
              child: FTTextAction('Customize home', onTap: () => context.push(Routes.dashboardSettings)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = ref.watch(familyGraphProvider).value;
    final homeId = ref.watch(homePersonIdProvider);
    final home = homeId == null ? null : g?[homeId];
    final tree = ref.watch(activeTreeProvider);
    final upcomingSoon = ref.watch(_upcomingProvider).where((o) => o.date.difference(DateTime.now()).inDays < 7).isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: FTPill(
            onTap: home == null ? null : () => context.push(Routes.person(home.id)),
            semanticLabel: 'Welcome back${home == null ? '' : ', ${home.shortName}'}',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                home != null
                    ? PersonAvatarFor(home, size: 44)
                    : Image.asset('assets/branding/emblem.png', width: 44, height: 44),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Welcome back,', style: context.tx.caption.copyWith(fontSize: 11.5)),
                      Text(
                        home?.shortName ?? tree?.name ?? 'Family Tales',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.tx.bodyStrong.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          ),
        ),
        const SizedBox(width: 8),
        FTIconButton(
          icon: AppIcons.bell,
          tooltip: 'Reminders',
          badge: upcomingSoon,
          onTap: () => context.push(Routes.calendar),
        ),
        const SizedBox(width: 4),
        FTIconButton(
          icon: AppIcons.search,
          tooltip: 'Search family',
          onTap: () => context.push(Routes.search),
        ),
      ],
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline();

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final style = context.tx.headline.copyWith(fontSize: 27);
    return Semantics(
      header: true,
      label: 'Your family story continues',
      child: ExcludeSemantics(
        child: Text.rich(
          TextSpan(
            style: style,
            children: [
              const TextSpan(text: 'Your family story\n'),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Container(
                  margin: const EdgeInsets.only(right: 8),
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: c.chipGradient,
                    border: Border.all(color: c.border),
                  ),
                  child: Icon(AppIcons.leaf, size: 15, color: c.accent),
                ),
              ),
              const TextSpan(text: 'continues…'),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------- overview

class _OverviewCard extends ConsumerWidget {
  const _OverviewCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final branches = ref.watch(branchesProvider).value ?? const [];
    final tree = ref.watch(activeTreeProvider);
    final c = context.ft;
    final deceased = g.people.values.where((p) => !p.isLiving).length;
    final lines = branches.isNotEmpty ? branches.length : g.rootLines().length;
    final completeness = g.size == 0
        ? 0.0
        : g.people.values.map((p) => profileCompleteness(p, g)).reduce((a, b) => a + b) / g.size;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.pagePadding),
      child: FTCard(
        onTap: () => context.go(Routes.tree),
        semanticLabel: 'Family overview: ${g.size} members, ${g.generationCount()} generations',
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const IconBadge(icon: AppIcons.tree, size: 40),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Family overview', style: context.tx.caption),
                            Text(tree?.name ?? 'Family tree',
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                          ],
                        ),
                      ),
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(shape: BoxShape.circle, gradient: c.accentGradient),
                        child: Icon(AppIcons.arrowUpRight, color: c.onAccent, size: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${g.size}', style: context.tx.display.copyWith(fontSize: 44, height: 1)),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(g.size == 1 ? 'family member' : 'family members',
                              maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.body),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  LayoutBuilder(builder: (context, cons) {
                    final metrics = [
                      ('${g.generationCount()}', 'Generations', AppIcons.generations),
                      ('${g.relationshipCount}', 'Relationships', AppIcons.link),
                      ('$lines', branches.isNotEmpty ? 'Branches' : 'Family lines', AppIcons.branch),
                      ('$deceased', 'Ancestors remembered', AppIcons.flower),
                    ];
                    final cols = cons.maxWidth > 420 ? 4 : 2;
                    final w = (cons.maxWidth - (cols - 1) * 12) / cols;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 14,
                      children: [
                        for (final m in metrics)
                          SizedBox(width: w, child: MetricTile(value: m.$1, label: m.$2, icon: m.$3)),
                      ],
                    );
                  }),
                ],
              ),
            ),
            StripedProgress(value: completeness, label: 'Tree completeness'),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ quick actions

class _QuickActions extends ConsumerWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = [
      (AppIcons.personAdd, 'Add family\nmember', () => context.push(Routes.newPerson())),
      (AppIcons.tree, 'Explore\nfamily tree', () => context.go(Routes.tree)),
      (AppIcons.event, 'Add family\nevent', () => context.push(Routes.newEvent())),
      (AppIcons.camera, 'Upload\nfamily photo', () => importPhotosFlow(context, ref)),
      (AppIcons.storyAlt, 'Create family\nstory', () => context.push(Routes.newStory())),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: context.pagePadding),
          child: SectionHeader('Quick actions', action: 'See all', onAction: () => context.go(Routes.more)),
        ),
        SizedBox(
          height: 128,
          child: ListView.separated(
            padding: EdgeInsets.symmetric(horizontal: context.pagePadding),
            scrollDirection: Axis.horizontal,
            itemCount: actions.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final a = actions[i];
              return FTCard(
                width: 118,
                radius: 22,
                padding: const EdgeInsets.all(14),
                onTap: a.$3,
                semanticLabel: a.$2.replaceAll('\n', ' '),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IconBadge(icon: a.$1, size: 40),
                    const Spacer(),
                    Text(a.$2,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.tx.label.copyWith(fontSize: 12.5, height: 1.25)),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------- recent additions

class _RecentAdditions extends ConsumerWidget {
  const _RecentAdditions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    if (g.size == 0) return const SizedBox.shrink();
    final home = ref.watch(homePersonIdProvider);
    final kin = ref.watch(kinshipProvider);
    final recent = g.people.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final items = recent.take(8).toList();
    final fmt = DateFormat('MMM dd, y');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: context.pagePadding),
          child: SectionHeader('Recent additions', action: 'See all', onAction: () => context.go(Routes.members)),
        ),
        SizedBox(
          height: 206,
          child: ListView.separated(
            padding: EdgeInsets.symmetric(horizontal: context.pagePadding),
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final p = items[i];
              String? rel;
              if (home != null && kin != null) {
                rel = p.id == home ? 'Home person' : kin.primaryLabel(p.id, home);
              }
              final added = p.createdAt == p.updatedAt ? 'Added' : 'Updated';
              return _PersonStoryCard(
                person: p,
                dateLine: '$added ${fmt.format(p.updatedAt.toLocal())}',
                relation: rel,
                completeness: profileCompleteness(p, g),
                tilt: i == 0 ? 0 : 0,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Person card styled after the reference's task cards.
class _PersonStoryCard extends StatelessWidget {
  const _PersonStoryCard({
    required this.person,
    required this.dateLine,
    required this.relation,
    required this.completeness,
    this.tilt = 0,
  });

  final Person person;
  final String dateLine;
  final String? relation;
  final double completeness;
  final double tilt;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return FTCard(
      width: 236,
      padding: EdgeInsets.zero,
      onTap: () => context.push(Routes.person(person.id)),
      semanticLabel: '${person.displayName}, $dateLine${relation == null ? '' : ', $relation'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      PersonAvatarFor(person, size: 40, showGender: true),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(dateLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.micro),
                            const SizedBox(height: 2),
                            Text(person.lifespanLabel.isEmpty ? 'Dates unknown' : person.lifespanLabel,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.label),
                          ],
                        ),
                      ),
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(shape: BoxShape.circle, gradient: c.accentGradient),
                        child: Icon(AppIcons.arrowUpRight, color: c.onAccent, size: 16),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(person.displayName,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.section.copyWith(fontSize: 17)),
                  if (relation != null) ...[
                    const SizedBox(height: 2),
                    Text(relation!, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.caption),
                  ],
                ],
              ),
            ),
          ),
          StripedProgress(value: completeness, label: 'Profile', height: 36),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ upcoming

final _upcomingProvider = Provider<List<Occasion>>((ref) {
  final g = ref.watch(familyGraphProvider).value;
  if (g == null) return const [];
  final events = ref.watch(eventsWithPeopleProvider).value ?? const [];
  final reminders = ref.watch(remindersProvider).value ?? const [];
  return OccasionCalculator(
    graph: g,
    events: [for (final e in events) e.event],
    eventPeople: {for (final e in events) e.event.id: e.personIds},
    reminders: reminders,
  ).upcoming(days: 90);
});

class _Upcoming extends ConsumerWidget {
  const _Upcoming();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(_upcomingProvider).take(4).toList();
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final c = context.ft;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.pagePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader('Upcoming family events', action: 'Calendar', onAction: () => context.push(Routes.calendar)),
          if (list.isEmpty)
            FTCard(
              padding: const EdgeInsets.all(16),
              shadow: false,
              child: Row(
                children: [
                  const IconBadge(icon: AppIcons.cake, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Nothing in the next three months. Birthdays and anniversaries appear here once day and month are known.',
                      style: context.tx.caption,
                    ),
                  ),
                ],
              ),
            )
          else
            for (final o in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: FTPill(
                  padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
                  onTap: () {
                    if (o.kind == OccasionKind.event && o.sourceId != null) {
                      context.push(Routes.event(o.sourceId!));
                    } else if (o.personIds.isNotEmpty) {
                      context.push(Routes.person(o.personIds.first));
                    } else {
                      context.push(Routes.calendar);
                    }
                  },
                  semanticLabel: '${o.title}, ${DateFormat.MMMMd().format(o.date)}',
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: _isToday(o.date) ? c.accentGradient : c.chipGradient,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('${o.date.day}',
                                textScaler: TextScaler.noScaling,
                                style: context.tx.bodyStrong.copyWith(
                                    height: 1, color: _isToday(o.date) ? c.onAccent : c.text)),
                            Text(DateFormat.MMM().format(o.date).toUpperCase(),
                                textScaler: TextScaler.noScaling,
                                style: context.tx.micro.copyWith(
                                    fontSize: 9, color: _isToday(o.date) ? c.onAccent : c.text3)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(o.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                            Text(
                              [o.kind.label, ?o.subtitle].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.tx.caption,
                            ),
                          ],
                        ),
                      ),
                      if (o.personIds.isNotEmpty)
                        AvatarStack(
                          people: [
                            for (final id in o.personIds)
                              if (g[id] != null) (g[id]!.displayName, _avatar(ref, g[id]!))
                          ],
                          size: 30,
                          max: 2,
                        ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }

  static bool _isToday(DateTime d) {
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }

  static String? _avatar(WidgetRef ref, Person p) => ref.watch(avatarPathProvider(p.profileMediaId));
}

// ------------------------------------------------------------------ memories

class _Memories extends ConsumerWidget {
  const _Memories();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = (ref.watch(mediaProvider).value ?? const <MediaAsset>[])
        .where((m) => m.kind.name == 'photo')
        .take(10)
        .toList();
    final stories = (ref.watch(storiesProvider).value ?? const <Story>[]).take(3).toList();
    final c = context.ft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: context.pagePadding),
          child: SectionHeader('Recent memories', action: 'Gallery', onAction: () => context.push(Routes.gallery)),
        ),
        if (media.isEmpty && stories.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.pagePadding),
            child: FTCard(
              padding: const EdgeInsets.all(16),
              shadow: false,
              onTap: () => importPhotosFlow(context, ref),
              child: Row(
                children: [
                  const IconBadge(icon: AppIcons.photos, size: 40),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Add old family photos and stories to bring your tree to life.', style: context.tx.caption)),
                  Icon(AppIcons.add, color: c.accent),
                ],
              ),
            ),
          )
        else ...[
          if (media.isNotEmpty)
            SizedBox(
              height: 132,
              child: ListView.separated(
                padding: EdgeInsets.symmetric(horizontal: context.pagePadding),
                scrollDirection: Axis.horizontal,
                itemCount: media.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final m = media[i];
                  final dpr = MediaQuery.devicePixelRatioOf(context);
                  return Pressable(
                    onTap: () => context.push(Routes.media(m.id), extra: [for (final x in media) x.id]),
                    semanticLabel: m.caption ?? 'Family photo',
                    child: Container(
                      width: 112,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: c.softShadow,
                        border: Border.all(color: c.border),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.file(
                        File(AppPaths.I.resolve(m.thumbPath ?? m.filePath)),
                        fit: BoxFit.cover,
                        cacheWidth: (112 * dpr).round(),
                        errorBuilder: (_, _, _) => Container(color: c.surfaceHigh, child: Icon(AppIcons.photo, color: c.text3)),
                      ),
                    ),
                  );
                },
              ),
            ),
          for (final s in stories)
            Padding(
              padding: EdgeInsets.fromLTRB(context.pagePadding, 12, context.pagePadding, 0),
              child: FTCard(
                padding: const EdgeInsets.all(16),
                onTap: () => context.push(Routes.story(s.id)),
                semanticLabel: 'Story: ${s.title}',
                child: Row(
                  children: [
                    const IconBadge(icon: AppIcons.story, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                          Text(
                            s.body.replaceAll(RegExp(r'[#>*_\-]'), '').replaceAll('\n', ' ').trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.tx.caption,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}
