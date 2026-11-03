import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'notification_planner.dart';

/// On-device reminder notifications (flutter_local_notifications + timezone).
///
/// Every call is defensive: on platforms without the plugin (unit tests,
/// desktop) or when the platform refuses, methods return `false` / `0`
/// instead of throwing. Nothing ever leaves the device.
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const channelId = 'family_reminders';
  static const channelName = 'Family reminders';
  static const channelDescription =
      'Birthdays, anniversaries, memorials, family events and your own reminders';
  static const testId = 1;

  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      color: Color(0xFF86D8CA),
      category: AndroidNotificationCategory.reminder,
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentSound: true,
      threadIdentifier: channelId,
    ),
  );

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  Future<bool>? _init;
  bool _ready = false;
  Future<void> _queue = Future<void>.value();
  String? _lastSignature;
  String? _launchPayload;
  bool _launchChecked = false;

  /// Called with the payload when the user taps a notification while the
  /// app is running.
  void Function(String? payload)? onSelect;

  /// Whether this platform supports local notifications at all.
  bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  /// True once the plugin initialised successfully.
  bool get isReady => _ready;

  /// Initialises the plugin and time zones once (lazily, on first use).
  Future<bool> ensureInitialized() {
    final existing = _init;
    if (existing != null) return existing;
    final f = _initialize();
    _init = f;
    return f;
  }

  Future<bool> _initialize() async {
    if (!isSupported) return false;
    try {
      tzdata.initializeTimeZones();
      try {
        final info = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(info.identifier));
      } catch (_) {
        tz.setLocalLocation(tz.UTC);
      }
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/launcher_icon'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: (r) => onSelect?.call(r.payload),
      );
      try {
        await _android?.createNotificationChannel(const AndroidNotificationChannel(
          channelId,
          channelName,
          description: channelDescription,
          importance: Importance.high,
        ));
      } catch (_) {
        // Channel is also created on first notification.
      }
      _ready = true;
      return true;
    } catch (e) {
      debugPrint('NotificationService: init failed: $e');
      _init = null; // allow a later retry
      return false;
    }
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  IOSFlutterLocalNotificationsPlugin? get _ios =>
      _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();

  /// Asks the OS for permission (Android 13+ runtime permission, iOS alert,
  /// badge and sound). Returns whether notifications may be shown.
  Future<bool> requestPermission() async {
    if (!await ensureInitialized()) return false;
    try {
      if (Platform.isAndroid) {
        final android = _android;
        if (android == null) return false;
        final granted = await android.requestNotificationsPermission();
        if (granted != null) return granted;
        return await android.areNotificationsEnabled() ?? false;
      }
      if (Platform.isIOS) {
        return await _ios?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
      }
    } catch (e) {
      debugPrint('NotificationService: permission request failed: $e');
    }
    return false;
  }

  /// Whether the OS currently allows this app's notifications.
  Future<bool> hasPermission() async {
    if (!await ensureInitialized()) return false;
    try {
      if (Platform.isAndroid) return await _android?.areNotificationsEnabled() ?? false;
      if (Platform.isIOS) return (await _ios?.checkPermissions())?.isEnabled ?? false;
    } catch (_) {}
    return false;
  }

  /// Opens the system notification settings for the app.
  Future<bool> openSystemSettings() async {
    if (!await ensureInitialized()) return false;
    try {
      return await _plugin.openAppNotificationSettings() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Payload of the notification that launched the app, if any (read once).
  Future<String?> takeLaunchPayload() async {
    if (_launchChecked) {
      final p = _launchPayload;
      _launchPayload = null;
      return p;
    }
    _launchChecked = true;
    if (!await ensureInitialized()) return null;
    try {
      final d = await _plugin.getNotificationAppLaunchDetails();
      if (d?.didNotificationLaunchApp ?? false) return d!.notificationResponse?.payload;
    } catch (_) {}
    return null;
  }

  /// Cancels all pending notifications, then schedules [plan] (one-shot,
  /// inexact, allowed while idle – no exact-alarm permission needed).
  /// Calls are serialised; identical consecutive plans are skipped.
  /// Returns the number of scheduled notifications.
  Future<int> reschedule(List<PlannedNotification> plan, {bool force = false}) {
    final c = Completer<int>();
    _queue = _queue.then((_) async {
      try {
        c.complete(await _apply(plan, force: force));
      } catch (e) {
        debugPrint('NotificationService: reschedule failed: $e');
        c.complete(0);
      }
    });
    return c.future;
  }

  Future<int> _apply(List<PlannedNotification> plan, {required bool force}) async {
    if (!await ensureInitialized()) return 0;
    final signature = plan.map((p) => p.signature).join('\n');
    if (!force && signature == _lastSignature) return plan.length;
    await _cancelPending();
    final now = tz.TZDateTime.now(tz.local);
    var n = 0;
    for (final p in plan.take(NotificationPlanner.maxPending)) {
      final when = tz.TZDateTime(
          tz.local, p.when.year, p.when.month, p.when.day, p.when.hour, p.when.minute);
      if (!when.isAfter(now)) continue;
      try {
        await _plugin.zonedSchedule(
          id: p.id,
          scheduledDate: when,
          notificationDetails: _details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          title: p.title,
          body: p.body,
          payload: p.payload,
        );
        n++;
      } catch (e) {
        debugPrint('NotificationService: could not schedule ${p.id}: $e');
      }
    }
    _lastSignature = signature;
    return n;
  }

  Future<void> _cancelPending() async {
    try {
      await _plugin.cancelAllPendingNotifications();
    } catch (_) {
      try {
        await _plugin.cancelAll();
      } catch (_) {}
    }
  }

  /// Removes every scheduled reminder (used when notifications are off).
  Future<void> cancelAll() {
    final c = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        if (await ensureInitialized()) {
          await _cancelPending();
          _lastSignature = null;
        }
      } catch (_) {}
      c.complete();
    });
    return c.future;
  }

  /// Number of notifications currently pending in the OS.
  Future<int> pendingCount() async {
    if (!await ensureInitialized()) return 0;
    try {
      return (await _plugin.pendingNotificationRequests()).length;
    } catch (_) {
      return 0;
    }
  }

  /// Shows an immediate sample notification. Returns false if it could not.
  Future<bool> showTest() async {
    if (!await ensureInitialized()) return false;
    try {
      await _plugin.show(
        id: testId,
        title: 'Family Tales',
        body: 'Notifications are working. Family birthdays and reminders will appear like this.',
        notificationDetails: _details,
        payload: 'calendar',
      );
      return true;
    } catch (e) {
      debugPrint('NotificationService: test failed: $e');
      return false;
    }
  }
}
