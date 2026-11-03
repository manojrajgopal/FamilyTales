/// One tree's records loaded for exports (GEDCOM, CSV, PDF), with privacy
/// filtering applied once. Pure Dart apart from the database read.
library;

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../family/domain/family_graph.dart';
import 'export_privacy.dart';

class TreeExportData {
  TreeExportData({
    required this.tree,
    required this.people,
    required this.links,
    required this.partnerships,
    required this.events,
    required this.eventPeople,
    required this.sources,
    required this.citations,
    required this.fields,
    required this.values,
    required this.media,
    this.excludedPeople = 0,
  });

  final FamilyTree tree;
  final List<Person> people;
  final List<ParentChildLink> links;
  final List<Partnership> partnerships;
  final List<FamilyEvent> events;
  final List<EventPerson> eventPeople;
  final List<Source> sources;
  final List<Citation> citations;
  final List<CustomField> fields;
  final List<PersonCustomValue> values;
  final List<MediaAsset> media;

  /// People left out by the privacy filter.
  final int excludedPeople;

  late final FamilyGraph graph =
      FamilyGraph(persons: people, parentLinks: links, partnerships: partnerships);

  late final Map<String, Person> byId = {for (final p in people) p.id: p};
  late final Map<String, MediaAsset> mediaById = {for (final m in media) m.id: m};

  /// Loads every live record of [treeId] and applies [privacy].
  static Future<TreeExportData> load(
    AppDatabase db,
    String treeId, {
    ExportPrivacy privacy = ExportPrivacy.none,
  }) async {
    final tree = await (db.select(db.familyTrees)..where((t) => t.id.equals(treeId))).getSingle();
    final allPeople = await (db.select(db.persons)
          ..where((p) => p.treeId.equals(treeId) & p.deletedAt.isNull()))
        .get();
    final people = [
      for (final p in allPeople)
        if (privacy.includes(p)) privacy.apply(p)
    ];
    final ids = {for (final p in people) p.id};
    final links = (await (db.select(db.parentChildLinks)..where((l) => l.treeId.equals(treeId))).get())
        .where((l) => ids.contains(l.parentId) && ids.contains(l.childId))
        .toList();
    final partnerships = (await (db.select(db.partnerships)..where((l) => l.treeId.equals(treeId))).get())
        .where((s) => ids.contains(s.personAId) && ids.contains(s.personBId))
        .toList();
    final events = await (db.select(db.familyEvents)
          ..where((e) => e.treeId.equals(treeId) & e.deletedAt.isNull()))
        .get();
    final eventIds = {for (final e in events) e.id};
    final eventPeople = (await (db.select(db.eventPersons).join([
      innerJoin(db.familyEvents, db.familyEvents.id.equalsExp(db.eventPersons.eventId)),
    ])
              ..where(db.familyEvents.treeId.equals(treeId)))
            .map((r) => r.readTable(db.eventPersons))
            .get())
        .where((x) => eventIds.contains(x.eventId) && ids.contains(x.personId))
        .toList();
    final sources = await (db.select(db.sources)
          ..where((s) => s.treeId.equals(treeId) & s.deletedAt.isNull()))
        .get();
    final sourceIds = {for (final s in sources) s.id};
    final citations = (await (db.select(db.citations).join([
      innerJoin(db.sources, db.sources.id.equalsExp(db.citations.sourceId)),
    ])
              ..where(db.sources.treeId.equals(treeId)))
            .map((r) => r.readTable(db.citations))
            .get())
        .where((c) => sourceIds.contains(c.sourceId))
        .toList();
    final fields = (await (db.select(db.customFields)
              ..where((f) => f.treeId.equals(treeId))
              ..orderBy([(f) => OrderingTerm.asc(f.sortOrder)]))
            .get())
        .where(privacy.includesField)
        .toList();
    final fieldIds = {for (final f in fields) f.id};
    final values = (await (db.select(db.personCustomValues).join([
      innerJoin(db.customFields, db.customFields.id.equalsExp(db.personCustomValues.fieldId)),
    ])
              ..where(db.customFields.treeId.equals(treeId)))
            .map((r) => r.readTable(db.personCustomValues))
            .get())
        .where((v) => fieldIds.contains(v.fieldId) && ids.contains(v.personId))
        .toList();
    final media = (await (db.select(db.mediaAssets)
              ..where((m) => m.treeId.equals(treeId) & m.deletedAt.isNull()))
            .get())
        .where(privacy.includesMedia)
        .toList();
    return TreeExportData(
      tree: tree,
      people: people,
      links: links,
      partnerships: partnerships,
      events: events,
      eventPeople: eventPeople,
      sources: sources,
      citations: citations,
      fields: fields,
      values: values,
      media: media,
      excludedPeople: allPeople.length - people.length,
    );
  }
}
