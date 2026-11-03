/// Privacy filters for exports that leave the device (GEDCOM, JSON, CSV,
/// PDF). Pure Dart.
library;

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';

/// Which details to remove before sharing. When [enabled] is false nothing
/// is filtered (a complete, personal export).
class ExportPrivacy {
  const ExportPrivacy({
    this.enabled = false,
    this.hideLivingBirthDates = true,
    this.hideContactDetails = true,
    this.hidePersonalNotes = true,
    this.excludePrivatePeople = true,
    this.hidePrivateFieldsAndMedia = true,
    this.anonymizeLivingInGedcom = true,
  });

  /// Full export, nothing hidden.
  static const none = ExportPrivacy();

  /// Every filter on.
  static const public = ExportPrivacy(enabled: true);

  final bool enabled;
  final bool hideLivingBirthDates;
  final bool hideContactDetails;
  final bool hidePersonalNotes;
  final bool excludePrivatePeople;
  final bool hidePrivateFieldsAndMedia;

  /// GEDCOM only: living people are written as "Living" with no dates,
  /// places, notes or events (common genealogy-sharing practice).
  final bool anonymizeLivingInGedcom;

  bool get hidesLivingBirth => enabled && hideLivingBirthDates;
  bool get hidesContact => enabled && hideContactDetails;
  bool get hidesNotes => enabled && hidePersonalNotes;
  bool get excludesPrivate => enabled && excludePrivatePeople;
  bool get hidesPrivateExtras => enabled && hidePrivateFieldsAndMedia;
  bool get anonymizesLiving => enabled && anonymizeLivingInGedcom;

  ExportPrivacy copyWith({
    bool? enabled,
    bool? hideLivingBirthDates,
    bool? hideContactDetails,
    bool? hidePersonalNotes,
    bool? excludePrivatePeople,
    bool? hidePrivateFieldsAndMedia,
    bool? anonymizeLivingInGedcom,
  }) =>
      ExportPrivacy(
        enabled: enabled ?? this.enabled,
        hideLivingBirthDates: hideLivingBirthDates ?? this.hideLivingBirthDates,
        hideContactDetails: hideContactDetails ?? this.hideContactDetails,
        hidePersonalNotes: hidePersonalNotes ?? this.hidePersonalNotes,
        excludePrivatePeople: excludePrivatePeople ?? this.excludePrivatePeople,
        hidePrivateFieldsAndMedia: hidePrivateFieldsAndMedia ?? this.hidePrivateFieldsAndMedia,
        anonymizeLivingInGedcom: anonymizeLivingInGedcom ?? this.anonymizeLivingInGedcom,
      );

  /// Short description for UI summaries.
  String get summary {
    if (!enabled) return 'Complete export – nothing hidden';
    final parts = <String>[
      if (hideLivingBirthDates) 'living birth dates',
      if (hideContactDetails) 'contact details',
      if (hidePersonalNotes) 'personal notes',
      if (excludePrivatePeople) 'private people',
      if (hidePrivateFieldsAndMedia) 'private fields & photos',
    ];
    return parts.isEmpty ? 'Sharing filters on' : 'Hides ${parts.join(', ')}';
  }

  /// Whether [p] may appear in the export at all.
  bool includes(Person p) => !(excludesPrivate && p.isPrivate);

  /// A copy of [p] with filtered fields removed.
  Person apply(Person p) {
    var out = p;
    if (hidesLivingBirth && p.isLiving) {
      out = out.copyWith(birthDate: const Value(null), birthNotes: const Value(null));
    }
    if (hidesContact) {
      out = out.copyWith(email: const Value(null), phone: const Value(null), address: const Value(null));
    }
    if (hidesNotes) {
      out = out.copyWith(
          notes: const Value(null), birthNotes: const Value(null), deathNotes: const Value(null));
    }
    return out;
  }

  bool includesField(CustomField f) => !(hidesPrivateExtras && f.isPrivate);
  bool includesMedia(MediaAsset m) => !(hidesPrivateExtras && m.isPrivate);
  bool includesStory(Story s) => !(hidesPrivateExtras && s.isPrivate);
}
