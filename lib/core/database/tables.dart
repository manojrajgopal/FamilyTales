import 'package:drift/drift.dart';

import '../models/enums.dart';

// All primary keys are stable UUID v4 strings so that backups, merges and
// GEDCOM round-trips never collide. Every mutable record keeps created/updated
// timestamps; records that can be moved to the trash carry `deletedAt`.
//
// Dates of historical facts are stored as serialised FuzzyDate strings
// (see core/models/fuzzy_date.dart) – never as fake exact DateTimes.

mixin TimestampColumns on Table {
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

@DataClassName('FamilyTree')
class FamilyTrees extends Table with TimestampColumns {
  TextColumn get id => text()();
  TextColumn get name => text().withLength(min: 1, max: 120)();
  TextColumn get description => text().nullable()();

  /// The "home" person used as default focus and for relationship labels.
  TextColumn get homePersonId => text().nullable()();
  TextColumn get coverMediaId => text().nullable()();
  BoolColumn get isExample => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('Person')
@TableIndex(name: 'idx_persons_tree', columns: {#treeId})
@TableIndex(name: 'idx_persons_last_name', columns: {#lastName})
class Persons extends Table with TimestampColumns {
  TextColumn get id => text()();
  TextColumn get treeId =>
      text().references(FamilyTrees, #id, onDelete: KeyAction.cascade)();

  // Names
  TextColumn get firstName => text().withDefault(const Constant(''))();
  TextColumn get middleName => text().nullable()();
  TextColumn get lastName => text().nullable()();

  /// Optional override of the display name (otherwise first+middle+last).
  TextColumn get fullName => text().nullable()();
  TextColumn get birthName => text().nullable()();
  TextColumn get nickname => text().nullable()();
  TextColumn get gender =>
      textEnum<Gender>().withDefault(Constant(Gender.unknown.name))();
  TextColumn get pronouns => text().nullable()();
  TextColumn get profileMediaId => text().nullable()();

  // Birth
  TextColumn get birthDate => text().nullable()();
  TextColumn get birthPlace => text().nullable()();
  TextColumn get birthCountry => text().nullable()();
  TextColumn get birthNotes => text().nullable()();

  // Death
  BoolColumn get isLiving => boolean().withDefault(const Constant(true))();
  TextColumn get deathDate => text().nullable()();
  TextColumn get deathPlace => text().nullable()();
  TextColumn get causeOfDeath => text().nullable()();
  TextColumn get burialPlace => text().nullable()();
  TextColumn get deathNotes => text().nullable()();

  // Additional
  TextColumn get occupation => text().nullable()();
  TextColumn get education => text().nullable()();
  TextColumn get nationality => text().nullable()();
  TextColumn get languages => text().nullable()();
  TextColumn get biography => text().nullable()();
  TextColumn get interests => text().nullable()();
  TextColumn get achievements => text().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get address => text().nullable()();

  /// Hidden from "public" exports when the user requests privacy filtering.
  BoolColumn get isPrivate => boolean().withDefault(const Constant(false))();
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Explicit parent → child edge. Siblings, grandparents, cousins etc. are
/// derived by graph traversal and never stored.
@DataClassName('ParentChildLink')
@TableIndex(name: 'idx_pc_parent', columns: {#parentId})
@TableIndex(name: 'idx_pc_child', columns: {#childId})
@TableIndex(name: 'idx_pc_tree', columns: {#treeId})
class ParentChildLinks extends Table with TimestampColumns {
  TextColumn get id => text()();
  TextColumn get treeId =>
      text().references(FamilyTrees, #id, onDelete: KeyAction.cascade)();
  TextColumn get parentId =>
      text().references(Persons, #id, onDelete: KeyAction.cascade)();
  TextColumn get childId =>
      text().references(Persons, #id, onDelete: KeyAction.cascade)();
  TextColumn get type =>
      textEnum<ParentType>().withDefault(Constant(ParentType.biological.name))();
  TextColumn get startDate => text().nullable()();
  TextColumn get endDate => text().nullable()();
  TextColumn get notes => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
        {parentId, childId},
      ];
}

/// A couple: marriage, civil union, partnership or engagement.
@DataClassName('Partnership')
@TableIndex(name: 'idx_partner_a', columns: {#personAId})
@TableIndex(name: 'idx_partner_b', columns: {#personBId})
@TableIndex(name: 'idx_partner_tree', columns: {#treeId})
class Partnerships extends Table with TimestampColumns {
  TextColumn get id => text()();
  TextColumn get treeId =>
      text().references(FamilyTrees, #id, onDelete: KeyAction.cascade)();
  TextColumn get personAId =>
      text().references(Persons, #id, onDelete: KeyAction.cascade)();
  TextColumn get personBId =>
      text().references(Persons, #id, onDelete: KeyAction.cascade)();
  TextColumn get type =>
      textEnum<PartnerType>().withDefault(Constant(PartnerType.marriage.name))();
  TextColumn get status => textEnum<PartnerStatus>()
      .withDefault(Constant(PartnerStatus.current.name))();
  TextColumn get startDate => text().nullable()();
  TextColumn get endDate => text().nullable()();
  TextColumn get place => text().nullable()();
  TextColumn get notes => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// A named family branch, e.g. "Paternal line". Membership is the union of
/// the descendants of [rootPersonId] (if set) and explicit [PersonBranches].
@DataClassName('FamilyBranch')
class FamilyBranches extends Table with TimestampColumns {
  TextColumn get id => text()();
  TextColumn get treeId =>
      text().references(FamilyTrees, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();
  TextColumn get rootPersonId => text().nullable()();
  IntColumn get colorValue => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('PersonBranch')
class PersonBranches extends Table {
  TextColumn get personId =>
      text().references(Persons, #id, onDelete: KeyAction.cascade)();
  TextColumn get branchId =>
      text().references(FamilyBranches, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {personId, branchId};
}

@DataClassName('FamilyEvent')
@TableIndex(name: 'idx_events_tree', columns: {#treeId})
class FamilyEvents extends Table with TimestampColumns {
  TextColumn get id => text()();
  TextColumn get treeId =>
      text().references(FamilyTrees, #id, onDelete: KeyAction.cascade)();
  TextColumn get title => text()();
  TextColumn get type =>
      textEnum<EventType>().withDefault(Constant(EventType.custom.name))();
  TextColumn get customLabel => text().nullable()();
  TextColumn get date => text().nullable()();
  TextColumn get location => text().nullable()();
  TextColumn get description => text().nullable()();

  /// Show this event as a yearly reminder in the calendar.
  BoolColumn get remind => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('EventPerson')
@TableIndex(name: 'idx_event_person_person', columns: {#personId})
class EventPersons extends Table {
  TextColumn get eventId =>
      text().references(FamilyEvents, #id, onDelete: KeyAction.cascade)();
  TextColumn get personId =>
      text().references(Persons, #id, onDelete: KeyAction.cascade)();
  TextColumn get role => text().nullable()();

  @override
  Set<Column> get primaryKey => {eventId, personId};
}

/// Photos and documents. Files live under the app documents directory; only
/// relative paths and metadata are stored here.
@DataClassName('MediaAsset')
@TableIndex(name: 'idx_media_tree', columns: {#treeId})
class MediaAssets extends Table with TimestampColumns {
  TextColumn get id => text()();
  TextColumn get treeId =>
      text().references(FamilyTrees, #id, onDelete: KeyAction.cascade)();
  TextColumn get kind =>
      textEnum<MediaKind>().withDefault(Constant(MediaKind.photo.name))();
  TextColumn get filePath => text()();
  TextColumn get thumbPath => text().nullable()();
  TextColumn get originalName => text().nullable()();
  TextColumn get mimeType => text().nullable()();
  IntColumn get width => integer().nullable()();
  IntColumn get height => integer().nullable()();
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();
  TextColumn get caption => text().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get date => text().nullable()();
  TextColumn get location => text().nullable()();
  TextColumn get category => text().nullable()();
  BoolColumn get isPrivate => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MediaPerson')
@TableIndex(name: 'idx_media_person_person', columns: {#personId})
class MediaPersons extends Table {
  TextColumn get mediaId =>
      text().references(MediaAssets, #id, onDelete: KeyAction.cascade)();
  TextColumn get personId =>
      text().references(Persons, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {mediaId, personId};
}

@DataClassName('MediaEvent')
class MediaEvents extends Table {
  TextColumn get mediaId =>
      text().references(MediaAssets, #id, onDelete: KeyAction.cascade)();
  TextColumn get eventId =>
      text().references(FamilyEvents, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {mediaId, eventId};
}

@DataClassName('Album')
class Albums extends Table with TimestampColumns {
  TextColumn get id => text()();
  TextColumn get treeId =>
      text().references(FamilyTrees, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();
  TextColumn get coverMediaId => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AlbumMediaEntry')
class AlbumMedia extends Table {
  TextColumn get albumId =>
      text().references(Albums, #id, onDelete: KeyAction.cascade)();
  TextColumn get mediaId =>
      text().references(MediaAssets, #id, onDelete: KeyAction.cascade)();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {albumId, mediaId};
}

@DataClassName('Story')
@TableIndex(name: 'idx_stories_tree', columns: {#treeId})
class Stories extends Table with TimestampColumns {
  TextColumn get id => text()();
  TextColumn get treeId =>
      text().references(FamilyTrees, #id, onDelete: KeyAction.cascade)();
  TextColumn get title => text()();

  /// Lightweight markdown (headings, bold, italic, quotes, lists).
  TextColumn get body => text().withDefault(const Constant(''))();
  TextColumn get historicalDate => text().nullable()();
  TextColumn get sourceText => text().nullable()();
  TextColumn get coverMediaId => text().nullable()();
  BoolColumn get isPrivate => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('StoryPerson')
@TableIndex(name: 'idx_story_person_person', columns: {#personId})
class StoryPersons extends Table {
  TextColumn get storyId =>
      text().references(Stories, #id, onDelete: KeyAction.cascade)();
  TextColumn get personId =>
      text().references(Persons, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {storyId, personId};
}

@DataClassName('StoryEvent')
class StoryEvents extends Table {
  TextColumn get storyId =>
      text().references(Stories, #id, onDelete: KeyAction.cascade)();
  TextColumn get eventId =>
      text().references(FamilyEvents, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {storyId, eventId};
}

@DataClassName('StoryMediaEntry')
class StoryMedia extends Table {
  TextColumn get storyId =>
      text().references(Stories, #id, onDelete: KeyAction.cascade)();
  TextColumn get mediaId =>
      text().references(MediaAssets, #id, onDelete: KeyAction.cascade)();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {storyId, mediaId};
}

/// Evidence: certificates, letters, oral history references…
@DataClassName('Source')
class Sources extends Table with TimestampColumns {
  TextColumn get id => text()();
  TextColumn get treeId =>
      text().references(FamilyTrees, #id, onDelete: KeyAction.cascade)();
  TextColumn get title => text()();
  TextColumn get type =>
      textEnum<SourceType>().withDefault(Constant(SourceType.document.name))();
  TextColumn get author => text().nullable()();
  TextColumn get repository => text().nullable()();
  TextColumn get date => text().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get mediaId => text().nullable()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Links a [Source] to a specific fact (e.g. a person's birth, an event).
@DataClassName('Citation')
@TableIndex(name: 'idx_citation_entity', columns: {#entityId})
class Citations extends Table with TimestampColumns {
  TextColumn get id => text()();
  TextColumn get sourceId =>
      text().references(Sources, #id, onDelete: KeyAction.cascade)();

  /// 'person' | 'event' | 'partnership' | 'parentChild' | 'story'
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();

  /// 'general' | 'name' | 'birth' | 'death' | 'marriage' | free text
  TextColumn get fact => text().withDefault(const Constant('general'))();
  TextColumn get detail => text().nullable()();

  /// 0 = unreliable … 3 = primary evidence.
  IntColumn get confidence => integer().withDefault(const Constant(2))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('CustomField')
class CustomFields extends Table with TimestampColumns {
  TextColumn get id => text()();
  TextColumn get treeId =>
      text().references(FamilyTrees, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  TextColumn get fieldType => textEnum<CustomFieldType>()
      .withDefault(Constant(CustomFieldType.text.name))();
  BoolColumn get isPrivate => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('PersonCustomValue')
class PersonCustomValues extends Table {
  TextColumn get personId =>
      text().references(Persons, #id, onDelete: KeyAction.cascade)();
  TextColumn get fieldId =>
      text().references(CustomFields, #id, onDelete: KeyAction.cascade)();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {personId, fieldId};
}

/// User-created reminders. Birthdays / anniversaries / memorials are derived
/// from people and partnerships and are not duplicated here.
@DataClassName('Reminder')
class Reminders extends Table with TimestampColumns {
  TextColumn get id => text()();
  TextColumn get treeId =>
      text().references(FamilyTrees, #id, onDelete: KeyAction.cascade)();
  TextColumn get title => text()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get date => dateTime()();
  TextColumn get repeat =>
      textEnum<ReminderRepeat>().withDefault(Constant(ReminderRepeat.none.name))();
  TextColumn get personId => text().nullable()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('Tag')
class Tags extends Table {
  TextColumn get id => text()();
  TextColumn get treeId =>
      text().references(FamilyTrees, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  IntColumn get colorValue => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('PersonTag')
class PersonTags extends Table {
  TextColumn get personId =>
      text().references(Persons, #id, onDelete: KeyAction.cascade)();
  TextColumn get tagId =>
      text().references(Tags, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {personId, tagId};
}

@DataClassName('StoryTag')
class StoryTags extends Table {
  TextColumn get storyId =>
      text().references(Stories, #id, onDelete: KeyAction.cascade)();
  TextColumn get tagId =>
      text().references(Tags, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {storyId, tagId};
}

/// Trash log. Soft-deleted rows keep `deletedAt`; this table lists them for
/// the Trash screen and stores JSON snapshots for hard-deleted relationships
/// so they can be undone.
@DataClassName('DeletionRecord')
class DeletionRecords extends Table {
  TextColumn get id => text()();
  TextColumn get treeId => text().nullable()();
  TextColumn get entityType => textEnum<TrashEntity>()();
  TextColumn get entityId => text()();
  TextColumn get label => text()();
  TextColumn get payload => text().nullable()();
  DateTimeColumn get deletedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// History of backups created / restored on this device.
@DataClassName('BackupRecord')
class BackupRecords extends Table {
  TextColumn get id => text()();

  /// 'backup' | 'restore' | 'export' | 'import'
  TextColumn get kind => text()();
  TextColumn get fileName => text()();
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();
  BoolColumn get encrypted => boolean().withDefault(const Constant(false))();
  TextColumn get summary => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AppSetting')
class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
