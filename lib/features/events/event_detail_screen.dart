import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/repositories/content_repository.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../gallery/media_import.dart';
import '../members/widgets/person_widgets.dart';
import '../sources/citations_section.dart';
import 'event_actions.dart';
import 'event_logic.dart';
import 'event_widgets.dart';

/// A single event: hero card, description, people, photos, linked stories
/// and sources.
class EventDetailScreen extends ConsumerWidget {
  const EventDetailScreen({super.key, required this.eventId});
  final String eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(eventsWithPeopleProvider);
    return async.when(
      loading: () => const FTPage(title: 'Event', body: LoadingView()),
      error: (e, _) => FTPage(title: 'Event', body: ErrorView(error: e)),
      data: (all) {
        final item = all.where((e) => e.event.id == eventId).firstOrNull;
        if (item == null) {
          return FTPage(
            title: 'Event',
            body: EmptyState(
              icon: AppIcons.event,
              title: 'Event not found',
              message: 'It may have been moved to the trash.',
              actionLabel: 'All events',
              onAction: () => context.go(Routes.events),
            ),
          );
        }
        return _EventDetail(item: item);
      },
    );
  }
}

class _EventDetail extends ConsumerWidget {
  const _EventDetail({required this.item});
  final EventWithPeople item;

  FamilyEvent get ev => item.event;

  Future<void> _edit(BuildContext context) async {
    final r = await context.push<Object?>(Routes.eventEdit(ev.id));
    if (r == 'deleted' && context.mounted && context.canPop()) context.pop();
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final done = await confirmTrashEvent(context, ref, ev);
    if (done && context.mounted) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(Routes.events);
      }
    }
  }

  Future<void> _linkExisting(BuildContext context, WidgetRef ref, Set<String> current) async {
    final r = await pickExistingPhotos(context, initial: current, title: 'Photos of this event');
    if (r == null) return;
    try {
      await setEventPhotos(ref, ev.id, r);
      if (context.mounted) showFTToast(context, 'Photos updated');
    } catch (e) {
      if (context.mounted) showFTToast(context, friendlyError(e), error: true);
    }
  }

  Future<void> _addPhotos(BuildContext context, WidgetRef ref, Set<String> current) async {
    final choice = await showFTOptions<int>(
      context,
      title: 'Add photos',
      options: const [
        FTOption(0, 'Import new photos', icon: AppIcons.camera, subtitle: 'Camera, photo library or files'),
        FTOption(1, 'Choose from gallery', icon: AppIcons.photos, subtitle: 'Photos already in this family tree'),
      ],
    );
    if (!context.mounted || choice == null) return;
    if (choice == 0) {
      await importPhotosFlow(context, ref, eventIds: [ev.id]);
    } else {
      await _linkExisting(context, ref, current);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pad = context.pagePadding;
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final mediaById = ref.watch(mediaByIdProvider);
    final links = ref.watch(mediaEventsProvider).value ?? const <MediaEvent>[];
    final photos = [
      for (final l in links)
        if (l.eventId == ev.id) ?mediaById[l.mediaId],
    ];
    final linkedIds = {for (final l in links) if (l.eventId == ev.id) l.mediaId};
    final photoIds = [for (final m in photos) m.id];

    final storyLinks = ref.watch(storyEventsProvider).value ?? const <StoryEvent>[];
    final storyIds = {for (final s in storyLinks) if (s.eventId == ev.id) s.storyId};
    final stories = [
      for (final s in ref.watch(storiesProvider).value ?? const <Story>[])
        if (storyIds.contains(s.id)) s,
    ];
    final people = [for (final id in item.personIds) ?g[id]];
    final desc = ev.description?.trim();

    Widget section(Widget child) => SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: pad),
            child: ContentWidth(child: child),
          ),
        );

    return FTPage(
      title: 'Event',
      actions: [
        Builder(
          builder: (bctx) => FTIconButton(
            icon: AppIcons.share,
            tooltip: 'Share event',
            onTap: () => shareEvent(bctx, ref, item),
          ),
        ),
        FTIconButton(icon: AppIcons.edit, tooltip: 'Edit event', onTap: () => _edit(context)),
      ],
      body: CustomScrollView(
        slivers: [
          section(Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: FadeSlideIn(child: _HeroCard(item: item, people: people)),
          )),
          if (desc != null && desc.isNotEmpty) ...[
            section(const Padding(
              padding: EdgeInsets.only(top: Gap.xl),
              child: SectionHeader('About'),
            )),
            section(FadeSlideIn(
              index: 1,
              child: FTCard(
                child: SelectableText(desc, style: context.tx.body.copyWith(color: context.ft.text)),
              ),
            )),
          ],
          section(Padding(
            padding: const EdgeInsets.only(top: Gap.xl),
            child: SectionHeader(
              'People',
              trailing: people.isEmpty ? null : FTTag('${people.length}'),
              action: 'Edit',
              onAction: () => _edit(context),
            ),
          )),
          section(FadeSlideIn(
            index: 2,
            child: FTCard(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.xs),
              child: people.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
                      child: FTListRow(
                        title: 'Add people',
                        subtitle: 'Link the relatives who were part of it',
                        icon: AppIcons.personAdd,
                        onTap: () => _edit(context),
                      ),
                    )
                  : Column(
                      children: [
                        for (final p in people)
                          PersonTile(
                            person: p,
                            subtitle: _personSubtitle(p, item.roles[p.id]),
                            trailing: Icon(AppIcons.forward, size: 18, color: context.ft.text3),
                            onTap: () => context.push(Routes.person(p.id)),
                          ),
                      ],
                    ),
            ),
          )),
          section(Padding(
            padding: const EdgeInsets.only(top: Gap.xl),
            child: SectionHeader(
              'Photos',
              trailing: photos.isEmpty ? null : FTTag('${photos.length}'),
              action: 'Add',
              onAction: () => _addPhotos(context, ref, linkedIds),
            ),
          )),
          if (photos.isEmpty)
            section(FTCard(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
              child: FTListRow(
                title: 'Add photos',
                subtitle: 'Import new photos or choose from the gallery',
                icon: AppIcons.photos,
                onTap: () => _addPhotos(context, ref, linkedIds),
              ),
            ))
          else
            SliverLayoutBuilder(builder: (context, cons) {
              final full = cons.crossAxisExtent;
              final content = (full - 2 * pad).clamp(0.0, context.maxContentWidth);
              final side = (full - content) / 2;
              final cols = (content / 112).floor().clamp(3, 6);
              return SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: side),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisSpacing: Gap.xs,
                    crossAxisSpacing: Gap.xs,
                  ),
                  itemCount: photos.length,
                  itemBuilder: (context, i) {
                    final m = photos[i];
                    return FadeSlideIn(
                      index: i < 12 ? i : 0,
                      child: Pressable(
                        semanticLabel: m.caption ?? 'Photo ${i + 1} of ${photos.length}',
                        onTap: () => context.push(Routes.media(m.id), extra: photoIds),
                        child: MediaThumb(media: m, radius: Radii.md),
                      ),
                    );
                  },
                ),
              );
            }),
          if (stories.isNotEmpty) ...[
            section(Padding(
              padding: const EdgeInsets.only(top: Gap.xl),
              child: SectionHeader('Stories', trailing: FTTag('${stories.length}')),
            )),
            section(FTCard(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
              child: Column(
                children: [
                  for (final s in stories)
                    FTListRow(
                      title: s.title,
                      subtitle: _storySubtitle(s),
                      icon: AppIcons.story,
                      onTap: () => context.push(Routes.story(s.id)),
                    ),
                ],
              ),
            )),
          ],
          section(Padding(
            padding: const EdgeInsets.only(top: Gap.xl),
            child: CitationsSection(entityType: 'event', entityId: ev.id),
          )),
          section(Padding(
            padding: EdgeInsets.only(top: Gap.xxl, bottom: FTPage.bottomInset(context)),
            child: FTButton(
              label: 'Move to trash',
              icon: AppIcons.delete,
              kind: FTButtonKind.danger,
              expand: true,
              onTap: () => _delete(context, ref),
            ),
          )),
        ],
      ),
    );
  }

  static String _personSubtitle(Person p, String? role) {
    final r = role?.trim();
    final life = p.lifespanLabel;
    if (r != null && r.isNotEmpty) return life.isEmpty ? r : '$r · $life';
    return life;
  }

  static String? _storySubtitle(Story s) {
    final d = FuzzyDate.tryParse(s.historicalDate);
    if (d != null && !d.isEmpty) return d.format();
    final body = s.body.replaceAll(RegExp(r'[#*>_`]'), '').trim();
    if (body.isEmpty) return null;
    return body.length > 90 ? '${body.substring(0, 90)}…' : body;
  }
}

class _HeroCard extends ConsumerWidget {
  const _HeroCard({required this.item, required this.people});
  final EventWithPeople item;
  final List<Person> people;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ft;
    final t = context.tx;
    final ev = item.event;
    final parsed = ev.fuzzyDate;
    final date = (parsed != null && !parsed.isEmpty) ? parsed : null;
    final place = ev.location?.trim();
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final avatars = avatarPairsFor(ref, g, [for (final p in people) p.id]);

    String? ago;
    if (date != null) {
      final exact = date.toDateTime();
      final today = DateUtils.dateOnly(DateTime.now());
      if (exact != null && exact.isAfter(today)) {
        ago = 'Upcoming';
      } else {
        final span = AgeSpan.between(date, null);
        if (span != null && span.years > 0) {
          ago = '${span.approximate ? 'about ' : ''}${span.years} ${span.years == 1 ? 'year' : 'years'} ago';
        }
      }
    }

    Widget info(IconData icon, String text, {String? trailing, bool muted = false}) => Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(icon, size: 17, color: c.text3),
              ),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: text, style: t.body.copyWith(color: muted ? c.text3 : c.text)),
                    if (trailing != null) TextSpan(text: '  ·  $trailing', style: t.caption),
                  ]),
                ),
              ),
            ],
          ),
        );

    return FTCard(
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconBadge(icon: AppIcons.forEvent(ev.type), size: 58, accent: true),
              const Spacer(),
              if (ev.remind) const FTTag('Yearly reminder', icon: AppIcons.bellRinging, accent: true),
            ],
          ),
          const SizedBox(height: Gap.lg),
          FTTag(ev.typeLabel),
          const SizedBox(height: Gap.sm),
          Semantics(
            header: true,
            child: Text(ev.title, style: t.headline),
          ),
          const SizedBox(height: Gap.sm),
          info(AppIcons.calendarBlank, date?.format(long: true) ?? 'Date unknown',
              trailing: ago, muted: date == null),
          if (place != null && place.isNotEmpty) info(AppIcons.location, place),
          if (avatars.isNotEmpty) ...[
            const SizedBox(height: Gap.lg),
            Row(
              children: [
                AvatarStack(people: avatars, size: 34, max: 4),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(
                    avatars.length == 1 ? avatars.first.$1 : '${avatars.length} people',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.caption,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
