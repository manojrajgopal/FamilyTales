import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../models/enums.dart';
import 'tables.dart';

export 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [
  FamilyTrees,
  Persons,
  ParentChildLinks,
  Partnerships,
  FamilyBranches,
  PersonBranches,
  FamilyEvents,
  EventPersons,
  MediaAssets,
  MediaPersons,
  MediaEvents,
  Albums,
  AlbumMedia,
  Stories,
  StoryPersons,
  StoryEvents,
  StoryMedia,
  Sources,
  Citations,
  CustomFields,
  PersonCustomValues,
  Reminders,
  Tags,
  PersonTags,
  StoryTags,
  DeletionRecords,
  BackupRecords,
  AppSettings,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// In-memory database for tests.
  AppDatabase.memory() : super(NativeDatabase.memory(setup: _pragmas));

  /// Opens (or creates) the on-device database at [file].
  ///
  /// When [key] is given the file is encrypted with SQLite3MultipleCiphers
  /// using the SQLCipher v4 compatible scheme. The key is a random 256-bit
  /// secret kept in the platform keystore (see `DatabaseKeyStore`).
  factory AppDatabase.open(File file, {String? key}) {
    return AppDatabase(NativeDatabase.createInBackground(
      file,
      setup: (raw) {
        if (key != null) {
          raw.execute("PRAGMA cipher = 'sqlcipher'");
          raw.execute('PRAGMA legacy = 4');
          raw.execute("PRAGMA key = '$key'");
          // Fails fast with "file is not a database" when the key is wrong.
          raw.select('SELECT count(*) FROM sqlite_master');
        }
        _pragmas(raw);
      },
    ));
  }

  static void _pragmas(dynamic raw) {
    raw.execute('PRAGMA foreign_keys = ON');
    raw.execute('PRAGMA journal_mode = WAL');
    raw.execute('PRAGMA synchronous = NORMAL');
  }

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // Future schema versions add their steps here, e.g.
          // if (from < 2) await m.addColumn(persons, persons.someColumn);
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  /// Reports whether SQLite3MultipleCiphers is active for this connection.
  Future<String?> cipherInfo() async {
    try {
      final rows = await customSelect('PRAGMA cipher').get();
      if (rows.isEmpty) return null;
      return rows.first.data.values.first?.toString();
    } catch (_) {
      return null;
    }
  }

  Future<void> vacuum() => customStatement('VACUUM');

  Future<int> integrityCheckErrors() async {
    final rows = await customSelect('PRAGMA integrity_check').get();
    return rows
        .where((r) => r.data.values.first?.toString().toLowerCase() != 'ok')
        .length;
  }
}
