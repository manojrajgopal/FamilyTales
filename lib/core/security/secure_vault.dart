import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Wrapper around the platform keystore (Android Keystore / iOS Keychain)
/// via flutter_secure_storage. Holds the database key and the app PIN hash.
class SecureVault {
  SecureVault([FlutterSecureStorage? storage])
      : _s = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _s;

  static const _dbKey = 'ft.db_key.v1';
  static const _pinHash = 'ft.pin.hash';
  static const _pinSalt = 'ft.pin.salt';
  static const _pinFails = 'ft.pin.fails';

  /// Returns the 256-bit database key, generating it on first use.
  Future<String> databaseKey() async {
    final existing = await _s.read(key: _dbKey);
    if (existing != null && existing.length >= 64) return existing;
    final key = randomHex(32);
    await _s.write(key: _dbKey, value: key);
    return key;
  }

  Future<bool> hasDatabaseKey() async => (await _s.read(key: _dbKey)) != null;

  Future<void> deleteDatabaseKey() => _s.delete(key: _dbKey);

  // ---------------------------------------------------------------- PIN

  Future<bool> hasPin() async => (await _s.read(key: _pinHash)) != null;

  Future<void> setPin(String pin) async {
    final salt = randomBytes(16);
    final hash = await _hash(pin, salt);
    await _s.write(key: _pinSalt, value: base64Encode(salt));
    await _s.write(key: _pinHash, value: base64Encode(hash));
    await _s.delete(key: _pinFails);
  }

  Future<void> clearPin() async {
    await _s.delete(key: _pinHash);
    await _s.delete(key: _pinSalt);
    await _s.delete(key: _pinFails);
  }

  Future<bool> verifyPin(String pin) async {
    final h = await _s.read(key: _pinHash);
    final s = await _s.read(key: _pinSalt);
    if (h == null || s == null) return false;
    final computed = await _hash(pin, base64Decode(s));
    final ok = _constantTimeEquals(computed, base64Decode(h));
    if (ok) {
      await _s.delete(key: _pinFails);
    } else {
      final fails = int.tryParse(await _s.read(key: _pinFails) ?? '0') ?? 0;
      await _s.write(key: _pinFails, value: '${fails + 1}');
    }
    return ok;
  }

  Future<int> failedAttempts() async =>
      int.tryParse(await _s.read(key: _pinFails) ?? '0') ?? 0;

  /// PBKDF2-HMAC-SHA256 (maintained `cryptography` package).
  static Future<List<int>> _hash(String pin, List<int> salt) async {
    final algo = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 120000, bits: 256);
    final key = await algo.deriveKeyFromPassword(password: pin, nonce: salt);
    return key.extractBytes();
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var r = 0;
    for (var i = 0; i < a.length; i++) {
      r |= a[i] ^ b[i];
    }
    return r == 0;
  }
}

final _rng = Random.secure();

List<int> randomBytes(int n) => List<int>.generate(n, (_) => _rng.nextInt(256));

String randomHex(int bytes) =>
    randomBytes(bytes).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
