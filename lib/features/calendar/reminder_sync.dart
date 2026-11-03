import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/settings.dart';
import '../family/domain/occasions.dart';
import 'calendar_logic.dart';
import 'notification_planner.dart';
import 'notification_service.dart';

/// Wraps the app and keeps scheduled local notifications in sync with the
/// family data: whenever people, events, reminders or notification
/// preferences change (debounced) and when the app returns to the
/// foreground. The notification plugin is initialised lazily, only once
/// notifications are enabled.
class ReminderSync extends ConsumerStatefulWidget {
  const ReminderSync({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<ReminderSync> createState() => _ReminderSyncState();
}

class _ReminderSyncState extends ConsumerState<ReminderSync> with WidgetsBindingObserver {
  static const _debounce = Duration(seconds: 2);

  Timer? _timer;
  bool _launchHandled = false;
  VoidCallback? _routerListener;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.instance.onSelect = _open;
    _queue();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _detachRouterListener();
    if (NotificationService.instance.onSelect == _open) {
      NotificationService.instance.onSelect = null;
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Dates roll over while the app sleeps: refresh on resume.
    if (state == AppLifecycleState.resumed) _queue(delay: const Duration(milliseconds: 600));
  }

  void _queue({Duration delay = _debounce}) {
    _timer?.cancel();
    _timer = Timer(delay, _sync);
  }

  Future<void> _sync() async {
    if (!mounted) return;
    final prefs = ref.read(settingsProvider);
    final service = NotificationService.instance;
    if (!prefs.notificationsEnabled) {
      // Only touch the plugin if it was ever started in this session.
      if (service.isReady) await service.cancelAll();
      return;
    }
    if (!service.isSupported) return;
    final calc = ref.read(occasionCalculatorProvider).value;
    if (calc == null) return; // data still loading: the listeners retrigger.
    final List<OccasionCalculator> all;
    try {
      all = [calc, ...await _otherTrees(ref.read(activeTreeIdProvider))];
    } catch (e) {
      debugPrint('ReminderSync: could not read other trees: $e');
      return;
    }
    if (!mounted) return;
    final plan = NotificationPlanner.planAll(calculators: all, prefs: prefs);
    await service.reschedule(plan);
    if (!_launchHandled) {
      _launchHandled = true;
      final payload = await service.takeLaunchPayload();
      if (payload != null && mounted) _openWhenReady(payload);
    }
  }

  /// Occasion calculators for every tree except the active one (which is
  /// already loaded and kept live by providers).
  Future<List<OccasionCalculator>> _otherTrees(String? activeId) async {
    final family = ref.read(familyRepoProvider);
    final content = ref.read(contentRepoProvider);
    final out = <OccasionCalculator>[];
    for (final t in await family.allTrees()) {
      if (t.id == activeId) continue;
      final graph = await family.loadGraph(t.id);
      final events = await content.watchEvents(t.id).first;
      final people = await content.watchEventPeople(t.id).first;
      final reminders = await content.watchReminders(t.id).first;
      final byEvent = <String, List<String>>{};
      for (final p in people) {
        (byEvent[p.eventId] ??= []).add(p.personId);
      }
      out.add(OccasionCalculator(graph: graph, events: events, eventPeople: byEvent, reminders: reminders));
    }
    return out;
  }

  // ------------------------------------------------------- notification taps

  /// Opens the screen a notification refers to.
  void _open(String? payload) {
    if (!mounted || payload == null || payload.isEmpty) return;
    try {
      final router = ref.read(routerProvider);
      final i = payload.indexOf(':');
      final kind = i < 0 ? payload : payload.substring(0, i);
      final id = i < 0 ? '' : payload.substring(i + 1);
      switch (kind) {
        case 'person' when id.isNotEmpty:
          _showTreeOf(id);
          router.push(Routes.person(id));
        case 'event' when id.isNotEmpty:
          router.push(Routes.event(id));
        default:
          router.push(Routes.calendar);
      }
    } catch (e) {
      debugPrint('ReminderSync: could not open notification target: $e');
    }
  }

  /// Notifications can come from any tree: switch to the person's tree so
  /// their profile shows the right family.
  Future<void> _showTreeOf(String personId) async {
    final p = await ref.read(familyRepoProvider).person(personId);
    if (p == null || !mounted || p.treeId == ref.read(activeTreeIdProvider)) return;
    await ref.read(settingsProvider.notifier).setActiveTree(p.treeId);
  }

  /// A notification that launched the app is opened once the splash /
  /// onboarding routes have been left.
  void _openWhenReady(String payload) {
    try {
      final router = ref.read(routerProvider);
      final delegate = router.routerDelegate;
      void attempt() {
        final path = delegate.currentConfiguration.uri.path;
        if (path.isEmpty || path == Routes.splash || path == Routes.welcome) return;
        _detachRouterListener();
        _open(payload);
      }

      _routerListener = attempt;
      delegate.addListener(attempt);
      attempt();
    } catch (e) {
      debugPrint('ReminderSync: launch payload ignored: $e');
    }
  }

  void _detachRouterListener() {
    final l = _routerListener;
    if (l == null) return;
    _routerListener = null;
    try {
      ref.read(routerProvider).routerDelegate.removeListener(l);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    void onError(Object _, StackTrace _) {}
    ref.listen(familyGraphProvider, (_, _) => _queue(), onError: onError);
    ref.listen(eventsWithPeopleProvider, (_, _) => _queue(), onError: onError);
    ref.listen(remindersProvider, (_, _) => _queue(), onError: onError);
    ref.listen(settingsProvider, (prev, next) {
      if (prev == null ||
          prev.notificationsEnabled != next.notificationsEnabled ||
          prev.notifyBirthdays != next.notifyBirthdays ||
          prev.notifyAnniversaries != next.notifyAnniversaries ||
          prev.notifyMemorials != next.notifyMemorials ||
          prev.notifyEvents != next.notifyEvents ||
          prev.notifyCustom != next.notifyCustom ||
          prev.notifyHour != next.notifyHour ||
          !_sameLeads(prev, next)) {
        _queue();
      }
    }, onError: onError);
    return widget.child;
  }

  static bool _sameLeads(AppPrefs a, AppPrefs b) =>
      a.reminderLeads.length == b.reminderLeads.length &&
      a.reminderLeads.containsAll(b.reminderLeads);
}
