import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database/app_database.dart';
import '../core/repositories/content_repository.dart';
import '../core/repositories/family_repository.dart';
import '../core/repositories/system_repository.dart';
import '../core/security/secure_vault.dart';
import '../core/services/app_paths.dart';
import '../features/family/domain/family_graph.dart';
import '../features/family/domain/kinship.dart';
import 'settings.dart';

// =================================================================== core

/// Overridden in main() once the encrypted database is open.
final databaseProvider = Provider<AppDatabase>((ref) => throw UnimplementedError());

/// Preferences loaded before the first frame (overridden in main()).
final initialPrefsProvider = Provider<AppPrefs>((ref) => const AppPrefs());

final vaultProvider = Provider<SecureVault>((ref) => SecureVault());

final familyRepoProvider = Provider((ref) => FamilyRepository(ref.watch(databaseProvider)));
final contentRepoProvider = Provider((ref) => ContentRepository(ref.watch(databaseProvider)));
final systemRepoProvider = Provider((ref) => SystemRepository(ref.watch(databaseProvider)));

// =============================================================== settings

final settingsProvider = NotifierProvider<SettingsController, AppPrefs>(SettingsController.new);

class SettingsController extends Notifier<AppPrefs> {
  @override
  AppPrefs build() => ref.read(initialPrefsProvider);

  Future<void> update(AppPrefs Function(AppPrefs p) change) async {
    state = change(state);
    await ref.read(systemRepoProvider).putSettings(state.toMap());
  }

  Future<void> setActiveTree(String id) => update((p) => p.copyWith(activeTreeId: id));
}

// ================================================================== trees

final treesProvider = StreamProvider<List<FamilyTree>>(
    (ref) => ref.watch(familyRepoProvider).watchTrees());

/// The tree currently being viewed. Falls back to the first tree when the
/// stored id no longer exists.
final activeTreeIdProvider = Provider<String?>((ref) {
  final trees = ref.watch(treesProvider).value;
  final wanted = ref.watch(settingsProvider.select((s) => s.activeTreeId));
  if (trees == null || trees.isEmpty) return wanted;
  if (wanted != null && trees.any((t) => t.id == wanted)) return wanted;
  return trees.first.id;
});

final activeTreeProvider = Provider<FamilyTree?>((ref) {
  final id = ref.watch(activeTreeIdProvider);
  final trees = ref.watch(treesProvider).value ?? const [];
  for (final t in trees) {
    if (t.id == id) return t;
  }
  return null;
});

// ================================================================= people

final peopleProvider = StreamProvider<List<Person>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(familyRepoProvider).watchPeople(tree);
});

final parentLinksProvider = StreamProvider<List<ParentChildLink>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(familyRepoProvider).watchParentLinks(tree);
});

final partnershipsProvider = StreamProvider<List<Partnership>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(familyRepoProvider).watchPartnerships(tree);
});

/// The in-memory family graph for the active tree. Rebuilt automatically
/// whenever people or relationships change, so every derived statistic and
/// the tree view stay current.
final familyGraphProvider = Provider<AsyncValue<FamilyGraph>>((ref) {
  final p = ref.watch(peopleProvider);
  final l = ref.watch(parentLinksProvider);
  final s = ref.watch(partnershipsProvider);
  for (final a in [p, l, s]) {
    if (a.hasError) return AsyncError(a.error!, a.stackTrace!);
  }
  if (!p.hasValue || !l.hasValue || !s.hasValue) return const AsyncLoading();
  return AsyncData(FamilyGraph(
    persons: p.value!,
    parentLinks: l.value!,
    partnerships: s.value!,
  ));
});

final kinshipProvider = Provider<KinshipCalculator?>((ref) {
  final g = ref.watch(familyGraphProvider).value;
  return g == null ? null : KinshipCalculator(g);
});

/// The tree's home person (or the first person), used as focus.
final homePersonIdProvider = Provider<String?>((ref) {
  final tree = ref.watch(activeTreeProvider);
  final g = ref.watch(familyGraphProvider).value;
  if (g == null || g.size == 0) return null;
  final h = tree?.homePersonId;
  if (h != null && g.contains(h)) return h;
  final sorted = g.people.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return sorted.first.id;
});

final personProvider = StreamProvider.family<Person?, String>(
    (ref, id) => ref.watch(familyRepoProvider).watchPerson(id));

// ================================================================ content

final mediaProvider = StreamProvider<List<MediaAsset>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(contentRepoProvider).watchMedia(tree);
});

/// Media by id (non-deleted) for quick lookups (avatars, covers).
final mediaByIdProvider = Provider<Map<String, MediaAsset>>((ref) {
  final list = ref.watch(mediaProvider).value ?? const [];
  return {for (final m in list) m.id: m};
});

/// Absolute thumbnail (or original) path for a person's profile photo.
final avatarPathProvider = Provider.family<String?, String?>((ref, mediaId) {
  if (mediaId == null || !AppPaths.isReady) return null;
  final m = ref.watch(mediaByIdProvider)[mediaId];
  if (m == null) return null;
  return AppPaths.I.resolve(m.thumbPath ?? m.filePath);
});

final mediaPeopleProvider = StreamProvider<List<MediaPerson>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(contentRepoProvider).watchMediaPeople(tree);
});

final mediaEventsProvider = StreamProvider<List<MediaEvent>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(contentRepoProvider).watchMediaEvents(tree);
});

final eventsProvider = StreamProvider<List<FamilyEvent>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(contentRepoProvider).watchEvents(tree);
});

final eventPeopleProvider = StreamProvider<List<EventPerson>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(contentRepoProvider).watchEventPeople(tree);
});

/// Events joined with their participants.
final eventsWithPeopleProvider = Provider<AsyncValue<List<EventWithPeople>>>((ref) {
  final e = ref.watch(eventsProvider);
  final ep = ref.watch(eventPeopleProvider);
  if (e.hasError) return AsyncError(e.error!, e.stackTrace!);
  if (!e.hasValue || !ep.hasValue) return const AsyncLoading();
  final byEvent = <String, List<EventPerson>>{};
  for (final x in ep.value!) {
    (byEvent[x.eventId] ??= []).add(x);
  }
  return AsyncData([
    for (final ev in e.value!)
      EventWithPeople(
        ev,
        [for (final x in byEvent[ev.id] ?? const <EventPerson>[]) x.personId],
        {for (final x in byEvent[ev.id] ?? const <EventPerson>[]) x.personId: x.role},
      )
  ]);
});

final albumsProvider = StreamProvider<List<Album>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(contentRepoProvider).watchAlbums(tree);
});

final albumEntriesProvider = StreamProvider<List<AlbumMediaEntry>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(contentRepoProvider).watchAlbumEntries(tree);
});

final storiesProvider = StreamProvider<List<Story>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(contentRepoProvider).watchStories(tree);
});

final storyPeopleProvider = StreamProvider<List<StoryPerson>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(contentRepoProvider).watchStoryPeople(tree);
});

final storyEventsProvider = StreamProvider<List<StoryEvent>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(contentRepoProvider).watchStoryEvents(tree);
});

final storyMediaProvider = StreamProvider<List<StoryMediaEntry>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(contentRepoProvider).watchStoryMedia(tree);
});

final storyTagsProvider = StreamProvider<List<StoryTag>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(contentRepoProvider).watchStoryTags(tree);
});

final sourcesProvider = StreamProvider<List<Source>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(contentRepoProvider).watchSources(tree);
});

final citationsProvider = StreamProvider<List<Citation>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(contentRepoProvider).watchCitations(tree);
});

final remindersProvider = StreamProvider<List<Reminder>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(contentRepoProvider).watchReminders(tree);
});

final branchesProvider = StreamProvider<List<FamilyBranch>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(familyRepoProvider).watchBranches(tree);
});

final branchMembersProvider = StreamProvider<List<PersonBranch>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(familyRepoProvider).watchBranchMembers(tree);
});

final tagsProvider = StreamProvider<List<Tag>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(familyRepoProvider).watchTags(tree);
});

final personTagsProvider = StreamProvider<List<PersonTag>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(familyRepoProvider).watchPersonTags(tree);
});

final customFieldsProvider = StreamProvider<List<CustomField>>((ref) {
  final tree = ref.watch(activeTreeIdProvider);
  if (tree == null) return Stream.value(const []);
  return ref.watch(familyRepoProvider).watchCustomFields(tree);
});

final trashProvider = StreamProvider<List<DeletionRecord>>(
    (ref) => ref.watch(systemRepoProvider).watchTrash());

final backupHistoryProvider = StreamProvider<List<BackupRecord>>(
    (ref) => ref.watch(systemRepoProvider).watchBackupHistory());
