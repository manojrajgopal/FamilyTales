/// The `.ftbackup` archive format: table registry, manifest model, id
/// sanitising / remapping and the errors raised while reading archives.
///
/// Everything here is pure Dart (no Flutter, no database connection) so it
/// can run inside background isolates and unit tests.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/database/app_database.dart';

/// Identifier written to `manifest.json` → `format`.
const backupFormatId = 'family-tales-backup';

/// Bumped whenever the archive layout changes incompatibly.
const backupFormatVersion = 1;

/// App version recorded in new backups.
const backupAppVersion = '1.0.0';

/// File extension of backup archives (without dot).
const backupFileExtension = 'ftbackup';

/// Name of the table-data entry inside the archive.
const backupDataEntry = 'data.json';

/// Name of the manifest entry inside the archive.
const backupManifestEntry = 'manifest.json';

/// Prefix of media entries inside the archive (`media/<relative path>`).
const backupMediaPrefix = 'media/';

/// JSON serializer used for rows: ISO-8601 date strings keep `data.json`
/// human readable. Both ISO strings and unix timestamps are accepted on read.
const backupSerializer =
    ValueSerializer.defaults(serializeDateTimeValuesAsString: true);

/// `app_settings` table key inside `data.json`.
const settingsTableKey = 'app_settings';

/// Preference keys that may be applied from a backup. Security-related and
/// device-specific keys (app lock, active tree, onboarding, last backup) are
/// never restored, so a restore can never lock the user out.
const restorableSettingKeys = <String>{
  'themeMode',
  'accent',
  'textScale',
  'reduceMotion',
  'dashboardOrder',
  'dashboardHidden',
  'notifyBirthdays',
  'notifyAnniversaries',
  'notifyMemorials',
  'notifyEvents',
  'notifyCustom',
  'reminderLeads',
  'notifyHour',
  'encryptBackupsByDefault',
  'treeMode',
  'treeGenerations',
  'trashRetentionDays',
};

// =================================================================== errors

/// A failure while creating, reading or restoring a backup. [details] lists
/// every individual problem so the UI can show a full error report.
class BackupException implements Exception {
  BackupException(this.message, [this.details = const []]);
  final String message;
  final List<String> details;

  @override
  String toString() => message;
}

/// The archive is encrypted and no password was supplied.
class BackupPasswordRequired extends BackupException {
  BackupPasswordRequired()
      : super('This backup is protected with a password.');
}

/// Decryption of the first block failed: wrong password (or a damaged file).
class BackupWrongPassword extends BackupException {
  BackupWrongPassword()
      : super('The password is incorrect, or the backup file is damaged.');
}

/// The file is not a valid / compatible backup.
class BackupFormatException extends BackupException {
  BackupFormatException(super.message, [super.details]);
}

// ============================================================ table registry

/// Describes how one table is stored in `data.json` and how its id columns
/// relate to other rows. Field names are the drift JSON keys (camelCase).
class BackupTableSpec {
  const BackupTableSpec(
    this.name, {
    required this.fromJson,
    this.primaryKey,
    this.treeField,
    this.required = const [],
    this.optional = const [],
  });

  /// SQL table name, also used as the key inside `data.json`.
  final String name;

  /// Primary key field for entity tables (`id`), null for junction tables.
  final String? primaryKey;

  /// Field that holds the owning tree id (`treeId`), if any.
  final String? treeField;

  /// Id fields that must point at a row inside the same backup; rows whose
  /// reference cannot be resolved are dropped.
  final List<String> required;

  /// Id fields that are cleared when the referenced row is not included.
  final List<String> optional;

  /// Parses a JSON row into an insertable drift data class.
  final Insertable<dynamic> Function(Map<String, dynamic> json) fromJson;
}

/// Every family-data table in insertion order (parents before children so
/// foreign keys are always satisfied).
final List<BackupTableSpec> backupTables = [
  BackupTableSpec('family_trees',
      primaryKey: 'id',
      optional: const ['homePersonId', 'coverMediaId'],
      fromJson: (j) => FamilyTree.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('persons',
      primaryKey: 'id',
      treeField: 'treeId',
      required: const ['treeId'],
      optional: const ['profileMediaId'],
      fromJson: (j) => Person.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('parent_child_links',
      primaryKey: 'id',
      treeField: 'treeId',
      required: const ['treeId', 'parentId', 'childId'],
      fromJson: (j) =>
          ParentChildLink.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('partnerships',
      primaryKey: 'id',
      treeField: 'treeId',
      required: const ['treeId', 'personAId', 'personBId'],
      fromJson: (j) => Partnership.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('family_branches',
      primaryKey: 'id',
      treeField: 'treeId',
      required: const ['treeId'],
      optional: const ['rootPersonId'],
      fromJson: (j) => FamilyBranch.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('person_branches',
      required: const ['personId', 'branchId'],
      fromJson: (j) => PersonBranch.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('family_events',
      primaryKey: 'id',
      treeField: 'treeId',
      required: const ['treeId'],
      fromJson: (j) => FamilyEvent.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('event_persons',
      required: const ['eventId', 'personId'],
      fromJson: (j) => EventPerson.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('media_assets',
      primaryKey: 'id',
      treeField: 'treeId',
      required: const ['treeId'],
      fromJson: (j) => MediaAsset.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('media_persons',
      required: const ['mediaId', 'personId'],
      fromJson: (j) => MediaPerson.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('media_events',
      required: const ['mediaId', 'eventId'],
      fromJson: (j) => MediaEvent.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('albums',
      primaryKey: 'id',
      treeField: 'treeId',
      required: const ['treeId'],
      optional: const ['coverMediaId'],
      fromJson: (j) => Album.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('album_media',
      required: const ['albumId', 'mediaId'],
      fromJson: (j) =>
          AlbumMediaEntry.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('stories',
      primaryKey: 'id',
      treeField: 'treeId',
      required: const ['treeId'],
      optional: const ['coverMediaId'],
      fromJson: (j) => Story.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('story_persons',
      required: const ['storyId', 'personId'],
      fromJson: (j) => StoryPerson.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('story_events',
      required: const ['storyId', 'eventId'],
      fromJson: (j) => StoryEvent.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('story_media',
      required: const ['storyId', 'mediaId'],
      fromJson: (j) =>
          StoryMediaEntry.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('tags',
      primaryKey: 'id',
      treeField: 'treeId',
      required: const ['treeId'],
      fromJson: (j) => Tag.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('story_tags',
      required: const ['storyId', 'tagId'],
      fromJson: (j) => StoryTag.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('person_tags',
      required: const ['personId', 'tagId'],
      fromJson: (j) => PersonTag.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('sources',
      primaryKey: 'id',
      treeField: 'treeId',
      required: const ['treeId'],
      optional: const ['mediaId'],
      fromJson: (j) => Source.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('citations',
      primaryKey: 'id',
      required: const ['sourceId', 'entityId'],
      fromJson: (j) => Citation.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('custom_fields',
      primaryKey: 'id',
      treeField: 'treeId',
      required: const ['treeId'],
      fromJson: (j) => CustomField.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('person_custom_values',
      required: const ['personId', 'fieldId'],
      fromJson: (j) =>
          PersonCustomValue.fromJson(j, serializer: backupSerializer)),
  BackupTableSpec('reminders',
      primaryKey: 'id',
      treeField: 'treeId',
      required: const ['treeId'],
      optional: const ['personId'],
      fromJson: (j) => Reminder.fromJson(j, serializer: backupSerializer)),
];

BackupTableSpec? backupTableSpec(String name) {
  for (final s in backupTables) {
    if (s.name == name) return s;
  }
  return null;
}

/// Rows of every table, keyed by SQL table name. Values are drift JSON maps.
typedef BackupTables = Map<String, List<Map<String, dynamic>>>;

/// Summary counts shown in previews and stored in the manifest.
class BackupCounts {
  const BackupCounts({
    this.trees = 0,
    this.people = 0,
    this.relationships = 0,
    this.events = 0,
    this.photos = 0,
    this.stories = 0,
    this.albums = 0,
    this.sources = 0,
  });

  factory BackupCounts.of(BackupTables t) {
    int n(String k) => t[k]?.length ?? 0;
    return BackupCounts(
      trees: n('family_trees'),
      people: n('persons'),
      relationships: n('parent_child_links') + n('partnerships'),
      events: n('family_events'),
      photos: n('media_assets'),
      stories: n('stories'),
      albums: n('albums'),
      sources: n('sources'),
    );
  }

  factory BackupCounts.fromJson(Map<String, dynamic> j) {
    int v(String k) => (j[k] as num?)?.toInt() ?? 0;
    return BackupCounts(
      trees: v('trees'),
      people: v('people'),
      relationships: v('relationships'),
      events: v('events'),
      photos: v('photos'),
      stories: v('stories'),
      albums: v('albums'),
      sources: v('sources'),
    );
  }

  final int trees;
  final int people;
  final int relationships;
  final int events;
  final int photos;
  final int stories;
  final int albums;
  final int sources;

  Map<String, int> toJson() => {
        'trees': trees,
        'people': people,
        'relationships': relationships,
        'events': events,
        'photos': photos,
        'stories': stories,
        'albums': albums,
        'sources': sources,
      };

  String get summary => '$people people · $relationships relationships · '
      '$photos photos · $events events';
}

/// A tree listed in the manifest, with its member count.
class BackupTreeInfo {
  const BackupTreeInfo(this.id, this.name, {this.people = 0});
  final String id;
  final String name;
  final int people;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'people': people};

  factory BackupTreeInfo.fromJson(Map<String, dynamic> j) => BackupTreeInfo(
        j['id'] as String,
        (j['name'] as String?) ?? 'Family tree',
        people: (j['people'] as num?)?.toInt() ?? 0,
      );
}

/// `manifest.json`.
class BackupManifest {
  const BackupManifest({
    required this.formatVersion,
    required this.appVersion,
    required this.schemaVersion,
    required this.createdAt,
    required this.trees,
    required this.counts,
    required this.files,
    this.includesMedia = true,
    this.includesSettings = false,
    this.missingFiles = const [],
  });

  final int formatVersion;
  final String appVersion;
  final int schemaVersion;
  final DateTime createdAt;
  final List<BackupTreeInfo> trees;
  final BackupCounts counts;

  /// Archive entry path → lowercase hex SHA-256 of its content.
  final Map<String, String> files;
  final bool includesMedia;
  final bool includesSettings;

  /// Media referenced by the database that were not found on disk when the
  /// backup was created.
  final List<String> missingFiles;

  Map<String, dynamic> toJson() => {
        'format': backupFormatId,
        'formatVersion': formatVersion,
        'appVersion': appVersion,
        'schemaVersion': schemaVersion,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'trees': [for (final t in trees) t.toJson()],
        'counts': counts.toJson(),
        'includesMedia': includesMedia,
        'includesSettings': includesSettings,
        'missingFiles': missingFiles,
        'files': files,
      };

  /// Parses and validates a manifest. Throws [BackupFormatException] with
  /// every problem found.
  factory BackupManifest.parse(String text, {required int currentSchema}) {
    Object? raw;
    try {
      raw = jsonDecode(text);
    } catch (e) {
      throw BackupFormatException(
          'The backup manifest is unreadable.', ['manifest.json: $e']);
    }
    if (raw is! Map<String, dynamic>) {
      throw BackupFormatException(
          'The backup manifest is unreadable.', ['manifest.json is not an object']);
    }
    final problems = <String>[];
    if (raw['format'] != backupFormatId) {
      throw BackupFormatException('This file is not a Family Tales backup.',
          ['Unexpected format "${raw['format']}" (expected "$backupFormatId").']);
    }
    final fv = (raw['formatVersion'] as num?)?.toInt();
    final sv = (raw['schemaVersion'] as num?)?.toInt();
    final app = raw['appVersion']?.toString() ?? '?';
    if (fv == null) problems.add('formatVersion is missing.');
    if (sv == null) problems.add('schemaVersion is missing.');
    if (fv != null && fv > backupFormatVersion) {
      throw BackupFormatException(
        'This backup was made by a newer version of Family Tales.',
        [
          'Backup format v$fv (this app reads up to v$backupFormatVersion), app $app.',
          'Update Family Tales on this device, then try again.',
        ],
      );
    }
    if (sv != null && sv > currentSchema) {
      throw BackupFormatException(
        'This backup was made by a newer version of Family Tales.',
        [
          'Database schema v$sv (this app supports up to v$currentSchema), app $app.',
          'Update Family Tales on this device, then try again.',
        ],
      );
    }
    if (sv != null && sv < 1) problems.add('Invalid schemaVersion $sv.');
    final created = DateTime.tryParse(raw['createdAt']?.toString() ?? '');
    if (created == null) problems.add('createdAt is missing or invalid.');
    final filesRaw = raw['files'];
    final files = <String, String>{};
    if (filesRaw is Map) {
      for (final e in filesRaw.entries) {
        final v = e.value?.toString() ?? '';
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(v)) {
          problems.add('Invalid checksum for ${e.key}.');
        } else {
          files[e.key.toString()] = v;
        }
      }
    } else {
      problems.add('The list of files and checksums is missing.');
    }
    if (!files.containsKey(backupDataEntry)) {
      problems.add('$backupDataEntry is not listed in the manifest.');
    }
    final trees = <BackupTreeInfo>[];
    final treesRaw = raw['trees'];
    if (treesRaw is List) {
      for (final t in treesRaw) {
        if (t is Map<String, dynamic> && t['id'] is String) {
          trees.add(BackupTreeInfo.fromJson(t));
        } else {
          problems.add('Invalid tree entry in manifest.');
        }
      }
    } else {
      problems.add('The list of trees is missing.');
    }
    if (problems.isNotEmpty) {
      throw BackupFormatException('The backup manifest is invalid.', problems);
    }
    return BackupManifest(
      formatVersion: fv!,
      appVersion: app,
      schemaVersion: sv!,
      createdAt: created!.toLocal(),
      trees: trees,
      counts: BackupCounts.fromJson(
          (raw['counts'] as Map?)?.cast<String, dynamic>() ?? const {}),
      files: files,
      includesMedia: raw['includesMedia'] != false,
      includesSettings: raw['includesSettings'] == true,
      missingFiles: [
        for (final m in (raw['missingFiles'] as List?) ?? const []) m.toString()
      ],
    );
  }
}

// ======================================================= integrity helpers

/// Keeps only rows of [keepTrees] (all trees when null) and removes rows
/// whose required references are not part of the data; clears optional
/// references that cannot be resolved. Returns a new map; the input is not
/// modified. Unknown tables are dropped.
BackupTables sanitizeTables(BackupTables input, {Set<String>? keepTrees}) {
  final present = <String>{};
  final out = <String, List<Map<String, dynamic>>>{};
  // Pass 1 – required references, in dependency order.
  for (final spec in backupTables) {
    final rows = input[spec.name] ?? const [];
    final kept = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (spec.name == 'family_trees') {
        final id = r['id'];
        if (id is! String) continue;
        if (keepTrees != null && !keepTrees.contains(id)) continue;
        kept.add(Map<String, dynamic>.of(r));
        present.add(id);
        continue;
      }
      var ok = true;
      for (final f in spec.required) {
        final v = r[f];
        if (v is! String || !present.contains(v)) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      final row = Map<String, dynamic>.of(r);
      kept.add(row);
      final pk = spec.primaryKey;
      if (pk != null && row[pk] is String) present.add(row[pk] as String);
    }
    out[spec.name] = kept;
  }
  // Pass 2 – optional references.
  for (final spec in backupTables) {
    if (spec.optional.isEmpty) continue;
    for (final row in out[spec.name]!) {
      for (final f in spec.optional) {
        final v = row[f];
        if (v != null && (v is! String || !present.contains(v))) row[f] = null;
      }
    }
  }
  final settings = input[settingsTableKey];
  if (settings != null) out[settingsTableKey] = settings;
  return out;
}

/// Rewrites every id using [idMap] (old → new). Primary keys and required
/// references must be present in the map (call [sanitizeTables] first);
/// optional references missing from the map are cleared.
BackupTables remapTables(BackupTables input, Map<String, String> idMap) {
  final out = <String, List<Map<String, dynamic>>>{};
  for (final spec in backupTables) {
    final rows = input[spec.name] ?? const [];
    final mapped = <Map<String, dynamic>>[];
    for (final r in rows) {
      final row = Map<String, dynamic>.of(r);
      final pk = spec.primaryKey;
      if (pk != null) {
        final n = idMap[row[pk]];
        if (n == null) continue;
        row[pk] = n;
      }
      var ok = true;
      for (final f in spec.required) {
        final n = idMap[row[f]];
        if (n == null) {
          ok = false;
          break;
        }
        row[f] = n;
      }
      if (!ok) continue;
      for (final f in spec.optional) {
        final v = row[f];
        if (v != null) row[f] = idMap[v];
      }
      mapped.add(row);
    }
    out[spec.name] = mapped;
  }
  final settings = input[settingsTableKey];
  if (settings != null) out[settingsTableKey] = settings;
  return out;
}

/// Ids of every entity row (primary keys), used to build remapping tables.
Iterable<String> entityIds(BackupTables t) sync* {
  for (final spec in backupTables) {
    final pk = spec.primaryKey;
    if (pk == null) continue;
    for (final r in t[spec.name] ?? const <Map<String, dynamic>>[]) {
      final v = r[pk];
      if (v is String) yield v;
    }
  }
}

/// Parses and validates `data.json`. Every row is test-parsed into its
/// drift data class; problems are collected (up to [maxProblems]).
BackupTables decodeBackupData(String text, {int maxProblems = 25}) {
  Object? raw;
  try {
    raw = jsonDecode(text);
  } catch (e) {
    throw BackupFormatException(
        'The family data inside the backup is unreadable.', ['data.json: $e']);
  }
  if (raw is! Map<String, dynamic> || raw['tables'] is! Map) {
    throw BackupFormatException('The family data inside the backup is invalid.',
        ['data.json does not contain a "tables" object.']);
  }
  final tablesRaw = (raw['tables'] as Map).cast<String, dynamic>();
  final problems = <String>[];
  final out = <String, List<Map<String, dynamic>>>{};
  void problem(String p) {
    if (problems.length < maxProblems) problems.add(p);
  }

  for (final spec in backupTables) {
    final v = tablesRaw[spec.name];
    if (v == null) {
      out[spec.name] = [];
      continue;
    }
    if (v is! List) {
      problem('${spec.name}: expected a list of rows.');
      continue;
    }
    final rows = <Map<String, dynamic>>[];
    for (var i = 0; i < v.length; i++) {
      final r = v[i];
      if (r is! Map<String, dynamic>) {
        problem('${spec.name} row ${i + 1}: not an object.');
        continue;
      }
      try {
        spec.fromJson(r);
        rows.add(r);
      } catch (e) {
        problem('${spec.name} row ${i + 1}: ${_short(e)}');
      }
    }
    out[spec.name] = rows;
  }
  final settings = tablesRaw[settingsTableKey];
  if (settings is List) {
    out[settingsTableKey] = [
      for (final s in settings)
        if (s is Map<String, dynamic> && s['key'] is String && s['value'] is String)
          s
    ];
  }
  for (final k in tablesRaw.keys) {
    if (k != settingsTableKey && backupTableSpec(k) == null) {
      problem('Unknown table "$k" (ignored).');
    }
  }
  final fatal = problems.where((p) => !p.endsWith('(ignored).')).toList();
  if (fatal.isNotEmpty) {
    throw BackupFormatException(
        'Some records in this backup are damaged or incompatible.', problems);
  }
  return out;
}

String _short(Object e) {
  final s = e.toString();
  return s.length > 140 ? '${s.substring(0, 140)}…' : s;
}

/// Builds the `data.json` document.
String encodeBackupData(BackupTables tables, {required int schemaVersion}) =>
    jsonEncode({
      'format': 'family-tales-data',
      'schemaVersion': schemaVersion,
      'tables': tables,
    });

/// Checks that an archive entry path is a safe relative path below `media/`
/// (no absolute paths, drive letters, backslashes or `..` segments).
bool isSafeMediaEntry(String path) {
  if (!path.startsWith(backupMediaPrefix)) return false;
  if (path.contains('\\') || path.contains(':') || path.startsWith('/')) {
    return false;
  }
  final parts = path.split('/');
  for (final p in parts) {
    if (p.isEmpty || p == '.' || p == '..') return false;
  }
  return true;
}
