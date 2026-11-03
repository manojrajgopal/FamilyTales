import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../features/family/domain/family_graph.dart';
import '../database/app_database.dart';
import '../models/enums.dart';
import '../models/fuzzy_date.dart';

String newId() => const Uuid().v4();

/// Validation failure with a user-facing message.
class ValidationException implements Exception {
  ValidationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Family trees, people and their explicit relationships.
///
/// Only parent→child and partner edges are stored; every other kinship is
/// derived (see FamilyGraph / KinshipCalculator). Multi-table operations run
/// in transactions.
class FamilyRepository {
  FamilyRepository(this.db);
  final AppDatabase db;

  // ================================================================ trees

  Stream<List<FamilyTree>> watchTrees() => (db.select(db.familyTrees)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
      .watch();

  Future<List<FamilyTree>> allTrees() => (db.select(db.familyTrees)
        ..where((t) => t.deletedAt.isNull()))
      .get();

  Stream<FamilyTree?> watchTree(String id) =>
      (db.select(db.familyTrees)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<FamilyTree?> tree(String id) =>
      (db.select(db.familyTrees)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<String> createTree(String name, {String? description, bool isExample = false}) async {
    final id = newId();
    await db.into(db.familyTrees).insert(FamilyTreesCompanion.insert(
          id: id,
          name: name.trim(),
          description: Value(description),
          isExample: Value(isExample),
        ));
    return id;
  }

  Future<void> updateTree(String id, {String? name, String? description, String? homePersonId}) {
    return (db.update(db.familyTrees)..where((t) => t.id.equals(id))).write(
      FamilyTreesCompanion(
        name: name == null ? const Value.absent() : Value(name.trim()),
        description: description == null ? const Value.absent() : Value(description),
        homePersonId: homePersonId == null ? const Value.absent() : Value(homePersonId),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Moves a whole tree to the trash.
  Future<void> trashTree(String id) async {
    final t = await tree(id);
    if (t == null) return;
    await db.transaction(() async {
      await (db.update(db.familyTrees)..where((x) => x.id.equals(id)))
          .write(FamilyTreesCompanion(deletedAt: Value(DateTime.now())));
      await db.into(db.deletionRecords).insert(DeletionRecordsCompanion.insert(
            id: newId(),
            treeId: Value(id),
            entityType: TrashEntity.tree,
            entityId: id,
            label: t.name,
          ));
    });
  }

  /// Explicit, user-confirmed merge: moves every record of [sourceId] into
  /// [targetId] and removes the (now empty) source tree. People are NOT
  /// merged automatically – use duplicate detection afterwards.
  Future<void> mergeTrees({required String sourceId, required String targetId}) async {
    if (sourceId == targetId) throw ValidationException('Choose two different trees.');
    await db.transaction(() async {
      final tables = <TableInfo<Table, dynamic>>[
        db.persons,
        db.parentChildLinks,
        db.partnerships,
        db.familyBranches,
        db.familyEvents,
        db.mediaAssets,
        db.albums,
        db.stories,
        db.sources,
        db.reminders,
        db.tags,
        db.customFields,
      ];
      for (final t in tables) {
        await db.customUpdate(
          'UPDATE ${t.actualTableName} SET tree_id = ? WHERE tree_id = ?',
          variables: [Variable.withString(targetId), Variable.withString(sourceId)],
          updates: {t},
        );
      }
      await db.customUpdate(
        'UPDATE deletion_records SET tree_id = ? WHERE tree_id = ?',
        variables: [Variable.withString(targetId), Variable.withString(sourceId)],
        updates: {db.deletionRecords},
      );
      // Both trees may have had a tag with the same name: keep one.
      final seen = <String, String>{};
      for (final t in await (db.select(db.tags)..where((t) => t.treeId.equals(targetId))).get()) {
        final keep = seen.putIfAbsent(t.name.trim().toLowerCase(), () => t.id);
        if (keep == t.id) continue;
        for (final link in ['person_tags', 'story_tags']) {
          await db.customStatement('UPDATE OR IGNORE $link SET tag_id = ? WHERE tag_id = ?', [keep, t.id]);
          await db.customStatement('DELETE FROM $link WHERE tag_id = ?', [t.id]);
        }
        await (db.delete(db.tags)..where((x) => x.id.equals(t.id))).go();
      }
      await (db.delete(db.familyTrees)..where((t) => t.id.equals(sourceId))).go();
    });
  }

  // ================================================================ people

  Stream<List<Person>> watchPeople(String treeId, {bool includeArchived = true}) {
    final q = db.select(db.persons)
      ..where((p) => p.treeId.equals(treeId) & p.deletedAt.isNull());
    if (!includeArchived) q.where((p) => p.isArchived.equals(false));
    return q.watch();
  }

  Future<List<Person>> people(String treeId) => (db.select(db.persons)
        ..where((p) => p.treeId.equals(treeId) & p.deletedAt.isNull()))
      .get();

  Stream<Person?> watchPerson(String id) =>
      (db.select(db.persons)..where((p) => p.id.equals(id))).watchSingleOrNull();

  Future<Person?> person(String id) =>
      (db.select(db.persons)..where((p) => p.id.equals(id))).getSingleOrNull();

  Future<String> createPerson(PersonsCompanion data) async {
    _validatePerson(data);
    final id = data.id.present ? data.id.value : newId();
    await db.into(db.persons).insert(data.copyWith(id: Value(id)));
    return id;
  }

  Future<void> updatePerson(String id, PersonsCompanion data) async {
    _validatePerson(data);
    await (db.update(db.persons)..where((p) => p.id.equals(id)))
        .write(data.copyWith(updatedAt: Value(DateTime.now())));
  }

  void _validatePerson(PersonsCompanion d) {
    final first = d.firstName.present ? d.firstName.value.trim() : null;
    final full = d.fullName.present ? d.fullName.value?.trim() : null;
    final last = d.lastName.present ? d.lastName.value?.trim() : null;
    if (d.firstName.present &&
        (first == null || first.isEmpty) &&
        (full == null || full.isEmpty) &&
        (last == null || last.isEmpty)) {
      throw ValidationException('Please enter at least a first or last name.');
    }
    final b = d.birthDate.present ? FuzzyDate.tryParse(d.birthDate.value) : null;
    final de = d.deathDate.present ? FuzzyDate.tryParse(d.deathDate.value) : null;
    if (b != null && de != null && b.approxYear != null && de.approxYear != null) {
      if (de.qualifier == DateQualifier.exact && b.qualifier == DateQualifier.exact && _endsBefore(de, b)) {
        throw ValidationException('Date of death cannot be before date of birth.');
      }
    }
    if (b != null && b.isExactDay && b.toDateTime()!.isAfter(DateTime.now())) {
      throw ValidationException('Date of birth cannot be in the future.');
    }
  }

  /// True only when [a] is certainly earlier than [b], comparing just the
  /// parts both dates have (a year-only death in the birth year is fine).
  static bool _endsBefore(FuzzyDate a, FuzzyDate b) {
    if (a.year == null || b.year == null) return false;
    if (a.year != b.year) return a.year! < b.year!;
    if (a.month == null || b.month == null) return false;
    if (a.month != b.month) return a.month! < b.month!;
    if (a.day == null || b.day == null) return false;
    return a.day! < b.day!;
  }

  Future<void> setProfilePhoto(String personId, String? mediaId) =>
      (db.update(db.persons)..where((p) => p.id.equals(personId))).write(
          PersonsCompanion(profileMediaId: Value(mediaId), updatedAt: Value(DateTime.now())));

  Future<void> setArchived(Iterable<String> ids, bool archived) =>
      (db.update(db.persons)..where((p) => p.id.isIn(ids))).write(
          PersonsCompanion(isArchived: Value(archived), updatedAt: Value(DateTime.now())));

  Future<void> setPrivate(String id, bool private) =>
      (db.update(db.persons)..where((p) => p.id.equals(id))).write(
          PersonsCompanion(isPrivate: Value(private), updatedAt: Value(DateTime.now())));

  /// Soft delete: the person (and their relationships) can be restored from
  /// the trash.
  Future<void> trashPerson(String id) async {
    final p = await person(id);
    if (p == null) return;
    await db.transaction(() async {
      await (db.update(db.persons)..where((x) => x.id.equals(id)))
          .write(PersonsCompanion(deletedAt: Value(DateTime.now())));
      await db.into(db.deletionRecords).insert(DeletionRecordsCompanion.insert(
            id: newId(),
            treeId: Value(p.treeId),
            entityType: TrashEntity.person,
            entityId: id,
            label: p.displayName,
          ));
    });
  }

  // ========================================================= relationships

  Stream<List<ParentChildLink>> watchParentLinks(String treeId) =>
      (db.select(db.parentChildLinks)..where((l) => l.treeId.equals(treeId))).watch();

  Stream<List<Partnership>> watchPartnerships(String treeId) =>
      (db.select(db.partnerships)..where((l) => l.treeId.equals(treeId))).watch();

  Future<FamilyGraph> loadGraph(String treeId) async {
    final ps = await people(treeId);
    final ls = await (db.select(db.parentChildLinks)..where((l) => l.treeId.equals(treeId))).get();
    final ss = await (db.select(db.partnerships)..where((l) => l.treeId.equals(treeId))).get();
    return FamilyGraph(persons: ps, parentLinks: ls, partnerships: ss);
  }

  /// Graph including people in the trash. Used for validation and merging so
  /// a trashed relative's links still count (restoring them must never
  /// produce loops or a third biological parent) and are never lost.
  Future<FamilyGraph> _fullGraph(String treeId) async {
    final ps = await (db.select(db.persons)..where((p) => p.treeId.equals(treeId))).get();
    final ls = await (db.select(db.parentChildLinks)..where((l) => l.treeId.equals(treeId))).get();
    final ss = await (db.select(db.partnerships)..where((l) => l.treeId.equals(treeId))).get();
    return FamilyGraph(persons: ps, parentLinks: ls, partnerships: ss);
  }

  /// Links [parentId] as a parent of [childId] after validating that the
  /// edge is sensible (no self links, no cycles, no duplicate links, at most
  /// two biological parents).
  Future<String> addParent({
    required String childId,
    required String parentId,
    ParentType type = ParentType.biological,
    FuzzyDate? start,
    FuzzyDate? end,
    String? notes,
  }) async {
    final child = await person(childId);
    final parent = await person(parentId);
    if (child == null || parent == null) throw ValidationException('Person not found.');
    if (child.treeId != parent.treeId) {
      throw ValidationException('Both people must belong to the same family tree.');
    }
    final g = await _fullGraph(child.treeId);
    if (parentId == childId) throw ValidationException('A person cannot be their own parent.');
    if (g.parentIds(childId).contains(parentId)) {
      throw ValidationException('${parent.displayName} is already a parent of ${child.displayName}.');
    }
    if (g.wouldCreateCycle(parentId, childId)) {
      throw ValidationException(
          '${parent.displayName} is a descendant of ${child.displayName}; this would create a loop.');
    }
    if (g.partnerIds(childId).contains(parentId)) {
      throw ValidationException('Partners cannot also be parent and child.');
    }
    final bio = g.parentLinksOf(childId).where((l) => l.type == ParentType.biological).toList();
    if (type == ParentType.biological && bio.length >= 2) {
      final trashed = bio.any((l) => g[l.parentId]?.deletedAt != null);
      throw ValidationException(
          '${child.displayName} already has two biological parents${trashed ? ' (one is in the Trash – restore or delete them first)' : ''}. '
          'Choose another relationship type (e.g. step, adoptive or guardian).');
    }
    final id = newId();
    await db.into(db.parentChildLinks).insert(ParentChildLinksCompanion.insert(
          id: id,
          treeId: child.treeId,
          parentId: parentId,
          childId: childId,
          type: Value(type),
          startDate: Value(start?.serialize()),
          endDate: Value(end?.serialize()),
          notes: Value(notes),
        ));
    await _touch(childId);
    return id;
  }

  Future<void> updateParentLink(String linkId, {ParentType? type, String? notes}) =>
      (db.update(db.parentChildLinks)..where((l) => l.id.equals(linkId))).write(
        ParentChildLinksCompanion(
          type: type == null ? const Value.absent() : Value(type),
          notes: notes == null ? const Value.absent() : Value(notes),
          updatedAt: Value(DateTime.now()),
        ),
      );

  /// Removes a parent link and returns an undo token (deletion record id).
  Future<String> removeParentLink(String linkId) async {
    final l = await (db.select(db.parentChildLinks)..where((x) => x.id.equals(linkId)))
        .getSingleOrNull();
    if (l == null) throw ValidationException('Relationship not found.');
    final recId = newId();
    final parent = await person(l.parentId);
    final child = await person(l.childId);
    await db.transaction(() async {
      await db.into(db.deletionRecords).insert(DeletionRecordsCompanion.insert(
            id: recId,
            treeId: Value(l.treeId),
            entityType: TrashEntity.relationship,
            entityId: l.id,
            label: '${parent?.displayName ?? '?'} → ${child?.displayName ?? '?'} (${l.type.label.toLowerCase()} parent)',
            payload: Value(jsonEncode({'kind': 'parentChild', ...l.toJson()})),
          ));
      await (db.delete(db.parentChildLinks)..where((x) => x.id.equals(linkId))).go();
    });
    return recId;
  }

  Future<String> addPartnership({
    required String a,
    required String b,
    PartnerType type = PartnerType.marriage,
    PartnerStatus status = PartnerStatus.current,
    FuzzyDate? start,
    FuzzyDate? end,
    String? place,
    String? notes,
  }) async {
    if (a == b) throw ValidationException('A person cannot partner with themselves.');
    final pa = await person(a);
    final pb = await person(b);
    if (pa == null || pb == null) throw ValidationException('Person not found.');
    if (pa.treeId != pb.treeId) {
      throw ValidationException('Both people must belong to the same family tree.');
    }
    final g = await _fullGraph(pa.treeId);
    final existing = g.partnershipBetween(a, b);
    if (existing != null && existing.status == PartnerStatus.current &&
        status == PartnerStatus.current) {
      throw ValidationException('${pa.displayName} and ${pb.displayName} are already partners.');
    }
    if (g.ancestors(a).contains(b) || g.descendants(a).contains(b)) {
      throw ValidationException('A direct ancestor and descendant cannot be partners.');
    }
    final id = newId();
    await db.into(db.partnerships).insert(PartnershipsCompanion.insert(
          id: id,
          treeId: pa.treeId,
          personAId: a,
          personBId: b,
          type: Value(type),
          status: Value(status),
          startDate: Value(start?.serialize()),
          endDate: Value(end?.serialize()),
          place: Value(place),
          notes: Value(notes),
        ));
    await _touch(a);
    await _touch(b);
    return id;
  }

  Future<void> updatePartnership(String id, PartnershipsCompanion data) =>
      (db.update(db.partnerships)..where((s) => s.id.equals(id)))
          .write(data.copyWith(updatedAt: Value(DateTime.now())));

  Future<String> removePartnership(String id) async {
    final s = await (db.select(db.partnerships)..where((x) => x.id.equals(id))).getSingleOrNull();
    if (s == null) throw ValidationException('Relationship not found.');
    final a = await person(s.personAId);
    final b = await person(s.personBId);
    final recId = newId();
    await db.transaction(() async {
      await db.into(db.deletionRecords).insert(DeletionRecordsCompanion.insert(
            id: recId,
            treeId: Value(s.treeId),
            entityType: TrashEntity.relationship,
            entityId: s.id,
            label: '${a?.displayName ?? '?'} & ${b?.displayName ?? '?'} (${s.type.label.toLowerCase()})',
            payload: Value(jsonEncode({'kind': 'partnership', ...s.toJson()})),
          ));
      await (db.delete(db.partnerships)..where((x) => x.id.equals(id))).go();
    });
    return recId;
  }

  Future<void> _touch(String personId) =>
      (db.update(db.persons)..where((p) => p.id.equals(personId)))
          .write(PersonsCompanion(updatedAt: Value(DateTime.now())));

  // ===================================================== composite helpers

  /// Creates a person and links them in one transaction.
  Future<String> createPersonWithLinks(
    PersonsCompanion data, {
    List<(String parentId, ParentType type)> parents = const [],
    List<(String childId, ParentType type)> children = const [],
    List<(String partnerId, PartnerType type, PartnerStatus status)> partners = const [],
  }) async {
    return db.transaction(() async {
      final id = await createPerson(data);
      for (final (pid, t) in parents) {
        await addParent(childId: id, parentId: pid, type: t);
      }
      for (final (cid, t) in children) {
        await addParent(childId: cid, parentId: id, type: t);
      }
      for (final (sid, t, st) in partners) {
        await addPartnership(a: id, b: sid, type: t, status: st);
      }
      return id;
    });
  }

  // ============================================================ custom data

  Stream<List<CustomField>> watchCustomFields(String treeId) => (db.select(db.customFields)
        ..where((f) => f.treeId.equals(treeId))
        ..orderBy([(f) => OrderingTerm.asc(f.sortOrder), (f) => OrderingTerm.asc(f.name)]))
      .watch();

  Future<String> addCustomField(String treeId, String name, CustomFieldType type,
      {bool isPrivate = false}) async {
    final id = newId();
    await db.into(db.customFields).insert(CustomFieldsCompanion.insert(
        id: id, treeId: treeId, name: name.trim(), fieldType: Value(type), isPrivate: Value(isPrivate)));
    return id;
  }

  Future<void> updateCustomField(String id, {String? name, bool? isPrivate}) =>
      (db.update(db.customFields)..where((f) => f.id.equals(id))).write(CustomFieldsCompanion(
        name: name == null ? const Value.absent() : Value(name),
        isPrivate: isPrivate == null ? const Value.absent() : Value(isPrivate),
        updatedAt: Value(DateTime.now()),
      ));

  Future<void> deleteCustomField(String id) =>
      (db.delete(db.customFields)..where((f) => f.id.equals(id))).go();

  Stream<List<PersonCustomValue>> watchCustomValues(String personId) =>
      (db.select(db.personCustomValues)..where((v) => v.personId.equals(personId))).watch();

  Future<void> setCustomValue(String personId, String fieldId, String? value) async {
    if (value == null || value.trim().isEmpty) {
      await (db.delete(db.personCustomValues)
            ..where((v) => v.personId.equals(personId) & v.fieldId.equals(fieldId)))
          .go();
    } else {
      await db.into(db.personCustomValues).insertOnConflictUpdate(
          PersonCustomValuesCompanion.insert(personId: personId, fieldId: fieldId, value: value.trim()));
    }
  }

  // ================================================================== tags

  Stream<List<Tag>> watchTags(String treeId) =>
      (db.select(db.tags)..where((t) => t.treeId.equals(treeId))..orderBy([(t) => OrderingTerm.asc(t.name)]))
          .watch();

  Future<String> ensureTag(String treeId, String name) async {
    final existing = await (db.select(db.tags)
          ..where((t) => t.treeId.equals(treeId) & t.name.lower().equals(name.trim().toLowerCase()))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) return existing.id;
    final id = newId();
    await db.into(db.tags).insert(TagsCompanion.insert(id: id, treeId: treeId, name: name.trim()));
    return id;
  }

  Stream<List<PersonTag>> watchPersonTags(String treeId) {
    final q = db.select(db.personTags).join([
      innerJoin(db.persons, db.persons.id.equalsExp(db.personTags.personId)),
    ])
      ..where(db.persons.treeId.equals(treeId));
    return q.watch().map((rows) => rows.map((r) => r.readTable(db.personTags)).toList());
  }

  Future<void> tagPeople(Iterable<String> personIds, String tagId) async {
    await db.batch((b) {
      for (final p in personIds) {
        b.insert(db.personTags, PersonTagsCompanion.insert(personId: p, tagId: tagId),
            mode: InsertMode.insertOrIgnore);
      }
    });
  }

  Future<void> untagPerson(String personId, String tagId) =>
      (db.delete(db.personTags)..where((t) => t.personId.equals(personId) & t.tagId.equals(tagId))).go();

  // ============================================================== branches

  Stream<List<FamilyBranch>> watchBranches(String treeId) => (db.select(db.familyBranches)
        ..where((b) => b.treeId.equals(treeId))
        ..orderBy([(b) => OrderingTerm.asc(b.name)]))
      .watch();

  Stream<List<PersonBranch>> watchBranchMembers(String treeId) {
    final q = db.select(db.personBranches).join([
      innerJoin(db.familyBranches, db.familyBranches.id.equalsExp(db.personBranches.branchId)),
    ])
      ..where(db.familyBranches.treeId.equals(treeId));
    return q.watch().map((rows) => rows.map((r) => r.readTable(db.personBranches)).toList());
  }

  Future<String> createBranch(String treeId, String name,
      {String? rootPersonId, String? description, int? color}) async {
    final id = newId();
    await db.into(db.familyBranches).insert(FamilyBranchesCompanion.insert(
          id: id,
          treeId: treeId,
          name: name.trim(),
          rootPersonId: Value(rootPersonId),
          description: Value(description),
          colorValue: Value(color),
        ));
    return id;
  }

  Future<void> updateBranch(String id,
          {String? name, String? description, String? rootPersonId, bool clearRoot = false, int? color}) =>
      (db.update(db.familyBranches)..where((b) => b.id.equals(id))).write(FamilyBranchesCompanion(
        name: name == null ? const Value.absent() : Value(name.trim()),
        description: description == null ? const Value.absent() : Value(description),
        rootPersonId: clearRoot
            ? const Value(null)
            : (rootPersonId == null ? const Value.absent() : Value(rootPersonId)),
        colorValue: color == null ? const Value.absent() : Value(color),
        updatedAt: Value(DateTime.now()),
      ));

  Future<void> deleteBranch(String id) =>
      (db.delete(db.familyBranches)..where((b) => b.id.equals(id))).go();

  Future<void> assignToBranch(Iterable<String> personIds, String branchId) async {
    await db.batch((b) {
      for (final p in personIds) {
        b.insert(db.personBranches, PersonBranchesCompanion.insert(personId: p, branchId: branchId),
            mode: InsertMode.insertOrIgnore);
      }
    });
  }

  Future<void> removeFromBranch(String personId, String branchId) => (db.delete(db.personBranches)
        ..where((b) => b.personId.equals(personId) & b.branchId.equals(branchId)))
      .go();

  // ================================================================ merge

  /// Merges [removeId] into [keepId]: relationships, events, media, stories,
  /// citations, tags and custom values are re-pointed; empty fields on the
  /// kept person are filled from the removed one; the removed person is
  /// deleted. Triggered only by explicit user action.
  Future<void> mergePeople({required String keepId, required String removeId}) async {
    if (keepId == removeId) return;
    final keep = await person(keepId);
    final remove = await person(removeId);
    if (keep == null || remove == null) throw ValidationException('Person not found.');
    await db.transaction(() async {
      final g = await _fullGraph(keep.treeId);
      // Refuse merges that would make someone their own ancestor (through
      // any kind of parent link) or give the kept person a third
      // biological parent.
      for (final l in g.parentLinksOf(removeId)) {
        if (l.parentId != keepId && g.wouldCreateCycle(l.parentId, keepId)) {
          throw ValidationException('These two can’t be merged: ${g[l.parentId]?.displayName ?? 'a parent'} '
              'would become their own ancestor.');
        }
      }
      for (final l in g.childLinksOf(removeId)) {
        if (l.childId != keepId && g.wouldCreateCycle(keepId, l.childId)) {
          throw ValidationException('These two can’t be merged: ${g[l.childId]?.displayName ?? 'a child'} '
              'would become their own ancestor.');
        }
      }
      final keepPartners = g.partnerIds(keepId).toSet();
      for (final l in [...g.parentLinksOf(removeId), ...g.childLinksOf(removeId)]) {
        final other = l.parentId == removeId ? l.childId : l.parentId;
        if (keepPartners.contains(other)) {
          throw ValidationException('These two can’t be merged: ${g[other]?.displayName ?? 'someone'} '
              'would be both a partner and a parent or child.');
        }
      }
      final kin = {...g.ancestors(keepId), ...g.descendants(keepId)};
      for (final s in g.partnershipsOf(removeId)) {
        final other = s.personAId == removeId ? s.personBId : s.personAId;
        if (other != keepId && kin.contains(other)) {
          throw ValidationException('These two can’t be merged: ${g[other]?.displayName ?? 'someone'} '
              'would become the partner of their own ancestor or descendant.');
        }
      }
      final bio = {
        for (final l in [...g.parentLinksOf(keepId), ...g.parentLinksOf(removeId)])
          if (l.type == ParentType.biological && l.parentId != keepId && l.parentId != removeId) l.parentId
      };
      if (bio.length > 2) {
        throw ValidationException('These two can’t be merged: together they would have more than two '
            'biological parents. Fix their parents first.');
      }
      // Parent links where removed person is child.
      for (final l in g.parentLinksOf(removeId)) {
        if (l.parentId == keepId || g.parentIds(keepId).contains(l.parentId)) {
          await (db.delete(db.parentChildLinks)..where((x) => x.id.equals(l.id))).go();
        } else {
          await (db.update(db.parentChildLinks)..where((x) => x.id.equals(l.id)))
              .write(ParentChildLinksCompanion(childId: Value(keepId)));
        }
      }
      for (final l in g.childLinksOf(removeId)) {
        if (l.childId == keepId || g.childIds(keepId).contains(l.childId)) {
          await (db.delete(db.parentChildLinks)..where((x) => x.id.equals(l.id))).go();
        } else {
          await (db.update(db.parentChildLinks)..where((x) => x.id.equals(l.id)))
              .write(ParentChildLinksCompanion(parentId: Value(keepId)));
        }
      }
      for (final s in g.partnershipsOf(removeId)) {
        final other = s.personAId == removeId ? s.personBId : s.personAId;
        if (other == keepId || g.partnerIds(keepId).contains(other)) {
          await (db.delete(db.partnerships)..where((x) => x.id.equals(s.id))).go();
        } else {
          await (db.update(db.partnerships)..where((x) => x.id.equals(s.id))).write(
              s.personAId == removeId
                  ? PartnershipsCompanion(personAId: Value(keepId))
                  : PartnershipsCompanion(personBId: Value(keepId)));
        }
      }
      for (final table in ['event_persons', 'media_persons', 'story_persons', 'person_tags', 'person_branches', 'person_custom_values']) {
        await db.customStatement(
            'UPDATE OR IGNORE $table SET person_id = ? WHERE person_id = ?', [keepId, removeId]);
        await db.customStatement('DELETE FROM $table WHERE person_id = ?', [removeId]);
      }
      await db.customStatement(
          "UPDATE citations SET entity_id = ? WHERE entity_type = 'person' AND entity_id = ?",
          [keepId, removeId]);
      await db.customStatement('UPDATE reminders SET person_id = ? WHERE person_id = ?', [keepId, removeId]);
      await db.customStatement(
          'UPDATE family_branches SET root_person_id = ? WHERE root_person_id = ?', [keepId, removeId]);

      String? pick(String? a, String? b) => (a == null || a.trim().isEmpty) ? b : a;
      final notes = [keep.notes, remove.notes].whereType<String>().where((s) => s.trim().isNotEmpty).join('\n\n');
      await updatePerson(
        keepId,
        PersonsCompanion(
          middleName: Value(pick(keep.middleName, remove.middleName)),
          fullName: Value(pick(keep.fullName, remove.fullName)),
          pronouns: Value(pick(keep.pronouns, remove.pronouns)),
          birthNotes: Value(pick(keep.birthNotes, remove.birthNotes)),
          causeOfDeath: Value(pick(keep.causeOfDeath, remove.causeOfDeath)),
          burialPlace: Value(pick(keep.burialPlace, remove.burialPlace)),
          deathNotes: Value(pick(keep.deathNotes, remove.deathNotes)),
          nationality: Value(pick(keep.nationality, remove.nationality)),
          languages: Value(pick(keep.languages, remove.languages)),
          interests: Value(pick(keep.interests, remove.interests)),
          achievements: Value(pick(keep.achievements, remove.achievements)),
          email: Value(pick(keep.email, remove.email)),
          phone: Value(pick(keep.phone, remove.phone)),
          address: Value(pick(keep.address, remove.address)),
          isPrivate: Value(keep.isPrivate || remove.isPrivate),
          lastName: Value(pick(keep.lastName, remove.lastName)),
          birthName: Value(pick(keep.birthName, remove.birthName)),
          nickname: Value(pick(keep.nickname, remove.nickname)),
          gender: Value(keep.gender == Gender.unknown ? remove.gender : keep.gender),
          profileMediaId: Value(keep.profileMediaId ?? remove.profileMediaId),
          birthDate: Value(keep.birthDate ?? remove.birthDate),
          birthPlace: Value(pick(keep.birthPlace, remove.birthPlace)),
          birthCountry: Value(pick(keep.birthCountry, remove.birthCountry)),
          deathDate: Value(keep.deathDate ?? remove.deathDate),
          deathPlace: Value(pick(keep.deathPlace, remove.deathPlace)),
          isLiving: Value(keep.isLiving && remove.isLiving),
          occupation: Value(pick(keep.occupation, remove.occupation)),
          education: Value(pick(keep.education, remove.education)),
          biography: Value(pick(keep.biography, remove.biography)),
          notes: Value(notes.isEmpty ? null : notes),
        ),
      );
      final tree = await this.tree(keep.treeId);
      if (tree?.homePersonId == removeId) await updateTree(keep.treeId, homePersonId: keepId);
      await (db.delete(db.persons)..where((p) => p.id.equals(removeId))).go();
    });
  }
}
