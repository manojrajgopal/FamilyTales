/// Password protection for backup archives (`FTENC1` container).
///
/// Layout:
/// ```
/// "FTENC1"                       6 bytes magic
/// uint32 BE headerLength         4 bytes
/// header JSON (UTF-8)            {v, kdf, iterations, salt, cipher,
///                                 noncePrefix, chunkSize}
/// chunk*                         uint32 BE length + ciphertext + 16-byte tag
/// ```
///
/// * Key: PBKDF2-HMAC-SHA256(password, 16-byte random salt, ≥150 000
///   iterations) → 256-bit key.
/// * Each plaintext chunk (1 MiB, last one shorter) is sealed with
///   AES-256-GCM. Nonce = 8 random bytes + 4-byte big-endian chunk counter;
///   AAD = 4-byte big-endian counter + final-flag byte (1 for the last
///   chunk). Re-ordering, truncation or appending chunks therefore fails
///   authentication.
///
/// All primitives come from the maintained `cryptography` package; nothing
/// here implements cryptography by hand. Functions are synchronous-ish and
/// meant to run inside a background isolate.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'backup_format.dart';

const encryptionMagic = 'FTENC1';
const encryptionChunkSize = 1 << 20;
const defaultKdfIterations = 200000;
const minimumKdfIterations = 150000;
const _maxKdfIterations = 10000000;
const _tagLength = 16;

typedef CryptoProgress = void Function(double fraction);

/// Whether the file at [path] starts with the `FTENC1` magic.
bool isEncryptedBackup(String path) {
  final raf = File(path).openSync();
  try {
    final head = raf.readSync(encryptionMagic.length);
    return ascii.decode(head, allowInvalid: true) == encryptionMagic;
  } finally {
    raf.closeSync();
  }
}

Future<SecretKeyData> _deriveKey(
    String password, List<int> salt, int iterations) async {
  final kdf = DartPbkdf2(
    macAlgorithm: DartHmac.sha256(),
    iterations: iterations,
    bits: 256,
    pauseFrequency: 0, // runs in a background isolate
  );
  final key = await kdf.deriveKeyFromPassword(password: password, nonce: salt);
  return key.extract();
}

Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.big);

Uint8List _nonce(List<int> prefix, int counter) =>
    Uint8List.fromList([...prefix, ..._u32(counter)]);

Uint8List _aad(int counter, bool last) =>
    Uint8List.fromList([..._u32(counter), last ? 1 : 0]);

/// Encrypts [inPath] into [outPath].
Future<void> encryptBackupFile(
  String inPath,
  String outPath,
  String password, {
  int iterations = defaultKdfIterations,
  CryptoProgress? onProgress,
}) async {
  if (password.isEmpty) throw BackupException('Please choose a password.');
  final rnd = Random.secure();
  final salt = List<int>.generate(16, (_) => rnd.nextInt(256));
  final prefix = List<int>.generate(8, (_) => rnd.nextInt(256));
  final key = await _deriveKey(password, salt, iterations);
  final header = utf8.encode(jsonEncode({
    'v': 1,
    'kdf': 'pbkdf2-hmac-sha256',
    'iterations': iterations,
    'salt': base64Encode(salt),
    'cipher': 'aes-256-gcm',
    'noncePrefix': base64Encode(prefix),
    'chunkSize': encryptionChunkSize,
  }));
  final aes = DartAesGcm.with256bits();
  final input = File(inPath).openSync();
  final output = File(outPath).openSync(mode: FileMode.write);
  try {
    final total = input.lengthSync();
    output.writeFromSync(ascii.encode(encryptionMagic));
    output.writeFromSync(_u32(header.length));
    output.writeFromSync(header);
    final buf = Uint8List(encryptionChunkSize);
    var done = 0;
    var counter = 0;
    while (true) {
      final n = input.readIntoSync(buf);
      done += n;
      final last = done >= total;
      final box = aes.encryptSync(
        Uint8List.sublistView(buf, 0, n),
        secretKeyData: key,
        nonce: _nonce(prefix, counter),
        aad: _aad(counter, last),
      );
      output.writeFromSync(_u32(box.cipherText.length + _tagLength));
      output.writeFromSync(box.cipherText);
      output.writeFromSync(box.mac.bytes);
      counter++;
      onProgress?.call(total == 0 ? 1 : done / total);
      if (last) break;
    }
    output.flushSync();
  } finally {
    input.closeSync();
    output.closeSync();
  }
}

/// Decrypts [inPath] (an `FTENC1` file) into [outPath].
///
/// Throws [BackupWrongPassword] when the first chunk cannot be
/// authenticated and [BackupFormatException] for damaged / truncated files.
Future<void> decryptBackupFile(
  String inPath,
  String outPath,
  String password, {
  CryptoProgress? onProgress,
}) async {
  final input = File(inPath).openSync();
  RandomAccessFile? output;
  try {
    final total = input.lengthSync();
    final magic = input.readSync(encryptionMagic.length);
    if (ascii.decode(magic, allowInvalid: true) != encryptionMagic) {
      throw BackupFormatException('This file is not an encrypted backup.');
    }
    final lenBytes = input.readSync(4);
    if (lenBytes.length != 4) throw _damaged('The encryption header is incomplete.');
    final headerLen = ByteData.sublistView(lenBytes).getUint32(0, Endian.big);
    if (headerLen == 0 || headerLen > 64 * 1024) {
      throw _damaged('The encryption header has an invalid size.');
    }
    final headerBytes = input.readSync(headerLen);
    if (headerBytes.length != headerLen) {
      throw _damaged('The encryption header is incomplete.');
    }
    final Map<String, dynamic> header;
    try {
      header = jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw _damaged('The encryption header is unreadable.');
    }
    if (header['kdf'] != 'pbkdf2-hmac-sha256' || header['cipher'] != 'aes-256-gcm') {
      throw BackupFormatException(
          'This backup uses an encryption method this app does not support.',
          ['kdf: ${header['kdf']}, cipher: ${header['cipher']}']);
    }
    final iterations = (header['iterations'] as num?)?.toInt() ?? 0;
    final chunkSize = (header['chunkSize'] as num?)?.toInt() ?? encryptionChunkSize;
    List<int> salt, prefix;
    try {
      salt = base64Decode(header['salt'] as String);
      prefix = base64Decode(header['noncePrefix'] as String);
    } catch (_) {
      throw _damaged('The encryption header is unreadable.');
    }
    if (iterations < 1 || iterations > _maxKdfIterations || salt.length < 8 ||
        prefix.length != 8 || chunkSize < 1 || chunkSize > 64 * encryptionChunkSize) {
      throw _damaged('The encryption parameters are invalid.');
    }
    final key = await _deriveKey(password, salt, iterations);
    final aes = DartAesGcm.with256bits();
    output = File(outPath).openSync(mode: FileMode.write);
    var counter = 0;
    var sawLast = false;
    while (input.positionSync() < total) {
      final l = input.readSync(4);
      if (l.length != 4) throw _damaged('The file ends unexpectedly.');
      final len = ByteData.sublistView(l).getUint32(0, Endian.big);
      if (len < _tagLength || len > chunkSize + _tagLength) {
        throw _damaged('Block ${counter + 1} has an invalid size.');
      }
      final data = input.readSync(len);
      if (data.length != len) throw _damaged('The file ends unexpectedly.');
      final last = input.positionSync() >= total;
      final cipher = Uint8List.sublistView(data, 0, len - _tagLength);
      final tag = Uint8List.sublistView(data, len - _tagLength);
      List<int> clear;
      try {
        clear = aes.decryptSync(
          SecretBox(cipher, nonce: _nonce(prefix, counter), mac: Mac(tag)),
          secretKeyData: key,
          aad: _aad(counter, last),
        );
      } on SecretBoxAuthenticationError {
        if (counter == 0) throw BackupWrongPassword();
        throw _damaged(
            'Block ${counter + 1} failed its integrity check (the file was modified or truncated).');
      }
      output.writeFromSync(clear);
      counter++;
      onProgress?.call(total == 0 ? 1 : input.positionSync() / total);
      if (last) sawLast = true;
    }
    if (!sawLast) throw _damaged('The encrypted data is incomplete.');
    output.flushSync();
  } finally {
    input.closeSync();
    output?.closeSync();
  }
}

BackupFormatException _damaged(String detail) =>
    BackupFormatException('The backup file is damaged.', [detail]);

/// Rough password strength (0…4) used for the hint under the password field.
int passwordStrength(String p) {
  if (p.isEmpty) return 0;
  var score = 0;
  if (p.length >= 8) score++;
  if (p.length >= 12) score++;
  final classes = [
    RegExp(r'[a-z]'),
    RegExp(r'[A-Z]'),
    RegExp(r'[0-9]'),
    RegExp(r'[^A-Za-z0-9]'),
  ].where((r) => r.hasMatch(p)).length;
  if (classes >= 2) score++;
  if (classes >= 3 && p.length >= 10) score++;
  if (p.length >= 16 && classes >= 2) score = 4;
  if (p.length < 6) score = score > 1 ? 1 : score;
  return score.clamp(0, 4);
}

String passwordStrengthLabel(int s) => switch (s) {
      0 => 'Too short',
      1 => 'Weak',
      2 => 'Fair',
      3 => 'Good',
      _ => 'Strong',
    };
