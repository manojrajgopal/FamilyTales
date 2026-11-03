import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/settings.dart';
import '../../core/repositories/family_repository.dart';
import '../../core/security/app_lock.dart';
import '../../core/widgets/widgets.dart';
import 'settings_logic.dart';
import 'widgets/pin_sheet.dart';
import 'widgets/settings_widgets.dart';

/// App lock (PIN + biometrics), auto-lock, app-switcher privacy, backup
/// encryption default and an explanation of how data is protected.
class SecuritySettingsScreen extends ConsumerStatefulWidget {
  const SecuritySettingsScreen({super.key});

  @override
  ConsumerState<SecuritySettingsScreen> createState() => _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState extends ConsumerState<SecuritySettingsScreen> {
  bool _busy = false;

  LockSettingsService get _lock => ref.read(lockSettingsProvider);

  /// Runs [action] once at a time and turns failures into friendly toasts.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on ValidationException catch (e) {
      if (mounted) showFTToast(context, e.message, error: true);
    } catch (e) {
      if (mounted) showFTToast(context, 'Something went wrong. ${friendlyError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _update(AppPrefs Function(AppPrefs p) change) =>
      _run(() => ref.read(settingsProvider.notifier).update(change));

  // ---------------------------------------------------------------- flows

  Future<void> _enableLock() => _run(() async {
        final pin = await showCreatePinSheet(context);
        if (pin == null || !mounted) return;
        await _lock.enable(pin);
        if (!mounted) return;
        showFTToast(context, 'App lock is on');
        final bio = await ref.read(biometricsAvailableProvider.future);
        if (!bio || !mounted) return;
        final offer = await showFTConfirm(
          context,
          title: 'Unlock with biometrics too?',
          message: 'Use your fingerprint or face to open Family Tales. Your PIN still works as a backup.',
          confirmLabel: 'Use biometrics',
          cancelLabel: 'Not now',
          icon: AppIcons.fingerprint,
        );
        if (!offer || !mounted) return;
        final ok = await _lock.enableBiometrics();
        if (mounted && !ok) {
          showFTToast(context, 'Biometric check didn’t complete, so it stays off.', error: true);
        }
      });

  Future<void> _disableLock() => _run(() async {
        final vault = ref.read(vaultProvider);
        if (await vault.hasPin()) {
          if (!mounted) return;
          final ok = await showVerifyPinSheet(
            context,
            vault: vault,
            title: 'Turn off app lock',
            message: 'Enter your PIN to turn off app lock.',
          );
          if (!ok) return;
        }
        await _lock.disable();
        if (mounted) showFTToast(context, 'App lock is off');
      });

  Future<void> _changePin() => _run(() async {
        final vault = ref.read(vaultProvider);
        final ok = await showVerifyPinSheet(
          context,
          vault: vault,
          title: 'Change PIN',
          message: 'First, enter your current PIN.',
        );
        if (!ok || !mounted) return;
        final pin = await showCreatePinSheet(
          context,
          title: 'New PIN',
          message: 'Choose a new 4-digit PIN.',
        );
        if (pin == null) return;
        await _lock.changePin(pin);
        if (mounted) showFTToast(context, 'PIN changed');
      });

  Future<void> _toggleBiometrics(bool enable) => _run(() async {
        if (!enable) {
          await _lock.disableBiometrics();
          return;
        }
        if (!ref.read(settingsProvider).lockEnabled) {
          if (mounted) showFTToast(context, 'Turn on app lock first.', error: true);
          return;
        }
        final ok = await _lock.enableBiometrics();
        if (!mounted) return;
        showFTToast(
          context,
          ok ? 'Biometric unlock is on' : 'Biometric check didn’t complete, so it stays off.',
          error: !ok,
        );
      });

  Future<void> _pickAutoLock(int current) async {
    final v = await showFTOptions<int>(
      context,
      title: 'Auto-lock',
      options: [
        for (final (secs, label) in autoLockOptions)
          FTOption(
            secs,
            label,
            selected: secs == current,
            subtitle: switch (secs) {
              0 => 'Lock as soon as you leave the app',
              -1 => 'Only lock when you choose “Lock now”',
              _ => null,
            },
          ),
      ],
    );
    if (v == null || v == current) return;
    await _update((p) => p.copyWith(autoLockSeconds: v));
  }

  void _lockNow() {
    if (!ref.read(settingsProvider).lockEnabled) return;
    ref.read(appLockProvider.notifier).lockNow();
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(settingsProvider);
    final bioAvailable = ref.watch(biometricsAvailableProvider).value ?? false;
    final cipher = ref.watch(cipherInfoProvider);
    final lockOn = prefs.lockEnabled;

    return FTPage(
      title: 'Privacy & security',
      body: SettingsBody(
        children: [
          _StatusCard(lockOn: lockOn, encrypted: cipher.value != null),
          SettingsGroup(
            title: 'App lock',
            children: [
              FTSwitchRow(
                icon: AppIcons.lock,
                title: 'App lock',
                subtitle: lockOn
                    ? 'A PIN is needed to open Family Tales'
                    : 'Protect the app with a 4-digit PIN',
                value: lockOn,
                onChanged: _busy ? null : (v) => v ? _enableLock() : _disableLock(),
              ),
              if (lockOn)
                FTListRow(
                  icon: AppIcons.key,
                  title: 'Change PIN',
                  subtitle: 'You’ll confirm your current PIN first',
                  onTap: _busy ? null : _changePin,
                ),
              if (bioAvailable)
                FTSwitchRow(
                  icon: AppIcons.fingerprint,
                  title: 'Unlock with biometrics',
                  subtitle: lockOn
                      ? 'Use your fingerprint or face instead of the PIN'
                      : 'Turn on app lock to use biometrics',
                  value: lockOn && prefs.biometricEnabled,
                  onChanged: lockOn && !_busy ? _toggleBiometrics : null,
                ),
              if (lockOn)
                FTListRow(
                  icon: AppIcons.clock,
                  title: 'Auto-lock',
                  subtitle: autoLockLabel(prefs.autoLockSeconds),
                  onTap: () => _pickAutoLock(prefs.autoLockSeconds),
                ),
              if (lockOn)
                FTListRow(
                  icon: AppIcons.lock,
                  title: 'Lock now',
                  subtitle: 'Lock Family Tales immediately',
                  onTap: _lockNow,
                ),
            ],
          ),
          SettingsGroup(
            title: 'Privacy',
            children: [
              FTSwitchRow(
                icon: AppIcons.eyeOff,
                title: 'Hide content in app switcher',
                subtitle: Platform.isAndroid
                    ? 'Shows a blank preview in recent apps and blocks screenshots'
                    : 'Shows a blank preview in the app switcher',
                value: prefs.hideInSwitcher,
                onChanged: (v) => _update((p) => p.copyWith(hideInSwitcher: v)),
              ),
              FTSwitchRow(
                icon: AppIcons.archive,
                title: 'Encrypt backups by default',
                subtitle: 'New backups are protected with a password you choose',
                value: prefs.encryptBackupsByDefault,
                onChanged: (v) => _update((p) => p.copyWith(encryptBackupsByDefault: v)),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Encryption',
            children: [_EncryptionRow(cipher: cipher)],
          ),
          const InfoCard(
            icon: AppIcons.handHeart,
            title: 'Your data stays with you',
            message: 'Family Tales works completely offline.',
            child: BulletPoints([
              'No account or sign-in – there is nothing to register.',
              'No server and no cloud uploads – your tree lives only on this device.',
              'No analytics, ads or tracking of any kind.',
              'Your data leaves this device only when you export, back up or share it yourself.',
            ]),
          ),
        ],
      ),
    );
  }
}

/// Summary at the top: shield badge with the overall protection level.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.lockOn, required this.encrypted});
  final bool lockOn;
  final bool encrypted;

  @override
  Widget build(BuildContext context) {
    final strong = lockOn && encrypted;
    return FTCard(
      highlighted: strong,
      child: Row(
        children: [
          IconBadge(icon: AppIcons.shield, size: 52, accent: strong),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  strong
                      ? 'Well protected'
                      : (lockOn ? 'App lock is on' : 'Add an app lock'),
                  style: context.tx.title,
                ),
                const SizedBox(height: 2),
                Text(
                  lockOn
                      ? 'Your family data is locked behind your PIN${encrypted ? ' and encrypted on this device' : ''}.'
                      : 'Anyone holding your unlocked phone can open Family Tales. Turn on app lock to require a PIN.',
                  style: context.tx.body,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EncryptionRow extends StatelessWidget {
  const _EncryptionRow({required this.cipher});
  final AsyncValue<String?> cipher;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final loading = cipher.isLoading && !cipher.hasValue;
    final on = cipher.value != null;
    final title = loading
        ? 'Checking encryption…'
        : (on ? 'Database encrypted' : 'Standard private storage');
    final subtitle = loading
        ? 'One moment'
        : (on
            ? 'Encrypted at rest (SQLCipher-compatible, key in device keystore)'
            : 'Stored in this app’s private storage, which other apps can’t read. '
                'Full database encryption isn’t active on this build.');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconBadge(
            icon: on ? AppIcons.lock : AppIcons.database,
            size: 40,
            accent: on,
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: context.tx.bodyStrong),
                const SizedBox(height: 2),
                Text(subtitle, style: context.tx.caption),
              ],
            ),
          ),
          if (loading) ...[
            const SizedBox(width: Gap.sm),
            const RowSpinner(),
          ] else if (on) ...[
            const SizedBox(width: Gap.sm),
            Icon(AppIcons.checkCircle, size: 20, color: c.accent),
          ],
        ],
      ),
    );
  }
}
