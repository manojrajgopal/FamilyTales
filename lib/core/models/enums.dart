/// Domain enums. Their `name` is persisted in SQLite, so never rename values
/// without a migration.
library;

enum Gender {
  male('Male'),
  female('Female'),
  nonBinary('Non-binary'),
  other('Other'),
  unknown('Not specified');

  const Gender(this.label);
  final String label;
}

/// How a parent is related to a child. Multiple parent links with different
/// types are allowed (e.g. two biological parents plus a step-parent).
enum ParentType {
  biological('Biological'),
  adoptive('Adoptive'),
  step('Step'),
  foster('Foster'),
  guardian('Guardian'),
  unknown('Unspecified');

  const ParentType(this.label);
  final String label;

  /// Whether this link counts as a "blood" line for kinship calculations.
  bool get isBlood => this == biological || this == unknown;

  /// Whether this link is drawn as a main lineage connector in the tree.
  bool get isLineage => this != guardian && this != foster;
}

enum PartnerType {
  marriage('Marriage'),
  civilUnion('Civil union'),
  partner('Partner'),
  engaged('Engaged');

  const PartnerType(this.label);
  final String label;
}

enum PartnerStatus {
  current('Together'),
  divorced('Divorced'),
  separated('Separated'),
  widowed('Widowed'),
  annulled('Annulled'),
  ended('Ended');

  const PartnerStatus(this.label);
  final String label;

  bool get isActive => this == current;
}

enum EventType {
  birth('Birth'),
  baptism('Baptism'),
  namingCeremony('Naming ceremony'),
  adoption('Adoption'),
  engagement('Engagement'),
  marriage('Marriage'),
  divorce('Divorce'),
  separation('Separation'),
  graduation('Graduation'),
  employment('Employment'),
  retirement('Retirement'),
  migration('Migration'),
  relocation('Relocation'),
  militaryService('Military service'),
  award('Award'),
  achievement('Achievement'),
  death('Death'),
  burial('Burial'),
  memorial('Memorial'),
  familyReunion('Family reunion'),
  custom('Custom');

  const EventType(this.label);
  final String label;
}

enum MediaKind { photo, document }

enum SourceType {
  certificate('Certificate'),
  photograph('Historical photograph'),
  letter('Letter'),
  document('Document'),
  familyRecord('Family record'),
  oralHistory('Oral history'),
  census('Census record'),
  book('Book / publication'),
  other('Other');

  const SourceType(this.label);
  final String label;
}

enum CustomFieldType {
  text('Text'),
  number('Number'),
  date('Date'),
  yesNo('Yes / No');

  const CustomFieldType(this.label);
  final String label;
}

enum ReminderRepeat {
  none('Once'),
  yearly('Every year'),
  monthly('Every month');

  const ReminderRepeat(this.label);
  final String label;
}

/// Entities that can be moved to the trash.
enum TrashEntity {
  person('Person'),
  event('Event'),
  media('Photo'),
  story('Story'),
  source('Source'),
  album('Album'),
  tree('Family tree'),
  relationship('Relationship');

  const TrashEntity(this.label);
  final String label;
}
