import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../app/providers.dart';
import '../services/system_ui.dart';
import '../widgets/widgets.dart';

/// Whether the app is currently locked behind the PIN / biometric screen.
final appLockProvider = NotifierProvider<AppLockController, bool>(AppLockController.new);

class AppLockController extends Notifier<bool> {
  DateTime? _backgroundedAt;
  final _auth = LocalAuthentication();

  @override
  bool build() => ref.read(settingsProvider).lockEnabled;

  bool get _enabled => ref.read(settingsProvider).lockEnabled;

  void onBackground() => _backgroundedAt ??= DateTime.now();

  void onForeground() {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    if (!_enabled || since == null || state) return;
    final secs = ref.read(settingsProvider).autoLockSeconds;
    if (secs < 0) return;
    if (DateTime.now().difference(since).inSeconds >= secs) state = true;
  }

  void lockNow() {
    if (_enabled) state = true;
  }

  Future<bool> unlockWithPin(String pin) async {
    final ok = await ref.read(vaultProvider).verifyPin(pin);
    if (ok) state = false;
    return ok;
  }

  Future<bool> biometricsAvailable() async {
    try {
      return await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  Future<bool> unlockWithBiometrics() async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock Family Tales',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
      if (ok) state = false;
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Verifies biometrics without changing lock state (used when enabling).
  Future<bool> confirmBiometrics(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, biometricOnly: true);
    } catch (_) {
      return false;
    }
  }

  void unlockForDisabled() => state = false;
}

/// Watches the app lifecycle to auto-lock, hide content from the app
/// switcher, apply the Android "secure recents" flag and keep the
/// full-screen preference in effect.
class AppLifecycleGuard extends ConsumerStatefulWidget {
  const AppLifecycleGuard({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AppLifecycleGuard> createState() => _AppLifecycleGuardState();
}

class _AppLifecycleGuardState extends ConsumerState<AppLifecycleGuard>
    with WidgetsBindingObserver {
  bool _obscured = false;
  static const _channel = MethodChannel('family_tales/privacy');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applySecure(ref.read(settingsProvider).hideInSwitcher);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _applySecure(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setSecureContent', {'enabled': enabled});
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final hide = ref.read(settingsProvider).hideInSwitcher;
    final lock = ref.read(appLockProvider.notifier);
    switch (s) {
      case AppLifecycleState.inactive:
        if (hide && !_obscured) setState(() => _obscured = true);
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (hide && !_obscured) setState(() => _obscured = true);
        lock.onBackground();
      case AppLifecycleState.resumed:
        lock.onForeground();
        applySystemUiMode(fullScreen: ref.read(settingsProvider).fullScreen);
        if (_obscured) setState(() => _obscured = false);
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(settingsProvider.select((s) => s.hideInSwitcher), (_, v) => _applySecure(v));
    ref.listen(settingsProvider.select((s) => s.fullScreen), (_, v) => applySystemUiMode(fullScreen: v));
    final locked = ref.watch(appLockProvider);
    return Stack(
      children: [
        widget.child,
        if (locked) const Positioned.fill(child: LockScreen()),
        if (_obscured && !locked) const Positioned.fill(child: _PrivacyCover()),
      ],
    );
  }
}

class _PrivacyCover extends StatelessWidget {
  const _PrivacyCover();

  @override
  Widget build(BuildContext context) {
    return FTBackground(
      child: Center(
        child: Image.asset('assets/branding/emblem.png', width: 120, height: 120),
      ),
    );
  }
}

/// Full-screen PIN pad with optional biometric unlock.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen>
    with SingleTickerProviderStateMixin {
  String _pin = '';
  String? _error;
  bool _busy = false;
  bool _bioAvailable = false;
  DateTime? _lockedUntil;
  Timer? _ticker;
  late final AnimationController _shake =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  static const pinLength = 4;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = ref.read(settingsProvider);
    final ctl = ref.read(appLockProvider.notifier);
    if (prefs.biometricEnabled && await ctl.biometricsAvailable()) {
      if (!mounted) return;
      setState(() => _bioAvailable = true);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (mounted) await ctl.unlockWithBiometrics();
    }
    final fails = await ref.read(vaultProvider).failedAttempts();
    if (fails >= 5) _startCooldown(fails);
  }

  void _startCooldown(int fails) {
    final secs = 30 * (fails ~/ 5);
    _lockedUntil = DateTime.now().add(Duration(seconds: secs));
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (DateTime.now().isAfter(_lockedUntil!)) {
        t.cancel();
        setState(() => _lockedUntil = null);
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _shake.dispose();
    super.dispose();
  }

  Future<void> _digit(String d) async {
    if (_busy || _lockedUntil != null || _pin.length >= pinLength) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == pinLength) {
      setState(() => _busy = true);
      final ok = await ref.read(appLockProvider.notifier).unlockWithPin(_pin);
      if (!mounted) return;
      if (!ok) {
        HapticFeedback.heavyImpact();
        _shake.forward(from: 0);
        final fails = await ref.read(vaultProvider).failedAttempts();
        setState(() {
          _pin = '';
          _busy = false;
          _error = 'Incorrect PIN';
        });
        if (fails > 0 && fails % 5 == 0) _startCooldown(fails);
      }
    }
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final remaining = _lockedUntil?.difference(DateTime.now()).inSeconds;
    return Material(
      color: Colors.transparent,
      child: FTBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/branding/emblem.png', width: 96, height: 96),
                    const SizedBox(height: Gap.lg),
                    Text('Family Tales is locked', style: context.tx.title, textAlign: TextAlign.center),
                    const SizedBox(height: Gap.xs),
                    Text(
                      remaining != null
                          ? 'Too many attempts. Try again in ${remaining}s.'
                          : (_error ?? 'Enter your PIN to continue'),
                      style: context.tx.body.copyWith(color: _error != null ? c.danger : null),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: Gap.xl),
                    AnimatedBuilder(
                      animation: _shake,
                      builder: (context, child) {
                        final t = _shake.value;
                        final dx = (t == 0 || t == 1) ? 0.0 : 10 * (1 - t) * (((t * 8).floor().isEven) ? 1 : -1);
                        return Transform.translate(offset: Offset(dx, 0), child: child);
                      },
                      child: Semantics(
                        label: '${_pin.length} of $pinLength digits entered',
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (var i = 0; i < pinLength; i++)
                              AnimatedContainer(
                                duration: Motion.fast,
                                margin: const EdgeInsets.symmetric(horizontal: 9),
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: i < _pin.length ? c.accent : Colors.transparent,
                                  border: Border.all(
                                      color: i < _pin.length ? c.accent : c.borderStrong, width: 1.5),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: Gap.xxl),
                    _Keypad(
                      onDigit: _digit,
                      onBackspace: _backspace,
                      onBiometric: _bioAvailable
                          ? () => ref.read(appLockProvider.notifier).unlockWithBiometrics()
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.onDigit, required this.onBackspace, this.onBiometric});
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback? onBiometric;

  @override
  Widget build(BuildContext context) {
    Widget key(String d) => _Key(label: d, onTap: () => onDigit(d));
    return Column(
      children: [
        for (final row in [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: row.map(key).toList(),
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            onBiometric != null
                ? FTIconButton(
                    icon: AppIcons.fingerprint,
                    tooltip: 'Unlock with biometrics',
                    size: 72,
                    onTap: onBiometric,
                  )
                : const SizedBox(width: 72, height: 72),
            key('0'),
            FTIconButton(
              icon: AppIcons.backspace,
              tooltip: 'Delete digit',
              size: 72,
              onTap: onBackspace,
            ),
          ],
        ),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      scale: 0.9,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: c.chipGradient,
          boxShadow: c.softShadow,
        ),
        foregroundDecoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: c.border),
        ),
        alignment: Alignment.center,
        child: Text(label, style: context.tx.title.copyWith(fontSize: 26, fontWeight: FontWeight.w400)),
      ),
    );
  }
}
