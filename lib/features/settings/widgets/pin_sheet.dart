import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/security/secure_vault.dart';
import '../../../core/widgets/widgets.dart';

/// Length of the app-lock PIN (matches the lock screen).
const kPinLength = 4;

/// Whether [pin] is too easy to guess: one repeated digit or a straight run
/// such as 1234 / 9876.
bool isWeakPin(String pin) {
  if (pin.length != kPinLength) return true;
  if (pin.split('').toSet().length == 1) return true;
  const up = '0123456789';
  const down = '9876543210';
  return up.contains(pin) || down.contains(pin);
}

/// Asks for a new PIN twice. Returns the confirmed PIN, or null if the
/// sheet was dismissed.
Future<String?> showCreatePinSheet(
  BuildContext context, {
  String title = 'Create a PIN',
  String message = 'Choose a 4-digit PIN. You’ll enter it whenever Family Tales is locked.',
}) {
  return showFTSheet<String>(
    context,
    title: title,
    builder: (_) => _PinSheet(mode: _PinMode.create, message: message),
  );
}

/// Asks for the current PIN and checks it against [vault]. Returns true only
/// when the PIN was correct.
Future<bool> showVerifyPinSheet(
  BuildContext context, {
  required SecureVault vault,
  String title = 'Enter your PIN',
  String message = 'Enter your current PIN to continue.',
}) async {
  final ok = await showFTSheet<bool>(
    context,
    title: title,
    builder: (_) => _PinSheet(mode: _PinMode.verify, message: message, vault: vault),
  );
  return ok ?? false;
}

enum _PinMode { create, verify }

class _PinSheet extends StatefulWidget {
  const _PinSheet({required this.mode, required this.message, this.vault});
  final _PinMode mode;
  final String message;
  final SecureVault? vault;

  @override
  State<_PinSheet> createState() => _PinSheetState();
}

class _PinSheetState extends State<_PinSheet> with SingleTickerProviderStateMixin {
  String _pin = '';
  String? _first;
  String? _error;
  bool _busy = false;
  DateTime? _lockedUntil;
  Timer? _ticker;
  late final AnimationController _shake =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  @override
  void initState() {
    super.initState();
    if (widget.mode == _PinMode.verify) _checkCooldown();
  }

  Future<void> _checkCooldown() async {
    final fails = await widget.vault!.failedAttempts();
    if (mounted && fails >= 5) _startCooldown(fails);
  }

  void _startCooldown(int fails) {
    final secs = 30 * (fails ~/ 5);
    setState(() => _lockedUntil = DateTime.now().add(Duration(seconds: secs)));
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
    if (_busy || _lockedUntil != null || _pin.length >= kPinLength) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length < kPinLength) return;
    if (widget.mode == _PinMode.create) {
      await _completeCreate();
    } else {
      await _completeVerify();
    }
  }

  Future<void> _completeCreate() async {
    final pin = _pin;
    setState(() => _busy = true);
    // Let the last dot fill before moving on.
    await Future<void>.delayed(const Duration(milliseconds: 140));
    if (!mounted) return;
    if (_first == null) {
      if (isWeakPin(pin)) {
        _fail('That PIN is easy to guess. Try a less obvious one.');
        return;
      }
      setState(() {
        _first = pin;
        _pin = '';
        _busy = false;
      });
      return;
    }
    if (pin != _first) {
      _fail('The PINs didn’t match. Please start again.', resetFirst: true);
      return;
    }
    Navigator.of(context).pop(pin);
  }

  Future<void> _completeVerify() async {
    setState(() => _busy = true);
    final vault = widget.vault!;
    final ok = await vault.verifyPin(_pin);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    final fails = await vault.failedAttempts();
    if (!mounted) return;
    _fail('Incorrect PIN');
    if (fails > 0 && fails % 5 == 0) _startCooldown(fails);
  }

  void _fail(String message, {bool resetFirst = false}) {
    HapticFeedback.heavyImpact();
    if (!context.reduceMotion) _shake.forward(from: 0);
    setState(() {
      _pin = '';
      _busy = false;
      _error = message;
      if (resetFirst) _first = null;
    });
  }

  void _backspace() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final remaining = _lockedUntil?.difference(DateTime.now()).inSeconds;
    final prompt = switch (widget.mode) {
      _PinMode.create => _first == null ? 'Enter a new PIN' : 'Enter it again to confirm',
      _PinMode.verify => 'Current PIN',
    };
    final status = remaining != null
        ? 'Too many attempts. Try again in ${remaining}s.'
        : _error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.message, style: context.tx.body, textAlign: TextAlign.center),
        const SizedBox(height: Gap.lg),
        AnimatedSwitcher(
          duration: context.reduceMotion ? Duration.zero : Motion.fast,
          child: Text(prompt,
              key: ValueKey(prompt),
              style: context.tx.section,
              textAlign: TextAlign.center),
        ),
        const SizedBox(height: Gap.md),
        AnimatedBuilder(
          animation: _shake,
          builder: (context, child) {
            final t = _shake.value;
            final dx = (t == 0 || t == 1)
                ? 0.0
                : 10 * (1 - t) * (((t * 8).floor().isEven) ? 1 : -1);
            return Transform.translate(offset: Offset(dx, 0), child: child);
          },
          child: Semantics(
            label: '${_pin.length} of $kPinLength digits entered',
            liveRegion: true,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < kPinLength; i++)
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
        const SizedBox(height: Gap.sm),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Center(
            child: Text(
              status ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: context.tx.caption.copyWith(color: c.danger),
            ),
          ),
        ),
        const SizedBox(height: Gap.xs),
        PinKeypad(
          onDigit: _digit,
          onBackspace: _backspace,
          enabled: !_busy && remaining == null,
        ),
      ],
    );
  }
}

/// Circular graphite number pad (same look as the lock screen).
class PinKeypad extends StatelessWidget {
  const PinKeypad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    this.enabled = true,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: LayoutBuilder(builder: (context, cons) {
          final size = ((cons.maxWidth - 2 * Gap.lg) / 3).clamp(56.0, 72.0);
          Widget key(String d) =>
              _PinKey(label: d, size: size, onTap: enabled ? () => onDigit(d) : null);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final row in const [
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
                  SizedBox(width: size, height: size),
                  key('0'),
                  SizedBox(
                    width: size,
                    height: size,
                    child: FTIconButton(
                      icon: AppIcons.backspace,
                      tooltip: 'Delete digit',
                      size: size,
                      onTap: enabled ? onBackspace : null,
                    ),
                  ),
                ],
              ),
            ],
          );
        }),
      ),
    );
  }
}

class _PinKey extends StatelessWidget {
  const _PinKey({required this.label, required this.size, required this.onTap});
  final String label;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      scale: 0.9,
      child: Container(
        width: size,
        height: size,
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
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(label,
              style: context.tx.title.copyWith(fontSize: 26, fontWeight: FontWeight.w400)),
        ),
      ),
    );
  }
}
