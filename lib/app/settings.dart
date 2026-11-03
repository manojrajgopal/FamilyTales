import 'package:flutter/material.dart';

import '../features/family_tree/layout/tree_layout.dart';
import 'theme/tokens.dart';

/// Home dashboard sections (user can hide and reorder them).
enum DashboardSection {
  overview('Family overview'),
  quickActions('Quick actions'),
  recent('Recent additions'),
  upcoming('Upcoming family events'),
  memories('Recent memories');

  const DashboardSection(this.label);
  final String label;
}

/// Lead times for reminder notifications.
enum ReminderLead {
  sameDay('On the day', 0),
  dayBefore('1 day before', 1),
  weekBefore('1 week before', 7);

  const ReminderLead(this.label, this.days);
  final String label;
  final int days;
}

/// All user preferences. Persisted as key/value rows in `app_settings`;
/// secrets (PIN) live in the platform keystore instead.
@immutable
class AppPrefs {
  const AppPrefs({
    this.onboardingDone = false,
    this.activeTreeId,
    this.themeMode = ThemeMode.system,
    this.accent = AccentChoice.mint,
    this.textScale = 1.0,
    this.reduceMotion = false,
    this.fullScreen = true,
    this.showGender = true,
    this.dashboardOrder = DashboardSection.values,
    this.dashboardHidden = const {},
    this.notificationsEnabled = false,
    this.notifyBirthdays = true,
    this.notifyAnniversaries = true,
    this.notifyMemorials = false,
    this.notifyEvents = true,
    this.notifyCustom = true,
    this.reminderLeads = const {ReminderLead.sameDay},
    this.notifyHour = 9,
    this.lockEnabled = false,
    this.biometricEnabled = false,
    this.autoLockSeconds = 60,
    this.hideInSwitcher = false,
    this.encryptBackupsByDefault = true,
    this.treeMode = TreeViewMode.focus,
    this.treeGenerations = 3,
    this.trashRetentionDays = 30,
    this.lastBackupAt,
  });

  final bool onboardingDone;
  final String? activeTreeId;
  final ThemeMode themeMode;
  final AccentChoice accent;
  final double textScale;
  final bool reduceMotion;

  /// Hide the status and navigation bars (swipe from an edge to peek).
  final bool fullScreen;

  /// Colour-code people by gender (tree cards, avatars) with a symbol badge.
  final bool showGender;
  final List<DashboardSection> dashboardOrder;
  final Set<DashboardSection> dashboardHidden;
  final bool notificationsEnabled;
  final bool notifyBirthdays;
  final bool notifyAnniversaries;
  final bool notifyMemorials;
  final bool notifyEvents;
  final bool notifyCustom;
  final Set<ReminderLead> reminderLeads;
  final int notifyHour;
  final bool lockEnabled;
  final bool biometricEnabled;

  /// Lock after this many seconds in the background. 0 = immediately,
  /// -1 = never.
  final int autoLockSeconds;
  final bool hideInSwitcher;
  final bool encryptBackupsByDefault;
  final TreeViewMode treeMode;
  final int treeGenerations;
  final int trashRetentionDays;
  final DateTime? lastBackupAt;

  AppPrefs copyWith({
    bool? onboardingDone,
    String? activeTreeId,
    ThemeMode? themeMode,
    AccentChoice? accent,
    double? textScale,
    bool? reduceMotion,
    bool? fullScreen,
    bool? showGender,
    List<DashboardSection>? dashboardOrder,
    Set<DashboardSection>? dashboardHidden,
    bool? notificationsEnabled,
    bool? notifyBirthdays,
    bool? notifyAnniversaries,
    bool? notifyMemorials,
    bool? notifyEvents,
    bool? notifyCustom,
    Set<ReminderLead>? reminderLeads,
    int? notifyHour,
    bool? lockEnabled,
    bool? biometricEnabled,
    int? autoLockSeconds,
    bool? hideInSwitcher,
    bool? encryptBackupsByDefault,
    TreeViewMode? treeMode,
    int? treeGenerations,
    int? trashRetentionDays,
    DateTime? lastBackupAt,
  }) =>
      AppPrefs(
        onboardingDone: onboardingDone ?? this.onboardingDone,
        activeTreeId: activeTreeId ?? this.activeTreeId,
        themeMode: themeMode ?? this.themeMode,
        accent: accent ?? this.accent,
        textScale: textScale ?? this.textScale,
        reduceMotion: reduceMotion ?? this.reduceMotion,
        fullScreen: fullScreen ?? this.fullScreen,
        showGender: showGender ?? this.showGender,
        dashboardOrder: dashboardOrder ?? this.dashboardOrder,
        dashboardHidden: dashboardHidden ?? this.dashboardHidden,
        notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
        notifyBirthdays: notifyBirthdays ?? this.notifyBirthdays,
        notifyAnniversaries: notifyAnniversaries ?? this.notifyAnniversaries,
        notifyMemorials: notifyMemorials ?? this.notifyMemorials,
        notifyEvents: notifyEvents ?? this.notifyEvents,
        notifyCustom: notifyCustom ?? this.notifyCustom,
        reminderLeads: reminderLeads ?? this.reminderLeads,
        notifyHour: notifyHour ?? this.notifyHour,
        lockEnabled: lockEnabled ?? this.lockEnabled,
        biometricEnabled: biometricEnabled ?? this.biometricEnabled,
        autoLockSeconds: autoLockSeconds ?? this.autoLockSeconds,
        hideInSwitcher: hideInSwitcher ?? this.hideInSwitcher,
        encryptBackupsByDefault: encryptBackupsByDefault ?? this.encryptBackupsByDefault,
        treeMode: treeMode ?? this.treeMode,
        treeGenerations: treeGenerations ?? this.treeGenerations,
        trashRetentionDays: trashRetentionDays ?? this.trashRetentionDays,
        lastBackupAt: lastBackupAt ?? this.lastBackupAt,
      );

  Map<String, String> toMap() => {
        'onboardingDone': '$onboardingDone',
        'activeTreeId': ?activeTreeId,
        'themeMode': themeMode.name,
        'themeDefaultV2': 'true',
        'accent': accent.name,
        'textScale': '$textScale',
        'reduceMotion': '$reduceMotion',
        'fullScreen': '$fullScreen',
        'showGender': '$showGender',
        'dashboardOrder': dashboardOrder.map((e) => e.name).join(','),
        'dashboardHidden': dashboardHidden.map((e) => e.name).join(','),
        'notificationsEnabled': '$notificationsEnabled',
        'notifyBirthdays': '$notifyBirthdays',
        'notifyAnniversaries': '$notifyAnniversaries',
        'notifyMemorials': '$notifyMemorials',
        'notifyEvents': '$notifyEvents',
        'notifyCustom': '$notifyCustom',
        'reminderLeads': reminderLeads.map((e) => e.name).join(','),
        'notifyHour': '$notifyHour',
        'lockEnabled': '$lockEnabled',
        'biometricEnabled': '$biometricEnabled',
        'autoLockSeconds': '$autoLockSeconds',
        'hideInSwitcher': '$hideInSwitcher',
        'encryptBackupsByDefault': '$encryptBackupsByDefault',
        'treeMode': treeMode.name,
        'treeGenerations': '$treeGenerations',
        'trashRetentionDays': '$trashRetentionDays',
        if (lastBackupAt != null) 'lastBackupAt': lastBackupAt!.toIso8601String(),
      };

  factory AppPrefs.fromMap(Map<String, String> m) {
    bool b(String k, bool d) => switch (m[k]) { 'true' => true, 'false' => false, _ => d };
    T e<T extends Enum>(List<T> values, String k, T d) =>
        values.firstWhere((v) => v.name == m[k], orElse: () => d);
    List<T> list<T extends Enum>(List<T> values, String k, List<T> d) {
      final raw = m[k];
      if (raw == null) return d;
      if (raw.isEmpty) return [];
      return raw
          .split(',')
          .map((n) => values.where((v) => v.name == n).firstOrNull)
          .whereType<T>()
          .toList();
    }

    var order = list(DashboardSection.values, 'dashboardOrder', DashboardSection.values);
    for (final s in DashboardSection.values) {
      if (!order.contains(s)) order = [...order, s];
    }
    return AppPrefs(
      onboardingDone: b('onboardingDone', false),
      activeTreeId: m['activeTreeId'],
      // Earlier builds stored "dark" as the default for everyone; until the
      // user picks a theme again, follow the system appearance instead.
      themeMode: m['themeDefaultV2'] == null ? ThemeMode.system : e(ThemeMode.values, 'themeMode', ThemeMode.system),
      accent: e(AccentChoice.values, 'accent', AccentChoice.mint),
      textScale: double.tryParse(m['textScale'] ?? '') ?? 1.0,
      reduceMotion: b('reduceMotion', false),
      fullScreen: b('fullScreen', true),
      showGender: b('showGender', true),
      dashboardOrder: order,
      dashboardHidden: list(DashboardSection.values, 'dashboardHidden', const <DashboardSection>[]).toSet(),
      notificationsEnabled: b('notificationsEnabled', false),
      notifyBirthdays: b('notifyBirthdays', true),
      notifyAnniversaries: b('notifyAnniversaries', true),
      notifyMemorials: b('notifyMemorials', false),
      notifyEvents: b('notifyEvents', true),
      notifyCustom: b('notifyCustom', true),
      reminderLeads: list(ReminderLead.values, 'reminderLeads', const [ReminderLead.sameDay]).toSet(),
      notifyHour: int.tryParse(m['notifyHour'] ?? '') ?? 9,
      lockEnabled: b('lockEnabled', false),
      biometricEnabled: b('biometricEnabled', false),
      autoLockSeconds: int.tryParse(m['autoLockSeconds'] ?? '') ?? 60,
      hideInSwitcher: b('hideInSwitcher', false),
      encryptBackupsByDefault: b('encryptBackupsByDefault', true),
      treeMode: e(TreeViewMode.values, 'treeMode', TreeViewMode.focus),
      treeGenerations: int.tryParse(m['treeGenerations'] ?? '') ?? 3,
      trashRetentionDays: int.tryParse(m['trashRetentionDays'] ?? '') ?? 30,
      lastBackupAt: DateTime.tryParse(m['lastBackupAt'] ?? ''),
    );
  }
}
