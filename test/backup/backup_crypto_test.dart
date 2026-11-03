import 'dart:io';
import 'dart:typed_data';

import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/services/app_paths.dart';
import 'package:family_tales/features/backup/backup_crypto.dart';
import 'package:family_tales/features/backup/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'seed.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ft_crypto_test');
    AppPaths.initForTest(tmp);
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('stream encryption round trip across several chunks', () async {
    final plain = File(p.join(tmp.path, 'plain.bin'))
      ..writeAsBytesSync(Uint8List.fromList(
          List.generate(encryptionChunkSize * 2 + 12345, (i) => (i * 31) % 256)));
    final enc = p.join(tmp.path, 'x.enc');
    final dec = p.join(tmp.path, 'x.dec');
    await encryptBackupFile(plain.path, enc, 'correct horse battery');
    expect(isEncryptedBackup(enc), isTrue);
    final raw = File(enc).readAsBytesSync();
    expect(String.fromCharCodes(raw.sublist(0, 6)), 'FTENC1');
    await decryptBackupFile(enc, dec, 'correct horse battery');
    expect(File(dec).readAsBytesSync(), plain.readAsBytesSync());

    // Wrong password.
    await expectLater(decryptBackupFile(enc, dec, 'wrong password'),
        throwsA(isA<BackupWrongPassword>()));

    // Tampering with a later chunk.
    final tampered = Uint8List.fromList(raw);
    tampered[tampered.length - 100] ^= 0x01;
    final tPath = p.join(tmp.path, 't.enc');
    File(tPath).writeAsBytesSync(tampered);
    await expectLater(decryptBackupFile(tPath, dec, 'correct horse battery'),
        throwsA(isA<BackupFormatException>()));

    // Truncation (drop the final chunk).
    final firstChunkEnd = raw.length - (12345 + 16 + 4);
    final trunc = p.join(tmp.path, 'trunc.enc');
    File(trunc).writeAsBytesSync(raw.sublist(0, firstChunkEnd));
    await expectLater(decryptBackupFile(trunc, dec, 'correct horse battery'),
        throwsA(isA<BackupFormatException>()));
  });

  test('encrypted backup requires the right password to restore', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final seed = await seedTree(db);
    final service = BackupService(db);
    final res = await service.createBackup(
      BackupRequest(treeIds: [seed.treeId], password: 's3cret-Password'),
      outDir: p.join(tmp.path, 'out'),
    );
    expect(res.encrypted, isTrue);
    expect(isEncryptedBackup(res.path), isTrue);

    await expectLater(service.inspect(res.path), throwsA(isA<BackupPasswordRequired>()));
    await expectLater(service.inspect(res.path, password: 'nope-nope'),
        throwsA(isA<BackupWrongPassword>()));

    final insp = await service.inspect(res.path, password: 's3cret-Password');
    expect(insp.encrypted, isTrue);
    expect(insp.counts.people, 3);
    final r = await service.restore(insp, RestoreRequest.asNew(treeIds: [seed.treeId]));
    await insp.dispose();
    final people = await (db.select(db.persons)..where((x) => x.treeId.equals(r.treeIds.single))).get();
    expect(people, hasLength(3));
  });

  test('password strength hint', () {
    expect(passwordStrength(''), 0);
    expect(passwordStrength('abc'), lessThanOrEqualTo(1));
    expect(passwordStrength('Tr0ub4dor&3xyz'), greaterThanOrEqualTo(3));
  });
}
