import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../gallery/media_tools.dart';
import '../members/widgets/person_widgets.dart';
import 'story_index.dart';
import 'story_text.dart';

/// Family stories: searchable, filterable by tag and person.
class StoriesScreen extends ConsumerStatefulWidget {
  const StoriesScreen({super.key});

  @override
  ConsumerState<StoriesScreen> createState() => _StoriesScreenState();
}

class _StoriesScreenState extends ConsumerState<StoriesScreen> {
  final _search = TextEditingController();
  StoryFilter _filter = const StoryFilter();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _choosePerson() async {
    if (_filter.personId != null) {
      final r = await showFTOptions<int>(
        context,
        title: 'Filter by person',
        options: const [
          FTOption(0, 'Choose another person', icon: AppIcons.person),
          FTOption(1, 'Show everyone', icon: AppIcons.people),
        ],
      );
      if (r == null || !mounted) return;
      if (r == 1) {
        setState(() => _filter = _filter.copyWith(clearPerson: true));
        return;
      }
    }
    final id = await pickPerson(context, title: 'Stories about…');
    if (id != null && mounted) setState(() => _filter = _filter.copyWith(personId: id));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(storiesProvider);
    final pad = context.pagePadding;
    final hasStories = async.value?.isNotEmpty ?? false;
    return FTPage(
      title: 'Stories',
      actions: [
        FTIconButton(
          icon: AppIcons.add,
          tooltip: 'Write a story',
          accent: true,
          onTap: () => context.push(Routes.newStory()),
        ),
      ],
      headerBottom: hasStories
          ? Padding(
              padding: EdgeInsets.fromLTRB(pad, Gap.xxs, pad, Gap.sm),
              child: ContentWidth(
                child: FTSearchField(
                  controller: _search,
                  hint: 'Search titles, text, people, tags',
                  onChanged: (v) => setState(() => _filter = _filter.copyWith(query: v)),
                ),
              ),
            )
          : null,
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e),
        data: (stories) {
          if (stories.isEmpty) {
            return EmptyState(
              icon: AppIcons.story,
              title: 'No stories yet',
              message: 'Preserve memories, anecdotes, recipes and family legends in your own words.',
              actionLabel: 'Write a story',
              onAction: () => context.push(Routes.newStory()),
            );
          }
          final links = ref.watch(storyLinksProvider);
          final tags = {for (final t in ref.watch(tagsProvider).value ?? const <Tag>[]) t.id: t};
          final graph = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
          final byId = ref.watch(mediaByIdProvider);
          final usedTags = <String>{for (final l in links.values) ...l.tagIds};
          final tagChips = [
            for (final t in tags.values)
              if (usedTags.contains(t.id)) t,
          ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
          final person = _filter.personId == null ? null : graph[_filter.personId!];
          final shown = _filter.apply(stories, links, tags, graph);
          return ListView.builder(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, FTPage.bottomInset(context)),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            itemCount: 1 + (shown.isEmpty ? 1 : shown.length),
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: Gap.md),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    child: Row(
                      children: [
                        FTChip(
                          label: person?.shortName ?? 'Everyone',
                          icon: AppIcons.person,
                          selected: person != null,
                          onTap: _choosePerson,
                        ),
                        Container(
                          width: 1,
                          height: 22,
                          margin: const EdgeInsets.symmetric(horizontal: Gap.xs),
                          color: context.ft.border,
                        ),
                        FTChip(
                          label: 'All tags',
                          selected: _filter.tagId == null,
                          onTap: () => setState(() => _filter = _filter.copyWith(clearTag: true)),
                        ),
                        for (final t in tagChips) ...[
                          const SizedBox(width: Gap.xs),
                          FTChip(
                            label: t.name,
                            icon: AppIcons.tag,
                            selected: _filter.tagId == t.id,
                            onTap: () => setState(() => _filter = _filter.tagId == t.id
                                ? _filter.copyWith(clearTag: true)
                                : _filter.copyWith(tagId: t.id)),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }
              if (shown.isEmpty) {
                return const EmptyState(
                  icon: AppIcons.search,
                  title: 'No matching stories',
                  message: 'Try another search or clear the filters.',
                  compact: true,
                );
              }
              final s = shown[i - 1];
              final l = links[s.id] ?? const StoryLinks();
              return ContentWidth(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: Gap.md),
                  child: FadeSlideIn(
                    index: i - 1,
                    child: StoryCard(
                      story: s,
                      cover: storyCover(s, l, byId),
                      people: [
                        for (final id in l.personIds)
                          if (graph[id] != null) graph[id]!,
                      ],
                      tags: [
                        for (final id in l.tagIds)
                          if (tags[id] != null) tags[id]!.name,
                      ],
                      avatarPath: (p) => p.profileMediaId == null ? null : byId[p.profileMediaId]?.thumbAbsolutePath,
                      onTap: () => context.push(Routes.story(s.id)),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Story card: optional cover photo, historical date, title, two-line
/// excerpt, related people (overlapping avatars) and tags.
class StoryCard extends StatelessWidget {
  const StoryCard({
    super.key,
    required this.story,
    required this.cover,
    required this.people,
    required this.tags,
    required this.avatarPath,
    this.onTap,
  });

  final Story story;
  final MediaAsset? cover;
  final List<Person> people;
  final List<String> tags;
  final String? Function(Person) avatarPath;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final date = FuzzyDate.tryParse(story.historicalDate)?.format(long: true);
    final excerpt = StoryText.excerpt(story.body, max: 180);
    return FTCard(
      padding: EdgeInsets.zero,
      onTap: onTap,
      semanticLabel: '${story.title}${date == null ? '' : ', $date'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (cover != null)
            AspectRatio(
              aspectRatio: 16 / 8,
              child: LayoutBuilder(builder: (context, cons) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(
                      File(cover!.thumbAbsolutePath),
                      fit: BoxFit.cover,
                      cacheWidth: (cons.maxWidth * dpr).round().clamp(200, 1400),
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, c.cardMid.withValues(alpha: 0.85)],
                          stops: const [0.55, 1],
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (cover == null) ...[
                      const IconBadge(icon: AppIcons.story, size: 36),
                      const SizedBox(width: Gap.sm),
                    ],
                    Icon(AppIcons.calendarBlank, size: 14, color: date == null ? c.text3 : c.accent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(date ?? 'Undated',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.tx.caption.copyWith(color: date == null ? c.text3 : c.text2)),
                    ),
                    if (story.isPrivate) Icon(AppIcons.lock, size: 15, color: c.text3, semanticLabel: 'Private'),
                  ],
                ),
                const SizedBox(height: Gap.xs),
                Text(story.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.title),
                if (excerpt.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(excerpt, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.body),
                ],
                if (people.isNotEmpty || tags.isNotEmpty) ...[
                  const SizedBox(height: Gap.md),
                  Row(
                    children: [
                      if (people.isNotEmpty) ...[
                        AvatarStack(
                          people: [for (final p in people) (p.displayName, avatarPath(p))],
                          size: 30,
                          max: 3,
                        ),
                        const SizedBox(width: Gap.sm),
                      ],
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final t in tags.take(2)) FTTag(t, icon: AppIcons.tag),
                            if (tags.length > 2) FTTag('+${tags.length - 2}'),
                            if (tags.isEmpty && people.length == 1)
                              Text(people.first.displayName,
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.caption),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
