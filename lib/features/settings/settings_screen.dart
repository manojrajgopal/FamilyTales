import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/widgets/widgets.dart';
import 'app_info.dart';
import 'settings_logic.dart';
import 'widgets/settings_widgets.dart';

/// Settings overview: grouped cards with the current value of each area.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(settingsProvider);
    final trees = ref.watch(treesProvider).value ?? const [];
    final activeTree = ref.watch(activeTreeProvider);
    final trash = ref.watch(trashProvider).value?.length ?? 0;

    void go(String route) => context.push(route);

    final shown = prefs.dashboardOrder.where((s) => !prefs.dashboardHidden.contains(s)).length;
    final total = prefs.dashboardOrder.length;
    final lastBackup = prefs.lastBackupAt;

    final appearance = [
      themeModeLabel(prefs.themeMode),
      prefs.accent.label,
      'Text ${(prefs.textScale * 100).round()}%',
      if (prefs.reduceMotion) 'Reduced motion',
    ].join(' · ');

    final security = prefs.lockEnabled
        ? [
            'App lock on',
            if (prefs.biometricEnabled) 'Biometrics',
            'Auto-lock: ${autoLockLabel(prefs.autoLockSeconds).toLowerCase()}',
          ].join(' · ')
        : 'App lock off · Data encrypted on this device';

    final notifications = prefs.notificationsEnabled
        ? 'On · Reminders at ${_hourLabel(context, prefs.notifyHour)}'
        : 'Off';

    final treesLabel = trees.isEmpty
        ? 'No trees yet'
        : '${plural(trees.length, 'tree')}${activeTree == null ? '' : ' · Viewing ${activeTree.name}'}';

    return FTPage(
      title: 'Settings',
      body: SettingsBody(
        children: [
          SettingsGroup(
            title: 'Personalise',
            children: [
              FTListRow(
                icon: AppIcons.palette,
                title: 'Appearance',
                subtitle: appearance,
                onTap: () => go(Routes.appearance),
              ),
              FTListRow(
                icon: AppIcons.layout,
                title: 'Home layout',
                subtitle: shown == total
                    ? 'All $total sections shown'
                    : '$shown of $total sections shown',
                onTap: () => go(Routes.dashboardSettings),
              ),
              FTListRow(
                icon: AppIcons.bell,
                title: 'Notifications',
                subtitle: notifications,
                onTap: () => go(Routes.notifications),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Privacy & security',
            children: [
              FTListRow(
                icon: AppIcons.shield,
                title: 'App lock & privacy',
                subtitle: security,
                onTap: () => go(Routes.security),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Family trees',
            children: [
              FTListRow(
                icon: AppIcons.tree,
                title: 'Manage family trees',
                subtitle: treesLabel,
                onTap: () => go(Routes.trees),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Data management',
            children: [
              FTListRow(
                icon: AppIcons.backup,
                title: 'Backup & restore',
                subtitle: lastBackup == null
                    ? 'No backup yet – create one to keep your tree safe'
                    : 'Last backup ${DateFormat.yMMMd().format(lastBackup)}',
                onTap: () => go(Routes.backup),
              ),
              FTListRow(
                icon: AppIcons.download,
                title: 'Import GEDCOM',
                subtitle: 'Bring in a tree from another genealogy app',
                onTap: () => go(Routes.gedcomImport),
              ),
              FTListRow(
                icon: AppIcons.export,
                title: 'Export',
                subtitle: 'GEDCOM, PDF and printable charts',
                onTap: () => go(Routes.export),
              ),
              FTListRow(
                icon: AppIcons.storage,
                title: 'Storage',
                subtitle: 'Space used, clean-up and maintenance',
                onTap: () => go(Routes.storage),
              ),
              FTListRow(
                icon: AppIcons.trash,
                title: 'Trash',
                subtitle: trash == 0
                    ? 'Empty · Items are kept for ${prefs.trashRetentionDays} days'
                    : '${plural(trash, 'item')} · Kept for ${prefs.trashRetentionDays} days',
                onTap: () => go(Routes.trash),
              ),
              FTListRow(
                icon: AppIcons.fields,
                title: 'Custom fields',
                subtitle: 'Extra details to record for each person',
                onTap: () => go(Routes.customFields),
              ),
              FTListRow(
                icon: AppIcons.duplicate,
                title: 'Find duplicates',
                subtitle: 'Spot and merge people entered twice',
                onTap: () => go(Routes.duplicates),
              ),
            ],
          ),
          SettingsGroup(
            title: 'About',
            children: [
              FTListRow(
                icon: AppIcons.info,
                title: 'About Family Tales',
                subtitle: 'Version ${AppInfo.shortVersion} · Licenses & privacy',
                onTap: () => go(Routes.about),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _hourLabel(BuildContext context, int hour) {
    final h = hour.clamp(0, 23);
    return MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay(hour: h, minute: 0),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }
}
