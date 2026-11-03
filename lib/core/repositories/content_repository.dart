import 'dart:io';

import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../models/enums.dart';
import '../services/app_paths.dart';
import '../services/media_storage.dart';
import 'family_repository.dart';

/// An event with the ids of the people it involves.
class EventWithPeople {
  const EventWithPeople(this.event, this.personIds, this.roles);
  final FamilyEvent event;
  final List<String> personIds;
  final Map<String, String?> roles;
}

/// Events, media (photos & documents), albums, stories, sources/citations
/// and custom reminders.
class ContentRepository {
  ContentRepository(this.db, {this.storage = const MediaStorage()});
  final AppDatabase db;
  final MediaStorage storage;

  // ================================================================ events

  Stream<List<FamilyEvent>> watchEvents(String treeId) => (db.select(db.familyEvents)
        ..where((e) => e.treeId.equals(treeId) & e.deletedAt.isNull()))
      .watch();

  Stream<List<EventPerson>> watchEventPeople(String treeId) {
    final q = db.select(db.eventPersons).join([
      innerJoin(db.familyEvents, db.familyEvents.id.equalsExp(db.eventPersons.eventId)),
    ])
      ..where(db.familyEvents.treeId.equals(treeId));
    return q.watch().map((r) => r.map((x) => x.readTable(db.eventPersons)).toList());
  }

  Stream<FamilyEvent?> watchEvent(String id) =>
      (db.select(db.familyEvents)..where((e) => e.id.equals(id))).watchSingleOrNull();

  Future<String> saveEvent({
    String? id,
    required String treeId,
    required String title,
    required EventType type,
    String? customLabel,
    String? date,
    String? location,
    String? description,
    bool remind = false,
    Map<String, String?> people = const {},
  }) async {
    if (title.trim().isEmpty) throw ValidationException('Please give the event a title.');
    return db.transaction(() async {
      final eid = id ?? newId();
      final data = FamilyEventsCompanion(
        id: Value(eid),
        treeId: Value(treeId),
        title: Value(title.trim()),
        type: Value(type),
        customLabel: Value(customLabel),
        date: Value(date),
        location: Value(location),
        description: Value(description),
        remind: Value(remind),
        updatedAt: Value(DateTime.now()),
      );
      if (id == null) {
        await db.into(db.familyEvents).insert(data);
      } else {
        await (db.update(db.familyEvents)..where((e) => e.id.equals(id))).write(data);
        await (db.delete(db.eventPersons)..where((p) => p.eventId.equals(id))).go();
      }
      for (final e in people.entries) {
        await db.into(db.eventPersons).insert(
            EventPersonsCompanion.insert(eventId: eid, personId: e.key, role: Value(e.value)),
            mode: InsertMode.insertOrIgnore);
      }
      return eid;
    });
  }

  Future<void> trashEvent(String id) async {
    final e = await (db.select(db.familyEvents)..where((x) => x.id.equals(id))).getSingleOrNull();
    if (e == null) return;
    await db.transaction(() async {
      await (db.update(db.familyEvents)..where((x) => x.id.equals(id)))
          .write(FamilyEventsCompanion(deletedAt: Value(DateTime.now())));
      await _trashRecord(e.treeId, TrashEntity.event, id, e.title);
    });
  }

  // ================================================================= media

  Stream<List<MediaAsset>> watchMedia(String treeId) => (db.select(db.mediaAssets)
        ..where((m) => m.treeId.equals(treeId) & m.deletedAt.isNull())
        ..orderBy([(m) => OrderingTerm.desc(m.createdAt)]))
      .watch();

  Stream<MediaAsset?> watchMediaAsset(String id) =>
      (db.select(db.mediaAssets)..where((m) => m.id.equals(id))).watchSingleOrNull();

  Future<MediaAsset?> mediaAsset(String id) =>
      (db.select(db.mediaAssets)..where((m) => m.id.equals(id))).getSingleOrNull();

  Stream<List<MediaPerson>> watchMediaPeople(String treeId) {
    final q = db.select(db.mediaPersons).join([
      innerJoin(db.mediaAssets, db.mediaAssets.id.equalsExp(db.mediaPersons.mediaId)),
    ])
      ..where(db.mediaAssets.treeId.equals(treeId));
    return q.watch().map((r) => r.map((x) => x.readTable(db.mediaPersons)).toList());
  }

  Stream<List<MediaEvent>> watchMediaEvents(String treeId) {
    final q = db.select(db.mediaEvents).join([
      innerJoin(db.mediaAssets, db.mediaAssets.id.equalsExp(db.mediaEvents.mediaId)),
    ])
      ..where(db.mediaAssets.treeId.equals(treeId));
    return q.watch().map((r) => r.map((x) => x.readTable(db.mediaEvents)).toList());
  }

  /// Imports a file from the device into app storage and records it.
  Future<String> importMedia(
    File file, {
    required String treeId,
    MediaKind? kind,
    String? caption,
    List<String> personIds = const [],
    List<String> eventIds = const [],
    String? albumId,
    String? originalName,
  }) async {
    final stored = await storage.importFile(file, treeId, originalName: originalName);
    final id = newId();
    final k = kind ?? (MediaStorage.isImagePath(file.path) ? MediaKind.photo : MediaKind.document);
    await db.transaction(() async {
      await db.into(db.mediaAssets).insert(MediaAssetsCompanion.insert(
            id: id,
            treeId: treeId,
            kind: Value(k),
            filePath: stored.relativePath,
            thumbPath: Value(stored.thumbRelativePath),
            originalName: Value(stored.originalName),
            mimeType: Value(stored.mimeType),
            width: Value(stored.width),
            height: Value(stored.height),
            sizeBytes: Value(stored.sizeBytes),
            caption: Value(caption),
          ));
      for (final p in personIds) {
        await db.into(db.mediaPersons).insert(MediaPersonsCompanion.insert(mediaId: id, personId: p),
            mode: InsertMode.insertOrIgnore);
      }
      for (final e in eventIds) {
        await db.into(db.mediaEvents).insert(MediaEventsCompanion.insert(mediaId: id, eventId: e),
            mode: InsertMode.insertOrIgnore);
      }
      if (albumId != null) await addToAlbum(albumId, [id]);
    });
    return id;
  }

  Future<void> updateMedia(String id, MediaAssetsCompanion data) =>
      (db.update(db.mediaAssets)..where((m) => m.id.equals(id)))
          .write(data.copyWith(updatedAt: Value(DateTime.now())));

  /// Tags one more person in a photo, leaving existing tags untouched.
  Future<void> addMediaPerson(String mediaId, String personId) => db
      .into(db.mediaPersons)
      .insert(MediaPersonsCompanion.insert(mediaId: mediaId, personId: personId), mode: InsertMode.insertOrIgnore);

  Future<void> setMediaPeople(String mediaId, Iterable<String> personIds) => db.transaction(() async {
        await (db.delete(db.mediaPersons)..where((m) => m.mediaId.equals(mediaId))).go();
        for (final p in personIds) {
          await db.into(db.mediaPersons).insert(MediaPersonsCompanion.insert(mediaId: mediaId, personId: p),
              mode: InsertMode.insertOrIgnore);
        }
      });

  Future<void> setMediaEvents(String mediaId, Iterable<String> eventIds) => db.transaction(() async {
        await (db.delete(db.mediaEvents)..where((m) => m.mediaId.equals(mediaId))).go();
        for (final e in eventIds) {
          await db.into(db.mediaEvents).insert(MediaEventsCompanion.insert(mediaId: mediaId, eventId: e),
              mode: InsertMode.insertOrIgnore);
        }
      });

  /// Rotates the image file and regenerates its thumbnail.
  Future<void> rotateMedia(MediaAsset m) async {
    await storage.rotate(m.filePath);
    final t = await storage.regenerateThumb(m.filePath, m.treeId);
    await storage.deleteFiles(null, m.thumbPath);
    await updateMedia(
        m.id,
        MediaAssetsCompanion(
          thumbPath: Value(t.$1),
          width: Value(t.$2),
          height: Value(t.$3),
          sizeBytes: Value(await File(AppPaths.I.resolve(m.filePath)).length()),
        ));
  }

  Future<void> cropMedia(MediaAsset m, int x, int y, int w, int h) async {
    await storage.crop(m.filePath, x, y, w, h);
    final t = await storage.regenerateThumb(m.filePath, m.treeId);
    await storage.deleteFiles(null, m.thumbPath);
    await updateMedia(
        m.id,
        MediaAssetsCompanion(
          thumbPath: Value(t.$1),
          width: Value(t.$2),
          height: Value(t.$3),
          sizeBytes: Value(await File(AppPaths.I.resolve(m.filePath)).length()),
        ));
  }

  /// Moves a photo to the trash. People keep their other photos; profile
  /// pictures pointing at it fall back to initials until restored.
  Future<void> trashMedia(String id) async {
    final m = await mediaAsset(id);
    if (m == null) return;
    await db.transaction(() async {
      await (db.update(db.mediaAssets)..where((x) => x.id.equals(id)))
          .write(MediaAssetsCompanion(deletedAt: Value(DateTime.now())));
      await _trashRecord(m.treeId, TrashEntity.media, id, m.caption ?? m.originalName ?? 'Photo');
    });
  }

  // ================================================================ albums

  Stream<List<Album>> watchAlbums(String treeId) => (db.select(db.albums)
        ..where((a) => a.treeId.equals(treeId) & a.deletedAt.isNull())
        ..orderBy([(a) => OrderingTerm.asc(a.sortOrder), (a) => OrderingTerm.asc(a.name)]))
      .watch();

  Stream<List<AlbumMediaEntry>> watchAlbumEntries(String treeId) {
    final q = db.select(db.albumMedia).join([
      innerJoin(db.albums, db.albums.id.equalsExp(db.albumMedia.albumId)),
    ])
      ..where(db.albums.treeId.equals(treeId));
    return q.watch().map((r) => r.map((x) => x.readTable(db.albumMedia)).toList());
  }

  Future<String> createAlbum(String treeId, String name, {String? description}) async {
    final id = newId();
    await db.into(db.albums).insert(
        AlbumsCompanion.insert(id: id, treeId: treeId, name: name.trim(), description: Value(description)));
    return id;
  }

  Future<void> updateAlbum(String id, {String? name, String? description, String? coverMediaId}) =>
      (db.update(db.albums)..where((a) => a.id.equals(id))).write(AlbumsCompanion(
        name: name == null ? const Value.absent() : Value(name.trim()),
        description: description == null ? const Value.absent() : Value(description),
        coverMediaId: coverMediaId == null ? const Value.absent() : Value(coverMediaId),
        updatedAt: Value(DateTime.now()),
      ));

  Future<void> addToAlbum(String albumId, Iterable<String> mediaIds) async {
    await db.batch((b) {
      for (final m in mediaIds) {
        b.insert(db.albumMedia, AlbumMediaCompanion.insert(albumId: albumId, mediaId: m),
            mode: InsertMode.insertOrIgnore);
      }
    });
  }

  Future<void> removeFromAlbum(String albumId, String mediaId) =>
      (db.delete(db.albumMedia)..where((a) => a.albumId.equals(albumId) & a.mediaId.equals(mediaId))).go();

  /// Deleting an album never deletes its photos.
  Future<void> trashAlbum(String id) async {
    final a = await (db.select(db.albums)..where((x) => x.id.equals(id))).getSingleOrNull();
    if (a == null) return;
    await db.transaction(() async {
      await (db.update(db.albums)..where((x) => x.id.equals(id)))
          .write(AlbumsCompanion(deletedAt: Value(DateTime.now())));
      await _trashRecord(a.treeId, TrashEntity.album, id, a.name);
    });
  }

  // =============================================================== stories

  Stream<List<Story>> watchStories(String treeId) => (db.select(db.stories)
        ..where((s) => s.treeId.equals(treeId) & s.deletedAt.isNull())
        ..orderBy([(s) => OrderingTerm.desc(s.updatedAt)]))
      .watch();

  Stream<Story?> watchStory(String id) =>
      (db.select(db.stories)..where((s) => s.id.equals(id))).watchSingleOrNull();

  Stream<List<StoryPerson>> watchStoryPeople(String treeId) {
    final q = db.select(db.storyPersons).join([
      innerJoin(db.stories, db.stories.id.equalsExp(db.storyPersons.storyId)),
    ])
      ..where(db.stories.treeId.equals(treeId));
    return q.watch().map((r) => r.map((x) => x.readTable(db.storyPersons)).toList());
  }

  Stream<List<StoryEvent>> watchStoryEvents(String treeId) {
    final q = db.select(db.storyEvents).join([
      innerJoin(db.stories, db.stories.id.equalsExp(db.storyEvents.storyId)),
    ])
      ..where(db.stories.treeId.equals(treeId));
    return q.watch().map((r) => r.map((x) => x.readTable(db.storyEvents)).toList());
  }

  Stream<List<StoryMediaEntry>> watchStoryMedia(String treeId) {
    final q = db.select(db.storyMedia).join([
      innerJoin(db.stories, db.stories.id.equalsExp(db.storyMedia.storyId)),
    ])
      ..where(db.stories.treeId.equals(treeId));
    return q.watch().map((r) => r.map((x) => x.readTable(db.storyMedia)).toList());
  }

  Stream<List<StoryTag>> watchStoryTags(String treeId) {
    final q = db.select(db.storyTags).join([
      innerJoin(db.stories, db.stories.id.equalsExp(db.storyTags.storyId)),
    ])
      ..where(db.stories.treeId.equals(treeId));
    return q.watch().map((r) => r.map((x) => x.readTable(db.storyTags)).toList());
  }

  Future<String> saveStory({
    String? id,
    required String treeId,
    required String title,
    required String body,
    String? historicalDate,
    String? sourceText,
    String? coverMediaId,
    bool isPrivate = false,
    List<String> personIds = const [],
    List<String> eventIds = const [],
    List<String> mediaIds = const [],
    List<String> tagIds = const [],
  }) async {
    if (title.trim().isEmpty) throw ValidationException('Please give the story a title.');
    return db.transaction(() async {
      final sid = id ?? newId();
      final data = StoriesCompanion(
        id: Value(sid),
        treeId: Value(treeId),
        title: Value(title.trim()),
        body: Value(body),
        historicalDate: Value(historicalDate),
        sourceText: Value(sourceText),
        coverMediaId: Value(coverMediaId),
        isPrivate: Value(isPrivate),
        updatedAt: Value(DateTime.now()),
      );
      if (id == null) {
        await db.into(db.stories).insert(data);
      } else {
        await (db.update(db.stories)..where((s) => s.id.equals(id))).write(data);
        await (db.delete(db.storyPersons)..where((x) => x.storyId.equals(id))).go();
        await (db.delete(db.storyEvents)..where((x) => x.storyId.equals(id))).go();
        await (db.delete(db.storyMedia)..where((x) => x.storyId.equals(id))).go();
        await (db.delete(db.storyTags)..where((x) => x.storyId.equals(id))).go();
      }
      for (final p in personIds) {
        await db.into(db.storyPersons).insert(StoryPersonsCompanion.insert(storyId: sid, personId: p),
            mode: InsertMode.insertOrIgnore);
      }
      for (final e in eventIds) {
        await db.into(db.storyEvents).insert(StoryEventsCompanion.insert(storyId: sid, eventId: e),
            mode: InsertMode.insertOrIgnore);
      }
      for (var i = 0; i < mediaIds.length; i++) {
        await db.into(db.storyMedia).insert(
            StoryMediaCompanion.insert(storyId: sid, mediaId: mediaIds[i], sortOrder: Value(i)),
            mode: InsertMode.insertOrIgnore);
      }
      for (final t in tagIds) {
        await db.into(db.storyTags).insert(StoryTagsCompanion.insert(storyId: sid, tagId: t),
            mode: InsertMode.insertOrIgnore);
      }
      return sid;
    });
  }

  Future<void> trashStory(String id) async {
    final s = await (db.select(db.stories)..where((x) => x.id.equals(id))).getSingleOrNull();
    if (s == null) return;
    await db.transaction(() async {
      await (db.update(db.stories)..where((x) => x.id.equals(id)))
          .write(StoriesCompanion(deletedAt: Value(DateTime.now())));
      await _trashRecord(s.treeId, TrashEntity.story, id, s.title);
    });
  }

  // =============================================================== sources

  Stream<List<Source>> watchSources(String treeId) => (db.select(db.sources)
        ..where((s) => s.treeId.equals(treeId) & s.deletedAt.isNull())
        ..orderBy([(s) => OrderingTerm.asc(s.title)]))
      .watch();

  Stream<List<Citation>> watchCitations(String treeId) {
    final q = db.select(db.citations).join([
      innerJoin(db.sources, db.sources.id.equalsExp(db.citations.sourceId)),
    ])
      ..where(db.sources.treeId.equals(treeId));
    return q.watch().map((r) => r.map((x) => x.readTable(db.citations)).toList());
  }

  Future<String> saveSource({
    String? id,
    required String treeId,
    required String title,
    SourceType type = SourceType.document,
    String? author,
    String? repository,
    String? date,
    String? notes,
    String? mediaId,
  }) async {
    if (title.trim().isEmpty) throw ValidationException('Please give the source a title.');
    final sid = id ?? newId();
    final data = SourcesCompanion(
      id: Value(sid),
      treeId: Value(treeId),
      title: Value(title.trim()),
      type: Value(type),
      author: Value(author),
      repository: Value(repository),
      date: Value(date),
      notes: Value(notes),
      mediaId: Value(mediaId),
      updatedAt: Value(DateTime.now()),
    );
    if (id == null) {
      await db.into(db.sources).insert(data);
    } else {
      await (db.update(db.sources)..where((s) => s.id.equals(id))).write(data);
    }
    return sid;
  }

  Future<void> trashSource(String id) async {
    final s = await (db.select(db.sources)..where((x) => x.id.equals(id))).getSingleOrNull();
    if (s == null) return;
    await db.transaction(() async {
      await (db.update(db.sources)..where((x) => x.id.equals(id)))
          .write(SourcesCompanion(deletedAt: Value(DateTime.now())));
      await _trashRecord(s.treeId, TrashEntity.source, id, s.title);
    });
  }

  Future<String> addCitation({
    required String sourceId,
    required String entityType,
    required String entityId,
    String fact = 'general',
    String? detail,
    int confidence = 2,
  }) async {
    final id = newId();
    await db.into(db.citations).insert(CitationsCompanion.insert(
          id: id,
          sourceId: sourceId,
          entityType: entityType,
          entityId: entityId,
          fact: Value(fact),
          detail: Value(detail),
          confidence: Value(confidence),
        ));
    return id;
  }

  Future<void> deleteCitation(String id) => (db.delete(db.citations)..where((c) => c.id.equals(id))).go();

  // ============================================================= reminders

  Stream<List<Reminder>> watchReminders(String treeId) => (db.select(db.reminders)
        ..where((r) => r.treeId.equals(treeId))
        ..orderBy([(r) => OrderingTerm.asc(r.date)]))
      .watch();

  Future<String> saveReminder({
    String? id,
    required String treeId,
    required String title,
    required DateTime date,
    ReminderRepeat repeat = ReminderRepeat.none,
    String? notes,
    String? personId,
    bool enabled = true,
  }) async {
    if (title.trim().isEmpty) throw ValidationException('Please give the reminder a title.');
    final rid = id ?? newId();
    final data = RemindersCompanion(
      id: Value(rid),
      treeId: Value(treeId),
      title: Value(title.trim()),
      date: Value(date),
      repeat: Value(repeat),
      notes: Value(notes),
      personId: Value(personId),
      enabled: Value(enabled),
      updatedAt: Value(DateTime.now()),
    );
    if (id == null) {
      await db.into(db.reminders).insert(data);
    } else {
      await (db.update(db.reminders)..where((r) => r.id.equals(id))).write(data);
    }
    return rid;
  }

  Future<void> deleteReminder(String id) => (db.delete(db.reminders)..where((r) => r.id.equals(id))).go();

  // ================================================================ shared

  Future<void> _trashRecord(String treeId, TrashEntity type, String id, String label) =>
      db.into(db.deletionRecords).insert(DeletionRecordsCompanion.insert(
            id: newId(),
            treeId: Value(treeId),
            entityType: type,
            entityId: id,
            label: label,
          ));
}
