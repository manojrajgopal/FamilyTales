/// GEDCOM / JSON / CSV export files. Builders are pure; [ExportService]
/// reads the database and writes files into the app's export folder.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/database/app_database.dart';
import '../../../core/models/fuzzy_date.dart';
import '../../../core/repositories/system_repository.dart';
import '../../../core/services/app_paths.dart';
import '../../family/domain/family_graph.dart';
import '../backup_service.dart';
import '../gedcom/gedcom_exporter.dart';
import 'export_data.dart';
import 'export_privacy.dart';

/// A written export file.
class ExportFile {
  const ExportFile(this.path, this.mimeType, this.summary);
  final String path;
  final String mimeType;
  final String summary;
  String get fileName => p.basename(path);
}

// ===================================================================== CSV

const csvColumns = [
  'Name',
  'Gender',
  'Birth date',
  'Birth place',
  'Death date',
  'Death place',
  'Living',
  'Occupation',
  'Parents',
  'Partners',
  'Children',
];

/// Escapes one CSV cell (RFC 4180) and neutralises spreadsheet formulas.
String csvCell(String? v) {
  var s = v ?? '';
  if (s.isNotEmpty && '=+-@\t\r'.contains(s[0])) s = "'$s";
  if (s.contains(RegExp(r'[",\n\r]'))) s = '"${s.replaceAll('"', '""')}"';
  return s;
}

/// Members table as CSV (UTF-8 with BOM so spreadsheet apps detect it).
String buildMembersCsv(TreeExportData data) {
  final g = data.graph;
  String names(Iterable<String> ids) =>
      ids.map((id) => g[id]?.displayName).whereType<String>().join('; ');
  final rows = <List<String?>>[csvColumns];
  for (final person in g.sortedPeople()) {
    rows.add([
      person.displayName,
      person.gender.label,
      FuzzyDate.tryParse(person.birthDate)?.format(),
      person.birthPlace,
      FuzzyDate.tryParse(person.deathDate)?.format(),
      person.deathPlace,
      person.isLiving ? 'Yes' : 'No',
      person.occupation,
      names(g.parentIds(person.id)),
      names(g.partnerIds(person.id)),
      names(g.childIds(person.id)),
    ]);
  }
  return '﻿${rows.map((r) => r.map(csvCell).join(',')).join('\r\n')}\r\n';
}

// ==================================================================== JSON

/// Applies [privacy] to backup-style table maps for a public JSON export.
BackupTables applyPrivacyToTables(BackupTables t, ExportPrivacy privacy) {
  if (!privacy.enabled) return t;
  final out = <String, List<Map<String, dynamic>>>{...t};
  out['persons'] = [
    for (final row in t['persons'] ?? const <Map<String, dynamic>>[])
      if (privacy.includes(Person.fromJson(row, serializer: backupSerializer)))
        privacy.apply(Person.fromJson(row, serializer: backupSerializer)).toJson(serializer: backupSerializer)
  ];
  if (privacy.hidesPrivateExtras) {
    out['custom_fields'] = [
      for (final r in t['custom_fields'] ?? const <Map<String, dynamic>>[])
        if (r['isPrivate'] != true) r
    ];
    out['media_assets'] = [
      for (final r in t['media_assets'] ?? const <Map<String, dynamic>>[])
        if (r['isPrivate'] != true) r
    ];
    out['stories'] = [
      for (final r in t['stories'] ?? const <Map<String, dynamic>>[])
        if (r['isPrivate'] != true) r
    ];
  }
  if (privacy.hidesContact || privacy.hidesNotes) {
    // Reminders are personal planning notes – never part of a public export.
    out['reminders'] = [];
  }
  return sanitizeTables(out);
}

String buildTreeJson(BackupTables tables, {required int schemaVersion, required ExportPrivacy privacy}) {
  final tree = (tables['family_trees'] ?? const []).isEmpty ? null : tables['family_trees']!.first;
  return const JsonEncoder.withIndent('  ').convert({
    'format': 'family-tales-json',
    'formatVersion': 1,
    'appVersion': backupAppVersion,
    'schemaVersion': schemaVersion,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'tree': tree?['name'],
    'privacy': privacy.summary,
    'counts': BackupCounts.of(tables).toJson(),
    'tables': {
      for (final e in tables.entries)
        if (e.key != settingsTableKey) e.key: e.value,
    },
  });
}

// ================================================================= service

class ExportService {
  ExportService(this.db, {SystemRepository? system}) : system = system ?? SystemRepository(db);
  final AppDatabase db;
  final SystemRepository system;

  Future<String> _write(String treeName, String ext, String content) async {
    final dir = AppPaths.I.exportsDir();
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    var slug = treeName.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    if (slug.isEmpty) slug = 'Family';
    if (slug.length > 40) slug = slug.substring(0, 40);
    final path = p.join(dir.path, '${slug}_${n.year}-${two(n.month)}-${two(n.day)}.$ext');
    await File(path).writeAsString(content, flush: true);
    return path;
  }

  Future<ExportFile> gedcom(String treeId, ExportPrivacy privacy) async {
    final data = await TreeExportData.load(db, treeId, privacy: privacy);
    final res = GedcomExporter(data, privacy: privacy).build();
    final path = await _write(data.tree.name, 'ged', res.text);
    await _log(path, 'GEDCOM · ${res.summary}');
    return ExportFile(path, 'text/x-gedcom', res.summary);
  }

  Future<ExportFile> json(String treeId, ExportPrivacy privacy) async {
    final tables = applyPrivacyToTables(
        await BackupService(db, system: system).collectTables([treeId]), privacy);
    final text = buildTreeJson(tables, schemaVersion: db.schemaVersion, privacy: privacy);
    final name = (tables['family_trees']!.isEmpty ? 'Family' : tables['family_trees']!.first['name']) as String;
    final path = await _write(name, 'json', text);
    final summary = BackupCounts.of(tables).summary;
    await _log(path, 'JSON · $summary');
    return ExportFile(path, 'application/json', summary);
  }

  Future<ExportFile> csv(String treeId, ExportPrivacy privacy) async {
    final data = await TreeExportData.load(db, treeId, privacy: privacy);
    final path = await _write(data.tree.name, 'csv', buildMembersCsv(data));
    final summary = '${data.people.length} members';
    await _log(path, 'CSV · $summary');
    return ExportFile(path, 'text/csv', summary);
  }

  Future<void> _log(String path, String summary) async {
    await system.logBackup(
      kind: 'export',
      fileName: p.basename(path),
      sizeBytes: await File(path).length(),
      summary: summary,
    );
  }
}
