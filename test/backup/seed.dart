import 'dart:io';

import 'package:drift/drift.dart';
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/core/models/fuzzy_date.dart';
import 'package:family_tales/core/repositories/content_repository.dart';
import 'package:family_tales/core/repositories/family_repository.dart';
import 'package:family_tales/core/services/app_paths.dart';
import 'package:path/path.dart' as p;

/// Shared fixture: a three-person tree with a partnership, biological and
/// adoptive parent links, a photo (file + thumbnail), an event, a source with
/// citations, a reminder, a tag and a custom field value.
class Seed {
  Seed(this.treeId, this.grandpa, this.child, this.mediaId, this.fileBytes);
  final String treeId;
  final String grandpa;
  final String child;
  final String mediaId;
  final Uint8List fileBytes;
}

Future<Seed> seedTree(AppDatabase db, {String name = 'Smith family'}) async {
  final fam = FamilyRepository(db);
  final content = ContentRepository(db);
  final tree = await fam.createTree(name);
  Future<String> person(String first, String last, {String? birth, bool living = true, Gender g = Gender.unknown}) =>
      fam.createPerson(PersonsCompanion.insert(
        id: newId(),
        treeId: tree,
        firstName: Value(first),
        lastName: Value(last),
        gender: Value(g),
        birthDate: Value(birth),
        isLiving: Value(living),
      ));
  final grandpa = await person('Arthur', 'Smith',
      birth: FuzzyDate(qualifier: DateQualifier.about, year: 1920).serialize(),
      living: false,
      g: Gender.male);
  final grandma = await person('Edith', 'Smith', birth: FuzzyDate.ymd(1925, 3, 12).serialize(), living: false, g: Gender.female);
  final child = await person('Paul', 'Smith', birth: FuzzyDate.ymd(1950).serialize(), g: Gender.male);
  await fam.addPartnership(a: grandpa, b: grandma, start: FuzzyDate.ymd(1948, 6));
  await fam.addParent(childId: child, parentId: grandpa);
  await fam.addParent(childId: child, parentId: grandma, type: ParentType.adoptive);
  await fam.updateTree(tree, homePersonId: child);

  // A media file + thumbnail on disk.
  final dir = AppPaths.I.mediaDir(tree)..createSync(recursive: true);
  AppPaths.I.thumbDir(tree).createSync(recursive: true);
  final bytes = Uint8List.fromList(List.generate(300000, (i) => (i * 7) % 251));
  final file = File(p.join(dir.path, 'photo1.jpg'))..writeAsBytesSync(bytes);
  final thumb = File(p.join(AppPaths.I.thumbDir(tree).path, 'photo1.jpg'))..writeAsBytesSync([1, 2, 3]);
  final mediaId = newId();
  await db.into(db.mediaAssets).insert(MediaAssetsCompanion.insert(
        id: mediaId,
        treeId: tree,
        filePath: AppPaths.I.relative(file.path),
        thumbPath: Value(AppPaths.I.relative(thumb.path)),
        caption: const Value('Wedding'),
      ));
  await db.into(db.mediaPersons).insert(MediaPersonsCompanion.insert(mediaId: mediaId, personId: grandpa));
  await fam.setProfilePhoto(grandpa, mediaId);

  final ev = await content.saveEvent(
      treeId: tree, title: 'Graduation', type: EventType.graduation, people: {child: 'graduate'});
  final src = await content.saveSource(treeId: tree, title: 'Birth certificate');
  await content.addCitation(sourceId: src, entityType: 'person', entityId: child, fact: 'birth');
  await content.addCitation(sourceId: src, entityType: 'event', entityId: ev);
  await content.saveReminder(treeId: tree, title: 'Call Paul', date: DateTime(2030, 1, 2), personId: child);
  final tag = await fam.ensureTag(tree, 'Veteran');
  await fam.tagPeople([grandpa], tag);
  final field = await fam.addCustomField(tree, 'Religion', CustomFieldType.text);
  await fam.setCustomValue(grandpa, field, 'Anglican');
  return Seed(tree, grandpa, child, mediaId, bytes);
}

