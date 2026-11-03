import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../gallery/media_tools.dart';
import '../gallery/media_widgets.dart';
import '../members/widgets/person_widgets.dart';
import 'markdown_view.dart';
import 'story_index.dart';
import 'story_text.dart';

enum _StoryAction { share, delete }

/// Premium reading layout for a story.
class StoryReaderScreen extends ConsumerWidget {
  const StoryReaderScreen({super.key, required this.storyId});
  final String storyId;

  static String plainTextOf(Story s) {
    final b = StringBuffer(s.title.trim());
    final date = FuzzyDate.tryParse(s.historicalDate)?.format(long: true);
    if (date != null && date.isNotEmpty) b.write('\n$date');
    final body = StoryText.toPlain(s.body);
    if (body.isNotEmpty) b.write('\n\n$body');
    final src = s.sourceText?.trim() ?? '';
    if (src.isNotEmpty) b.write('\n\nSource: $src');
    return b.toString();
  }

  Future<void> _share(BuildContext context, Story s) async {
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(ShareParams(
        text: plainTextOf(s),
        subject: s.title,
        sharePositionOrigin: box != null && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null,
      ));
    } catch (_) {
      if (context.mounted) showFTToast(context, 'Could not open the share sheet.', error: true);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Story s) async {
    final ok = await showFTConfirm(
      context,
      title: 'Move story to trash?',
      message: '“${s.title}” moves to the trash. People, events and photos linked to it are kept.',
      confirmLabel: 'Move to trash',
      destructive: true,
      icon: AppIcons.trash,
    );
    if (!ok || !context.mounted) return;
    final repo = ref.read(contentRepoProvider);
    final done = await trashWithUndo(
      context,
      ref,
      type: TrashEntity.story,
      id: s.id,
      trash: () => repo.trashStory(s.id),
      message: 'Story moved to trash',
    );
    if (done && context.mounted) context.pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(storiesProvider);
    Story? story;
    for (final s in async.value ?? const <Story>[]) {
      if (s.id == storyId) story = s;
    }
    if (story == null) {
      return FTPage(
        title: 'Story',
        body: async.isLoading
            ? const LoadingView()
            : (async.hasError
                ? ErrorView(error: async.error!)
                : const EmptyState(
                    icon: AppIcons.story,
                    title: 'Story not found',
                    message: 'It may have been moved to the trash.',
                  )),
      );
    }
    final s = story;
    final links = ref.watch(storyLinksProvider)[s.id] ?? const StoryLinks();
    final graph = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final events = {for (final e in ref.watch(eventsProvider).value ?? const <FamilyEvent>[]) e.id: e};
    final tags = {for (final t in ref.watch(tagsProvider).value ?? const <Tag>[]) t.id: t};
    final byId = ref.watch(mediaByIdProvider);
    final photos = storyPhotos(links, byId);
    final photoIds = [for (final m in photos) m.id];
    final cover = storyCover(s, links, byId);
    final people = [
      for (final id in links.personIds)
        if (graph[id] != null) graph[id]!,
    ];
    final linkedEvents = [
      for (final id in links.eventIds)
        if (events[id] != null) events[id]!,
    ];
    final tagNames = [
      for (final id in links.tagIds)
        if (tags[id] != null) tags[id]!.name,
    ];
    final date = FuzzyDate.tryParse(s.historicalDate)?.format(long: true);
    final minutes = StoryText.readingMinutes(s.body);
    final updated = 'Updated ${DateFormat.yMMMd().format(s.updatedAt)}';
    final source = s.sourceText?.trim() ?? '';
    final pad = context.pagePadding;
    final c = context.ft;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    return FTPage(
      title: 'Story',
      actions: [
        FTIconButton(icon: AppIcons.edit, tooltip: 'Edit story', onTap: () => context.push(Routes.storyEdit(s.id))),
        Builder(
          builder: (bctx) => FTIconButton(
            icon: AppIcons.moreHoriz,
            tooltip: 'More actions',
            onTap: () async {
              final a = await showFTOptions<_StoryAction>(
                context,
                title: s.title,
                options: const [
                  FTOption(_StoryAction.share, 'Share as text', icon: AppIcons.share),
                  FTOption(_StoryAction.delete, 'Move to trash', icon: AppIcons.trash, danger: true),
                ],
              );
              if (a == null || !context.mounted) return;
              switch (a) {
                case _StoryAction.share:
                  if (bctx.mounted) await _share(bctx, s);
                case _StoryAction.delete:
                  await _delete(context, ref, s);
              }
            },
          ),
        ),
      ],
      body: ListView(
        padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, FTPage.bottomInset(context, extra: 40)),
        children: [
          ContentWidth(
            maxWidth: 720,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (cover != null) ...[
                  FTCard(
                    padding: EdgeInsets.zero,
                    onTap: () => context.push(Routes.media(cover.id), extra: photoIds),
                    semanticLabel: 'Cover photo, ${cover.displayTitle}. Open photo',
                    child: AspectRatio(
                      aspectRatio: 4 / 3,
                      child: LayoutBuilder(builder: (context, cons) {
                        return Image.file(
                          File(cover.absolutePath),
                          fit: BoxFit.cover,
                          cacheWidth: (cons.maxWidth * dpr).round().clamp(300, 2000),
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => const MediaPlaceholder(icon: AppIcons.photo),
                        );
                      }),
                    ),
                  ),
                  const SizedBox(height: Gap.xl),
                ] else ...[
                  const Align(alignment: Alignment.centerLeft, child: IconBadge(icon: AppIcons.storyAlt, size: 52)),
                  const SizedBox(height: Gap.lg),
                ],
                Wrap(
                  spacing: Gap.xs,
                  runSpacing: Gap.xs,
                  children: [
                    if (date != null) FTTag(date, icon: AppIcons.calendarBlank, accent: true),
                    if (s.isPrivate) const FTTag('Private', icon: AppIcons.lock),
                  ],
                ),
                if (date != null || s.isPrivate) const SizedBox(height: Gap.sm),
                Semantics(header: true, child: Text(s.title, style: context.tx.display)),
                const SizedBox(height: Gap.xs),
                Text(
                  minutes > 0 ? '$updated · $minutes min read' : updated,
                  style: context.tx.caption,
                ),
                if (people.isNotEmpty) ...[
                  const SizedBox(height: Gap.lg),
                  Wrap(
                    spacing: Gap.xs,
                    runSpacing: Gap.xs,
                    children: [
                      for (final p in people)
                        LinkPill(
                          label: p.displayName,
                          leading: PersonAvatarFor(p, size: 28),
                          onTap: () => context.push(Routes.person(p.id)),
                        ),
                    ],
                  ),
                ],
                if (linkedEvents.isNotEmpty) ...[
                  const SizedBox(height: Gap.xs),
                  Wrap(
                    spacing: Gap.xs,
                    runSpacing: Gap.xs,
                    children: [
                      for (final e in linkedEvents)
                        LinkPill(
                          label: e.title,
                          icon: AppIcons.forEvent(e.type),
                          onTap: () => context.push(Routes.event(e.id)),
                        ),
                    ],
                  ),
                ],
                const HairLine(vertical: Gap.xl),
                if (s.body.trim().isEmpty)
                  Text('This story has no text yet.', style: context.tx.body.copyWith(color: c.text3))
                else
                  SelectionArea(child: MarkdownView(s.body)),
                if (photos.isNotEmpty) ...[
                  const SizedBox(height: Gap.xxl),
                  SectionHeader('Photos · ${photos.length}'),
                  const SizedBox(height: Gap.xs),
                  SizedBox(
                    height: 112,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      clipBehavior: Clip.none,
                      itemCount: photos.length,
                      separatorBuilder: (_, _) => const SizedBox(width: Gap.sm),
                      itemBuilder: (context, i) => SizedBox(
                        width: 112,
                        child: MediaThumb(
                          media: photos[i],
                          radius: Radii.md,
                          onTap: () => context.push(Routes.media(photos[i].id), extra: photoIds),
                        ),
                      ),
                    ),
                  ),
                ],
                if (source.isNotEmpty) ...[
                  const SizedBox(height: Gap.xxl),
                  FTCard(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const IconBadge(icon: AppIcons.source, size: 40),
                        const SizedBox(width: Gap.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Source', style: context.tx.caption),
                              const SizedBox(height: 2),
                              SelectableText(source, style: context.tx.body.copyWith(color: c.text)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (tagNames.isNotEmpty) ...[
                  const SizedBox(height: Gap.xl),
                  Wrap(
                    spacing: Gap.xs,
                    runSpacing: Gap.xs,
                    children: [for (final t in tagNames) FTTag(t, icon: AppIcons.tag)],
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
