import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Static facts about this build, shown on the About and Settings screens.
/// Keep in sync with `version:` in pubspec.yaml.
abstract final class AppInfo {
  static const name = 'Family Tales';
  static const version = '1.0.0';
  static const build = 1;
  static const tagline = 'Your family. Your story. Your roots.';

  /// "Version 1.0.0 (build 1)"
  static const versionLabel = 'Version $version (build $build)';

  /// Short form used in subtitles: "1.0.0 (1)".
  static const shortVersion = '$version ($build)';

  static const copyright = '© 2026 Family Tales';
}

/// Registers licenses for bundled assets that are not Dart packages (the
/// Inter typeface and the Phosphor icon font) with [LicenseRegistry]. Safe
/// to call more than once.
abstract final class AppLicenses {
  static bool _registered = false;

  static const _bundled = [
    ('Inter typeface', 'assets/fonts/OFL-Inter.txt'),
    ('Phosphor Icons', 'assets/fonts/MIT-Phosphor.txt'),
  ];

  static void ensureRegistered() {
    if (_registered) return;
    _registered = true;
    LicenseRegistry.addLicense(() async* {
      for (final (package, asset) in _bundled) {
        try {
          final text = await rootBundle.loadString(asset);
          yield LicenseEntryWithLineBreaks([package], text);
        } catch (_) {
          // Asset missing from this build: skip rather than break the list.
        }
      }
    });
  }
}

/// One package (or bundled asset) and all of its license texts.
@immutable
class PackageLicenses {
  const PackageLicenses(this.package, this.texts);
  final String package;
  final List<String> texts;
}

/// Collects [LicenseRegistry.licenses] grouped by package, sorted by name.
Future<List<PackageLicenses>> collectLicenses() async {
  AppLicenses.ensureRegistered();
  final byPackage = <String, List<String>>{};
  await for (final entry in LicenseRegistry.licenses) {
    final text = entry.paragraphs
        .map((p) => p.indent > 0 ? '${'  ' * p.indent}${p.text}' : p.text)
        .join('\n\n');
    for (final pkg in entry.packages) {
      (byPackage[pkg] ??= []).add(text);
    }
  }
  final list = [
    for (final e in byPackage.entries) PackageLicenses(e.key, e.value),
  ]..sort((a, b) => a.package.toLowerCase().compareTo(b.package.toLowerCase()));
  return list;
}
