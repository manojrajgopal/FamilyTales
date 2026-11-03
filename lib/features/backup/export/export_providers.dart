import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'export_privacy.dart';

/// Sharing filters chosen on the Export screen; also used by the PDF
/// preview so both stay in sync for the session.
final exportPrivacyProvider =
    NotifierProvider<ExportPrivacyController, ExportPrivacy>(ExportPrivacyController.new);

class ExportPrivacyController extends Notifier<ExportPrivacy> {
  @override
  ExportPrivacy build() => ExportPrivacy.none;

  void set(ExportPrivacy value) => state = value;
}
