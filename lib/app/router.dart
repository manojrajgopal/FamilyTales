import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/widgets/widgets.dart';
import '../features/backup/backup_screen.dart';
import '../features/backup/export_screen.dart';
import '../features/backup/gedcom_import_screen.dart';
import '../features/backup/pdf_preview_screen.dart';
import '../features/backup/restore_screen.dart';
import '../features/branches/branches_screen.dart';
import '../features/calendar/calendar_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/events/event_detail_screen.dart';
import '../features/events/event_form_screen.dart';
import '../features/events/event_list_screen.dart';
import '../features/family_tree/family_tree_screen.dart';
import '../features/gallery/album_detail_screen.dart';
import '../features/gallery/gallery_screen.dart';
import '../features/gallery/media_edit_screen.dart';
import '../features/gallery/photo_viewer_screen.dart';
import '../features/members/custom_fields_screen.dart';
import '../features/members/duplicates_screen.dart';
import '../features/members/members_screen.dart';
import '../features/members/person_form_screen.dart';
import '../features/members/person_profile_screen.dart';
import '../features/onboarding/onboarding_flow.dart';
import '../features/onboarding/splash_screen.dart';
import '../features/relationships/relationship_finder_screen.dart';
import '../features/relationships/relationships_screen.dart';
import '../features/reports/insights_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/about_screen.dart';
import '../features/settings/appearance_settings_screen.dart';
import '../features/settings/dashboard_settings_screen.dart';
import '../features/settings/more_screen.dart';
import '../features/settings/notification_settings_screen.dart';
import '../features/settings/security_settings_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/storage_screen.dart';
import '../features/settings/trash_screen.dart';
import '../features/sources/source_detail_screen.dart';
import '../features/sources/sources_screen.dart';
import '../features/stories/stories_screen.dart';
import '../features/stories/story_editor_screen.dart';
import '../features/stories/story_reader_screen.dart';
import '../features/timeline/timeline_screen.dart';
import '../features/trees/trees_screen.dart';
import 'navigation/app_shell.dart';
import 'providers.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// Route paths. Use these constants (or `context.push('/person/$id')`).
abstract final class Routes {
  static const splash = '/splash';
  static const welcome = '/welcome';
  static const home = '/home';
  static const tree = '/tree';
  static const members = '/members';
  static const timeline = '/timeline';
  static const more = '/more';
  static String person(String id) => '/person/$id';
  static String personEdit(String id) => '/person/$id/edit';
  static String personRelationships(String id) => '/person/$id/relationships';

  /// `/person/new?relation=father&anchor=<personId>`
  static String newPerson({String? relation, String? anchorId}) {
    final q = <String, String>{
      'relation': ?relation,
      'anchor': ?anchorId,
    };
    return Uri(path: '/person/new', queryParameters: q.isEmpty ? null : q).toString();
  }

  static const relationshipFinder = '/relationship-finder';
  static const branches = '/branches';
  static const calendar = '/calendar';
  static const events = '/events';
  static String event(String id) => '/events/$id';
  static String eventEdit(String id) => '/events/$id/edit';
  static String newEvent({String? personId}) =>
      Uri(path: '/events/new', queryParameters: personId == null ? null : {'person': personId}).toString();
  static const gallery = '/gallery';
  static String album(String id) => '/albums/$id';
  static String media(String id) => '/media/$id';
  static String mediaEdit(String id) => '/media/$id/edit';
  static const stories = '/stories';
  static String story(String id) => '/stories/$id';
  static String storyEdit(String id) => '/stories/$id/edit';
  static String newStory({String? personId}) =>
      Uri(path: '/stories/new', queryParameters: personId == null ? null : {'person': personId}).toString();
  static const sources = '/sources';
  static String source(String id) => '/sources/$id';
  static const search = '/search';
  static const insights = '/insights';
  static const backup = '/backup';
  static const restore = '/backup/restore';
  static const gedcomImport = '/gedcom/import';
  static const export = '/export';
  static String pdf({String kind = 'tree', String? personId}) =>
      Uri(path: '/export/pdf', queryParameters: {'kind': kind, 'person': ?personId}).toString();
  static const settings = '/settings';
  static const appearance = '/settings/appearance';
  static const security = '/settings/security';
  static const notifications = '/settings/notifications';
  static const storage = '/settings/storage';
  static const dashboardSettings = '/settings/dashboard';
  static const trash = '/trash';
  static const about = '/about';
  static const trees = '/trees';
  static const duplicates = '/duplicates';
  static const customFields = '/custom-fields';
}

/// Fade-through + subtle rise transition; instant with reduced motion.
CustomTransitionPage<void> _page(GoRouterState state, Widget child) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: Motion.medium,
    reverseTransitionDuration: const Duration(milliseconds: 220),
    transitionsBuilder: (context, animation, secondary, child) {
      if (MediaQuery.of(context).disableAnimations) return child;
      final curved = CurvedAnimation(parent: animation, curve: Motion.emphasized);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.035), end: Offset.zero).animate(curved),
          child: child,
        ),
      );
    },
  );
}

GoRoute _r(String path, Widget Function(GoRouterState s) build) => GoRoute(
      path: path,
      parentNavigatorKey: rootNavigatorKey,
      pageBuilder: (context, state) => _page(state, build(state)),
    );

final routerProvider = Provider<GoRouter>((ref) {
  final onboarded = ValueNotifier<bool>(ref.read(settingsProvider).onboardingDone);
  ref.listen(settingsProvider.select((s) => s.onboardingDone), (_, v) => onboarded.value = v);
  ref.onDispose(onboarded.dispose);

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: Routes.splash,
    refreshListenable: onboarded,
    redirect: (context, state) {
      final loc = state.matchedLocation;
      if (loc == Routes.splash) return null;
      if (!onboarded.value && loc != Routes.welcome) return Routes.welcome;
      if (onboarded.value && loc == Routes.welcome) return Routes.home;
      return null;
    },
    routes: [
      GoRoute(path: Routes.splash, pageBuilder: (c, s) => _page(s, const SplashScreen())),
      GoRoute(path: Routes.welcome, pageBuilder: (c, s) => _page(s, const OnboardingFlow())),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: Routes.home, builder: (c, s) => const DashboardScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: Routes.tree,
              builder: (c, s) => FamilyTreeScreen(focusId: s.uri.queryParameters['focus']),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: Routes.members, builder: (c, s) => const MembersScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: Routes.timeline, builder: (c, s) => const TimelineScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: Routes.more, builder: (c, s) => const MoreScreen()),
          ]),
        ],
      ),
      _r('/person/new', (s) => PersonFormScreen(
            relation: s.uri.queryParameters['relation'],
            anchorId: s.uri.queryParameters['anchor'],
          )),
      _r('/person/:id', (s) => PersonProfileScreen(personId: s.pathParameters['id']!)),
      _r('/person/:id/edit', (s) => PersonFormScreen(personId: s.pathParameters['id'])),
      _r('/person/:id/relationships', (s) => RelationshipsScreen(personId: s.pathParameters['id']!)),
      _r(Routes.relationshipFinder, (s) => RelationshipFinderScreen(
            aId: s.uri.queryParameters['a'],
            bId: s.uri.queryParameters['b'],
          )),
      _r(Routes.branches, (s) => const BranchesScreen()),
      _r(Routes.calendar, (s) => const CalendarScreen()),
      _r(Routes.events, (s) => const EventListScreen()),
      _r('/events/new', (s) => EventFormScreen(personId: s.uri.queryParameters['person'])),
      _r('/events/:id', (s) => EventDetailScreen(eventId: s.pathParameters['id']!)),
      _r('/events/:id/edit', (s) => EventFormScreen(eventId: s.pathParameters['id'])),
      _r(Routes.gallery, (s) => const GalleryScreen()),
      _r('/albums/:id', (s) => AlbumDetailScreen(albumId: s.pathParameters['id']!)),
      _r('/media/:id', (s) => PhotoViewerScreen(
            mediaId: s.pathParameters['id']!,
            contextIds: s.extra is List<String> ? s.extra as List<String> : null,
          )),
      _r('/media/:id/edit', (s) => MediaEditScreen(mediaId: s.pathParameters['id']!)),
      _r(Routes.stories, (s) => const StoriesScreen()),
      _r('/stories/new', (s) => StoryEditorScreen(personId: s.uri.queryParameters['person'])),
      _r('/stories/:id', (s) => StoryReaderScreen(storyId: s.pathParameters['id']!)),
      _r('/stories/:id/edit', (s) => StoryEditorScreen(storyId: s.pathParameters['id'])),
      _r(Routes.sources, (s) => const SourcesScreen()),
      _r('/sources/:id', (s) => SourceDetailScreen(sourceId: s.pathParameters['id']!)),
      _r(Routes.search, (s) => const SearchScreen()),
      _r(Routes.insights, (s) => const InsightsScreen()),
      _r(Routes.backup, (s) => const BackupScreen()),
      _r(Routes.restore, (s) => const RestoreScreen()),
      _r(Routes.gedcomImport, (s) => const GedcomImportScreen()),
      _r(Routes.export, (s) => const ExportScreen()),
      _r('/export/pdf', (s) => PdfPreviewScreen(
            kind: s.uri.queryParameters['kind'] ?? 'tree',
            personId: s.uri.queryParameters['person'],
          )),
      _r(Routes.settings, (s) => const SettingsScreen()),
      _r(Routes.appearance, (s) => const AppearanceSettingsScreen()),
      _r(Routes.security, (s) => const SecuritySettingsScreen()),
      _r(Routes.notifications, (s) => const NotificationSettingsScreen()),
      _r(Routes.storage, (s) => const StorageScreen()),
      _r(Routes.dashboardSettings, (s) => const DashboardSettingsScreen()),
      _r(Routes.trash, (s) => const TrashScreen()),
      _r(Routes.about, (s) => const AboutScreen()),
      _r(Routes.trees, (s) => const TreesScreen()),
      _r(Routes.duplicates, (s) => const DuplicatesScreen()),
      _r(Routes.customFields, (s) => const CustomFieldsScreen()),
    ],
  );
});
