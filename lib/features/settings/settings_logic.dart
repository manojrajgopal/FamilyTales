import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/settings.dart';
import '../../core/database/app_database.dart';
import '../../core/repositories/system_repository.dart';
import '../../core/security/app_lock.dart';
import '../../core/security/secure_vault.dart';
import '../../core/services/app_paths.dart';

// ============================================================== providers

/// Sizes and counts for the Storage screen. Invalidate after maintenance.
final storageReportProvider = FutureProvider.autoDispose<StorageReport>(
    (ref) => ref.watch(systemRepoProvider).storageReport());

/// SQLite3MultipleCiphers cipher name, or null when the database is plain.
final cipherInfoProvider =
    FutureProvider.autoDispose<String?>((ref) => ref.watch(databaseProvider).cipherInfo());

/// Whether this device can use fingerprint / face unlock.
final biometricsAvailableProvider = FutureProvider.autoDispose<bool>(
    (ref) => ref.read(appLockProvider.notifier).biometricsAvailable());

// ============================================================ auto-lock

/// Auto-lock choices (seconds in the background; 0 = immediately,
/// -1 = never).
const autoLockOptions = <(int, String)>[
  (0, 'Immediately'),
  (30, 'After 30 seconds'),
  (60, 'After 1 minute'),
  (300, 'After 5 minutes'),
  (900, 'After 15 minutes'),
  (-1, 'Never'),
];

String autoLockLabel(int seconds) {
  for (final (s, label) in autoLockOptions) {
    if (s == seconds) return label;
  }
  if (seconds < 0) return 'Never';
  if (seconds < 60) return 'After $seconds seconds';
  return 'After ${(seconds / 60).round()} minutes';
}

/// Friendly theme-mode names (shared by the overview and Appearance).
String themeModeLabel(ThemeMode mode) => switch (mode) {
      ThemeMode.dark => 'Dark',
      ThemeMode.light => 'Light',
      ThemeMode.system => 'System default',
    };

// ============================================================== app lock

/// App-lock state transitions. Keeps the PIN (in the keystore) and the
/// preferences consistent.
class LockSettingsService {
  LockSettingsService({required this.vault, required this.settings, required this.lock});

  final SecureVault vault;
  final SettingsController settings;
  final AppLockController lock;

  /// Stores [pin] and turns the lock on.
  Future<void> enable(String pin) async {
    await vault.setPin(pin);
    await settings.update((p) => p.copyWith(lockEnabled: true));
  }

  Future<void> changePin(String pin) => vault.setPin(pin);

  /// Removes the PIN and turns the lock (and biometrics) off.
  Future<void> disable() async {
    await vault.clearPin();
    await settings.update((p) => p.copyWith(lockEnabled: false, biometricEnabled: false));
    lock.unlockForDisabled();
  }

  /// Asks the OS for a biometric check and enables biometric unlock when it
  /// succeeds. Returns whether it was enabled.
  Future<bool> enableBiometrics() async {
    final ok = await lock.confirmBiometrics('Confirm to unlock Family Tales with biometrics');
    if (ok) await settings.update((p) => p.copyWith(biometricEnabled: true));
    return ok;
  }

  Future<void> disableBiometrics() =>
      settings.update((p) => p.copyWith(biometricEnabled: false));
}

final lockSettingsProvider = Provider<LockSettingsService>((ref) => LockSettingsService(
      vault: ref.watch(vaultProvider),
      settings: ref.read(settingsProvider.notifier),
      lock: ref.read(appLockProvider.notifier),
    ));

// ======================================================== maintenance

/// Database / file maintenance used by the Storage and Trash screens.
class MaintenanceService {
  MaintenanceService({required this.db, required this.vault});

  final AppDatabase db;
  final SecureVault vault;

  /// Runs VACUUM and returns the number of bytes reclaimed (never negative).
  Future<int> optimise() async {
    final before = await _dbBytes();
    await db.vacuum();
    final after = await _dbBytes();
    return (before - after).clamp(0, before);
  }

  Future<int> _dbBytes() async {
    var total = 0;
    final f = AppPaths.I.databaseFile;
    for (final path in [f.path, '${f.path}-wal', '${f.path}-shm']) {
      try {
        total += await File(path).length();
      } catch (_) {}
    }
    return total;
  }

  /// Number of trash records older than [days] (they would be purged by a
  /// shorter retention period).
  Future<int> trashOlderThan(int days) async {
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final rows = await (db.select(db.deletionRecords)
          ..where((d) => d.deletedAt.isSmallerThanValue(cutoff)))
        .get();
    return rows.length;
  }

  /// Irreversibly erases every family record, preference, photo and the
  /// app PIN on this device. The (now empty) encrypted database stays open.
  Future<void> eraseEverything() async {
    final tables = db.allTables.toList().reversed.toList();
    await db.transaction(() async {
      // Children before parents (tables are declared parent-first), so the
      // foreign keys never block a delete.
      for (final t in tables) {
        await db.delete(t).go();
      }
    });
    try {
      // Reclaims the freed pages so deleted content does not linger on disk.
      await db.vacuum();
    } catch (_) {}

    final paths = AppPaths.I;
    if (await paths.mediaRoot.exists()) {
      await paths.mediaRoot.delete(recursive: true);
    }
    if (await paths.temp.exists()) {
      await for (final e in paths.temp.list(followLinks: false)) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    }
    await vault.clearPin();
  }
}

final maintenanceProvider = Provider<MaintenanceService>((ref) => MaintenanceService(
      db: ref.watch(databaseProvider),
      vault: ref.watch(vaultProvider),
    ));

/// Resets preferences to first-run defaults so the router returns to
/// onboarding.
Future<void> resetPreferences(WidgetRef ref) async {
  ref.read(appLockProvider.notifier).unlockForDisabled();
  await ref.read(settingsProvider.notifier).update((_) => const AppPrefs());
}
