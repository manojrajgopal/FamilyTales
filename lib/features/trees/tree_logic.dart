import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/repositories/family_repository.dart';

/// Live record counts for one family tree (non-deleted records only).
@immutable
class TreeStats {
  const TreeStats({
    this.people = 0,
    this.events = 0,
    this.photos = 0,
    this.documents = 0,
    this.stories = 0,
    this.sources = 0,
  });

  final int people;
  final int events;
  final int photos;
  final int documents;
  final int stories;
  final int sources;

  static const empty = TreeStats();

  bool get isEmpty =>
      people == 0 && events == 0 && photos == 0 && documents == 0 && stories == 0 && sources == 0;
}

/// Counts per tree id, updated automatically after every write.
final treeStatsProvider = StreamProvider.autoDispose<Map<String, TreeStats>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.customSelect(
    '''
    SELECT t.id AS id,
      (SELECT COUNT(*) FROM persons x WHERE x.tree_id = t.id AND x.deleted_at IS NULL) AS people,
      (SELECT COUNT(*) FROM family_events x WHERE x.tree_id = t.id AND x.deleted_at IS NULL) AS events,
      (SELECT COUNT(*) FROM media_assets x
         WHERE x.tree_id = t.id AND x.deleted_at IS NULL AND x.kind = 'photo') AS photos,
      (SELECT COUNT(*) FROM media_assets x
         WHERE x.tree_id = t.id AND x.deleted_at IS NULL AND x.kind = 'document') AS documents,
      (SELECT COUNT(*) FROM stories x WHERE x.tree_id = t.id AND x.deleted_at IS NULL) AS stories,
      (SELECT COUNT(*) FROM sources x WHERE x.tree_id = t.id AND x.deleted_at IS NULL) AS sources
    FROM family_trees t
    WHERE t.deleted_at IS NULL
    ''',
    readsFrom: {
      db.familyTrees,
      db.persons,
      db.familyEvents,
      db.mediaAssets,
      db.stories,
      db.sources,
    },
  ).watch().map((rows) => {
        for (final r in rows)
          r.read<String>('id'): TreeStats(
            people: r.read<int>('people'),
            events: r.read<int>('events'),
            photos: r.read<int>('photos'),
            documents: r.read<int>('documents'),
            stories: r.read<int>('stories'),
            sources: r.read<int>('sources'),
          ),
      });
});

/// Result of moving a tree to the trash.
class TreeTrashResult {
  const TreeTrashResult({this.recordId, this.newActiveId, this.createdReplacement = false});

  /// Deletion record id (for Undo).
  final String? recordId;

  /// The tree that should become active, if the trashed one was active.
  final String? newActiveId;

  /// True when the trashed tree was the only one and an empty tree was
  /// created so the app always has somewhere to work.
  final bool createdReplacement;
}

/// Family-tree management operations used by the Trees and Storage screens.
class TreeActions {
  TreeActions({required this.db, required this.family});

  final AppDatabase db;
  final FamilyRepository family;

  static const maxNameLength = 120;

  String? validateName(String? name) {
    final n = name?.trim() ?? '';
    if (n.isEmpty) return 'Please give the tree a name';
    if (n.length > maxNameLength) return 'Keep the name under $maxNameLength characters';
    return null;
  }

  Future<String> create(String name, {String? description}) {
    final err = validateName(name);
    if (err != null) throw ValidationException(err);
    final d = description?.trim();
    return family.createTree(name, description: (d == null || d.isEmpty) ? null : d);
  }

  Future<void> edit(String id, {required String name, String? description}) {
    final err = validateName(name);
    if (err != null) throw ValidationException(err);
    // An empty string clears the description (null would leave it as is).
    return family.updateTree(id, name: name, description: description?.trim() ?? '');
  }

  Future<void> setHomePerson(String treeId, String personId) async {
    final p = await family.person(personId);
    if (p == null || p.treeId != treeId) {
      throw ValidationException('That person isn’t part of this tree.');
    }
    await family.updateTree(treeId, homePersonId: personId);
  }

  /// Moves [treeId] to the trash. When it was the active tree another tree
  /// becomes active; when it was the only tree and [allowLast] is true an
  /// empty replacement tree is created.
  Future<TreeTrashResult> trash(
    String treeId, {
    required String? activeId,
    bool allowLast = false,
  }) async {
    final trees = await family.allTrees();
    final others = trees.where((t) => t.id != treeId).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (others.isEmpty && !allowLast) {
      throw ValidationException(
          'This is your only family tree. Create another tree before deleting it.');
    }
    await family.trashTree(treeId);
    final recordId = await _recordFor(treeId);
    if (others.isEmpty) {
      final id = await family.createTree('My family');
      return TreeTrashResult(recordId: recordId, newActiveId: id, createdReplacement: true);
    }
    final wasActive = activeId == null || activeId == treeId;
    return TreeTrashResult(recordId: recordId, newActiveId: wasActive ? others.first.id : null);
  }

  Future<String?> _recordFor(String treeId) async {
    final r = await (db.select(db.deletionRecords)
          ..where((d) => d.entityId.equals(treeId) & d.entityType.equalsValue(TrashEntity.tree))
          ..orderBy([(d) => OrderingTerm.desc(d.deletedAt)])
          ..limit(1))
        .getSingleOrNull();
    return r?.id;
  }

  /// Explicit merge of [sourceId] into [targetId] (people are not merged).
  Future<void> merge({required String sourceId, required String targetId}) =>
      family.mergeTrees(sourceId: sourceId, targetId: targetId);
}

final treeActionsProvider = Provider<TreeActions>((ref) => TreeActions(
      db: ref.watch(databaseProvider),
      family: ref.watch(familyRepoProvider),
    ));
