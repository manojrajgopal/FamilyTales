import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/settings.dart';
import '../../core/widgets/widgets.dart';
import '../calendar/calendar_logic.dart';
import '../calendar/calendar_widgets.dart';
import '../calendar/notification_planner.dart';
import '../calendar/notification_service.dart';
import '../family/domain/occasions.dart';

/// Reminder notification preferences: master switch (with OS permission),
/// categories, lead times, delivery hour, a test notification and a preview
/// of what will be scheduled.
class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  ConsumerState<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends ConsumerState<NotificationSettingsScreen>
    with WidgetsBindingObserver {
  final _service = NotificationService.instance;
  late final ScrollController _hours =
      ScrollController(initialScrollOffset: ((ref.read(settingsProvider).notifyHour - 1).clamp(0, 23)) * 82.0);

  bool _busy = false;

  /// The OS refuses notifications for this app.
  bool _blocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hours.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user may come back from the system settings.
    if (state == AppLifecycleState.resumed) _checkPermission();
  }

  Future<void> _checkPermission() async {
    final enabled = ref.read(settingsProvider).notificationsEnabled;
    if (!_service.isSupported || (!enabled && !_blocked)) return;
    final ok = await _service.hasPermission();
    if (mounted && _blocked != !ok) setState(() => _blocked = !ok);
  }

  Future<void> _update(AppPrefs Function(AppPrefs p) change) =>
      ref.read(settingsProvider.notifier).update(change);

  Future<void> _setEnabled(bool on) async {
    if (_busy) return;
    if (!on) {
      await _update((p) => p.copyWith(notificationsEnabled: false));
      await _service.cancelAll();
      if (mounted) {
        setState(() => _blocked = false);
        showFTToast(context, 'Reminder notifications turned off');
      }
      return;
    }
    if (!_service.isSupported) {
      showFTToast(context, 'Notifications aren’t available on this device', error: true);
      return;
    }
    setState(() => _busy = true);
    final granted = await _service.requestPermission();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _blocked = !granted;
    });
    if (!granted) {
      await _explainBlocked();
      return;
    }
    await _update((p) => p.copyWith(notificationsEnabled: true));
    if (mounted) showFTToast(context, 'Reminder notifications turned on');
  }

  Future<void> _explainBlocked() async {
    final open = await showFTConfirm(
      context,
      title: 'Notifications are blocked',
      message: 'Family Tales isn’t allowed to show notifications. Open the system settings, '
          'choose Notifications and allow them for Family Tales, then come back and turn reminders on.',
      confirmLabel: 'Open settings',
      cancelLabel: 'Not now',
      icon: AppIcons.bell,
    );
    if (open) {
      final ok = await _service.openSystemSettings();
      if (!ok && mounted) {
        showFTToast(context, 'Open Settings › Apps › Family Tales › Notifications', error: true);
      }
    }
  }

  Future<void> _sendTest() async {
    if (!_service.isSupported) {
      showFTToast(context, 'Notifications aren’t available on this device', error: true);
      return;
    }
    setState(() => _busy = true);
    var allowed = await _service.hasPermission();
    if (!allowed) allowed = await _service.requestPermission();
    if (!mounted) return;
    if (!allowed) {
      setState(() {
        _busy = false;
        _blocked = true;
      });
      await _explainBlocked();
      return;
    }
    final sent = await _service.showTest();
    if (!mounted) return;
    setState(() => _busy = false);
    showFTToast(
      context,
      sent ? 'Test notification sent' : 'Could not show a notification',
      error: !sent,
    );
  }

  void _toggleLead(AppPrefs prefs, ReminderLead lead) {
    final next = {...prefs.reminderLeads};
    if (next.contains(lead)) {
      if (next.length == 1) {
        showFTToast(context, 'Keep at least one reminder time');
        return;
      }
      next.remove(lead);
    } else {
      next.add(lead);
    }
    _update((p) => p.copyWith(reminderLeads: next));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final t = context.tx;
    final pad = context.pagePadding;
    final prefs = ref.watch(settingsProvider);
    final on = prefs.notificationsEnabled;
    final calc = ref.watch(occasionCalculatorProvider).value;
    final plan = calc == null
        ? const <PlannedNotification>[]
        : NotificationPlanner.plan(calculator: calc, prefs: prefs);

    Widget gap([double h = Gap.xl]) => SizedBox(height: h);

    final categories = <(OccasionKind, String, String, IconData, bool, AppPrefs Function(AppPrefs, bool))>[
      (OccasionKind.birthday, 'Birthdays', 'Living relatives with a known day and month', AppIcons.cake,
          prefs.notifyBirthdays, (p, v) => p.copyWith(notifyBirthdays: v)),
      (OccasionKind.anniversary, 'Anniversaries', 'Couples who are together', AppIcons.heart,
          prefs.notifyAnniversaries, (p, v) => p.copyWith(notifyAnniversaries: v)),
      (OccasionKind.memorial, 'Memorials', 'Remembrance days of relatives who passed', AppIcons.candle,
          prefs.notifyMemorials, (p, v) => p.copyWith(notifyMemorials: v)),
      (OccasionKind.event, 'Family events', 'Dated events and yearly event reminders', AppIcons.event,
          prefs.notifyEvents, (p, v) => p.copyWith(notifyEvents: v)),
      (OccasionKind.reminder, 'Your reminders', 'Reminders you added in the calendar', AppIcons.bell,
          prefs.notifyCustom, (p, v) => p.copyWith(notifyCustom: v)),
    ];

    return FTPage(
      title: 'Notifications',
      body: ListView(
        padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, FTPage.bottomInset(context)),
        children: [
          ContentWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FadeSlideIn(
                  child: FTCard(
                    highlighted: on && !_blocked,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            IconBadge(icon: AppIcons.bellRinging, size: 52, accent: on && !_blocked),
                            const Spacer(),
                            if (_busy)
                              SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
                              ),
                          ],
                        ),
                        gap(Gap.md),
                        Text('Family reminders', style: t.title),
                        gap(Gap.xxs),
                        Text(
                          'Gentle notifications for birthdays, anniversaries and your own reminders – '
                          'scheduled on this device, nothing is sent anywhere.',
                          style: t.body,
                        ),
                        gap(Gap.md),
                        FTSwitchRow(
                          title: 'Allow notifications',
                          subtitle: on ? (_blocked ? 'Blocked in system settings' : 'On') : 'Off',
                          value: on,
                          onChanged: _busy ? null : _setEnabled,
                        ),
                      ],
                    ),
                  ),
                ),
                if (_blocked) ...[
                  gap(Gap.md),
                  FTCard(
                    color: c.warning.withValues(alpha: c.isDark ? 0.10 : 0.12),
                    shadow: false,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(AppIcons.warning, color: c.warning, size: 22),
                        const SizedBox(width: Gap.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Notifications are blocked', style: t.bodyStrong),
                              gap(Gap.xxs),
                              Text(
                                'Allow notifications for Family Tales in your system settings, then return here.',
                                style: t.caption,
                              ),
                              gap(Gap.xs),
                              FTTextAction('Open system settings', accent: true, onTap: () async {
                                final ok = await _service.openSystemSettings();
                                if (!ok && context.mounted) {
                                  showFTToast(context, 'Open Settings › Apps › Family Tales › Notifications',
                                      error: true);
                                }
                              }),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                gap(),
                const SectionHeader('Remind me about'),
                FadeSlideIn(
                  index: 1,
                  child: FTCard(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
                    child: Column(
                      children: [
                        for (final (_, title, sub, icon, value, apply) in categories)
                          FTSwitchRow(
                            icon: icon,
                            title: title,
                            subtitle: sub,
                            value: value,
                            onChanged: (v) => _update((p) => apply(p, v)),
                          ),
                      ],
                    ),
                  ),
                ),
                gap(),
                const SectionHeader('When'),
                FadeSlideIn(
                  index: 2,
                  child: FTCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Notify me', style: t.caption),
                        gap(Gap.xs),
                        Wrap(
                          spacing: Gap.xs,
                          runSpacing: Gap.xs,
                          children: [
                            for (final lead in ReminderLead.values)
                              FTChip(
                                label: lead.label,
                                icon: prefs.reminderLeads.contains(lead) ? AppIcons.check : null,
                                selected: prefs.reminderLeads.contains(lead),
                                onTap: () => _toggleLead(prefs, lead),
                              ),
                          ],
                        ),
                        gap(Gap.lg),
                        Row(
                          children: [
                            Expanded(child: Text('Time of day', style: t.caption)),
                            Text(formatClock(context, prefs.notifyHour, 0),
                                style: t.label.copyWith(color: c.accent)),
                          ],
                        ),
                        gap(Gap.xs),
                        SizedBox(
                          height: 40,
                          child: ListView.separated(
                            controller: _hours,
                            scrollDirection: Axis.horizontal,
                            itemCount: 24,
                            separatorBuilder: (_, _) => const SizedBox(width: Gap.xs),
                            itemBuilder: (context, h) => FTChip(
                              label: formatClock(context, h, 0),
                              selected: h == prefs.notifyHour,
                              onTap: () => _update((p) => p.copyWith(notifyHour: h)),
                            ),
                          ),
                        ),
                        gap(Gap.sm),
                        Text(
                          'Your own reminders on the day use the time you set for them.',
                          style: t.caption,
                        ),
                      ],
                    ),
                  ),
                ),
                gap(Gap.lg),
                FTButton.secondary(
                  label: 'Send test notification',
                  icon: AppIcons.bellRinging,
                  expand: true,
                  loading: _busy,
                  onTap: _sendTest,
                ),
                gap(),
                SectionHeader(
                  'Coming up',
                  trailing: plan.isEmpty ? null : FTTag('${plan.length}'),
                  action: 'Calendar',
                  onAction: () => context.push(Routes.calendar),
                ),
                Text(
                  on
                      ? 'Scheduled for the next ${NotificationPlanner.horizonDays} days. The list refreshes whenever you open the app.'
                      : 'Preview – these will be scheduled once notifications are allowed.',
                  style: t.caption,
                ),
                gap(Gap.sm),
                if (calc == null)
                  const Padding(padding: EdgeInsets.all(Gap.lg), child: LoadingView())
                else if (plan.isEmpty)
                  FTCard(
                    child: Row(
                      children: [
                        const IconBadge(icon: AppIcons.calendarBlank, size: 40),
                        const SizedBox(width: Gap.md),
                        Expanded(
                          child: Text(
                            'Nothing to remind you about in the next ${NotificationPlanner.horizonDays} days. '
                            'Add birthdays with a day and month, or create a reminder in the calendar.',
                            style: t.body,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  for (var i = 0; i < plan.length && i < 8; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Gap.xs),
                      child: FadeSlideIn(
                        index: 3 + i,
                        child: Opacity(
                          opacity: on ? 1 : 0.6,
                          child: _PlannedRow(item: plan[i]),
                        ),
                      ),
                    ),
                if (plan.length > 8)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.xxs),
                    child: Text('and ${plan.length - 8} more', style: t.caption, textAlign: TextAlign.center),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlannedRow extends StatelessWidget {
  const _PlannedRow({required this.item});
  final PlannedNotification item;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final t = context.tx;
    final w = item.when;
    final when = '${DateFormat('EEE d MMM').format(w)} · ${formatClock(context, w.hour, w.minute)}';
    final lead = switch (item.leadDays) {
      0 => 'on the day',
      1 => '1 day before',
      final d => '$d days before',
    };
    return FTPill(
      padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
      semanticLabel: '${item.title}, $when, $lead',
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: c.chipGradient,
              border: Border.all(color: c.border),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('${w.day}', style: t.bodyStrong.copyWith(height: 1)),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(DateFormat('MMM').format(w).toUpperCase(),
                      style: t.micro.copyWith(fontSize: 8.5, height: 1.1)),
                ),
              ],
            ),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStrong),
                const SizedBox(height: 1),
                Text('$when · $lead', maxLines: 1, overflow: TextOverflow.ellipsis, style: t.caption),
              ],
            ),
          ),
          const SizedBox(width: Gap.xs),
          Icon(occasionIcon(item.occasion.kind), size: 18, color: c.text3),
        ],
      ),
    );
  }
}
