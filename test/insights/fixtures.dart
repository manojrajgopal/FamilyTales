// Small builders for the generated drift data classes used by the insights,
// search, branch and duplicate-detection tests.
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/features/family/domain/family_graph.dart';

final t0 = DateTime(2020, 1, 1);
const treeId = 'tree';

Person person(
  String id, {
  String first = '',
  String? middle,
  String? last,
  String? fullName,
  String? birthName,
  String? nickname,
  Gender gender = Gender.unknown,
  String? birth,
  String? birthPlace,
  bool living = true,
  String? death,
  String? deathPlace,
  DateTime? createdAt,
}) =>
    Person(
      createdAt: createdAt ?? t0,
      updatedAt: t0,
      id: id,
      treeId: treeId,
      firstName: first,
      middleName: middle,
      lastName: last,
      fullName: fullName,
      birthName: birthName,
      nickname: nickname,
      gender: gender,
      birthDate: birth,
      birthPlace: birthPlace,
      isLiving: living,
      deathDate: death,
      deathPlace: deathPlace,
      isPrivate: false,
      isArchived: false,
    );

ParentChildLink link(String parent, String child, {ParentType type = ParentType.biological}) =>
    ParentChildLink(
      createdAt: t0,
      updatedAt: t0,
      id: '$parent>$child',
      treeId: treeId,
      parentId: parent,
      childId: child,
      type: type,
    );

Partnership couple(
  String a,
  String b, {
  String? start,
  PartnerStatus status = PartnerStatus.current,
  PartnerType type = PartnerType.marriage,
}) =>
    Partnership(
      createdAt: t0,
      updatedAt: t0,
      id: '$a&$b',
      treeId: treeId,
      personAId: a,
      personBId: b,
      type: type,
      status: status,
      startDate: start,
    );

FamilyEvent event(
  String id,
  String title, {
  EventType type = EventType.custom,
  String? date,
  String? location,
  bool remind = false,
}) =>
    FamilyEvent(
      createdAt: t0,
      updatedAt: t0,
      id: id,
      treeId: treeId,
      title: title,
      type: type,
      date: date,
      location: location,
      remind: remind,
    );

MediaAsset media(String id, {MediaKind kind = MediaKind.photo}) => MediaAsset(
      createdAt: t0,
      updatedAt: t0,
      id: id,
      treeId: treeId,
      kind: kind,
      filePath: 'media/$id.jpg',
      sizeBytes: 0,
      isPrivate: false,
    );

Story story(String id, String title, {String body = '', String? date}) => Story(
      createdAt: t0,
      updatedAt: t0,
      id: id,
      treeId: treeId,
      title: title,
      body: body,
      historicalDate: date,
      isPrivate: false,
    );

FamilyBranch branch(String id, String name, {String? root, String? description}) => FamilyBranch(
      createdAt: t0,
      updatedAt: t0,
      id: id,
      treeId: treeId,
      name: name,
      rootPersonId: root,
      description: description,
    );

Source source(String id, String title, {String? author, SourceType type = SourceType.document}) => Source(
      createdAt: t0,
      updatedAt: t0,
      id: id,
      treeId: treeId,
      title: title,
      type: type,
      author: author,
    );

FamilyGraph graphOf(
  List<Person> people, {
  List<ParentChildLink> links = const [],
  List<Partnership> couples = const [],
}) =>
    FamilyGraph(persons: people, parentLinks: links, partnerships: couples);
