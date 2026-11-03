import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/database/app_database.dart';
import '../family/domain/family_graph.dart';
import '../gallery/media_tools.dart';
import 'story_text.dart';

/// Everything a story links to.
class StoryLinks {
  const StoryLinks({
    this.personIds = const [],
    this.eventIds = const [],
    this.mediaIds = const [],
    this.tagIds = const [],
  });

  final List<String> personIds;
  final List<String> eventIds;

  /// In story order.
  final List<String> mediaIds;
  final List<String> tagIds;
}

/// Story id → links, joined from the story link tables. Updates live.
final storyLinksProvider = Provider<Map<String, StoryLinks>>((ref) {
  final people = ref.watch(storyPeopleProvider).value ?? const <StoryPerson>[];
  final events = ref.watch(storyEventsProvider).value ?? const <StoryEvent>[];
  final media = [...ref.watch(storyMediaProvider).value ?? const <StoryMediaEntry>[]]
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  final tags = ref.watch(storyTagsProvider).value ?? const <StoryTag>[];
  final p = <String, List<String>>{};
  final e = <String, List<String>>{};
  final m = <String, List<String>>{};
  final t = <String, List<String>>{};
  for (final x in people) {
    (p[x.storyId] ??= []).add(x.personId);
  }
  for (final x in events) {
    (e[x.storyId] ??= []).add(x.eventId);
  }
  for (final x in media) {
    (m[x.storyId] ??= []).add(x.mediaId);
  }
  for (final x in tags) {
    (t[x.storyId] ??= []).add(x.tagId);
  }
  final ids = {...p.keys, ...e.keys, ...m.keys, ...t.keys};
  return {
    for (final id in ids)
      id: StoryLinks(
        personIds: p[id] ?? const [],
        eventIds: e[id] ?? const [],
        mediaIds: m[id] ?? const [],
        tagIds: t[id] ?? const [],
      ),
  };
});

/// Photos of a story that still exist, in order.
List<MediaAsset> storyPhotos(StoryLinks links, Map<String, MediaAsset> byId) => [
      for (final id in links.mediaIds)
        if (byId[id] != null && byId[id]!.isImage) byId[id]!,
    ];

/// Explicit cover, or the first photo.
MediaAsset? storyCover(Story s, StoryLinks links, Map<String, MediaAsset> byId) {
  final explicit = s.coverMediaId == null ? null : byId[s.coverMediaId];
  if (explicit != null && explicit.isImage) return explicit;
  final photos = storyPhotos(links, byId);
  return photos.isEmpty ? null : photos.first;
}

/// Search + filter for the stories list.
class StoryFilter {
  const StoryFilter({this.query = '', this.tagId, this.personId});
  final String query;
  final String? tagId;
  final String? personId;

  StoryFilter copyWith({String? query, String? tagId, String? personId, bool clearTag = false, bool clearPerson = false}) =>
      StoryFilter(
        query: query ?? this.query,
        tagId: clearTag ? null : (tagId ?? this.tagId),
        personId: clearPerson ? null : (personId ?? this.personId),
      );

  List<Story> apply(
    List<Story> stories,
    Map<String, StoryLinks> links,
    Map<String, Tag> tags,
    FamilyGraph graph,
  ) {
    final q = query.trim().toLowerCase();
    return [
      for (final s in stories)
        if (_matches(s, links[s.id] ?? const StoryLinks(), tags, graph, q)) s,
    ];
  }

  bool _matches(Story s, StoryLinks l, Map<String, Tag> tags, FamilyGraph g, String q) {
    if (tagId != null && !l.tagIds.contains(tagId)) return false;
    if (personId != null && !l.personIds.contains(personId)) return false;
    if (q.isEmpty) return true;
    if (s.title.toLowerCase().contains(q)) return true;
    if (StoryText.stripInline(s.body).toLowerCase().contains(q)) return true;
    if ((s.sourceText ?? '').toLowerCase().contains(q)) return true;
    for (final t in l.tagIds) {
      if (tags[t]?.name.toLowerCase().contains(q) ?? false) return true;
    }
    for (final p in l.personIds) {
      if (g[p]?.displayName.toLowerCase().contains(q) ?? false) return true;
    }
    return false;
  }
}
