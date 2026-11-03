import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Locations of all on-device data. Everything lives inside the app's
/// private documents directory:
///
/// ```
/// <documents>/family_tales/
///   family_tales.db          encrypted SQLite database
///   media/<treeId>/          original photos & documents
///   media/<treeId>/thumbs/   generated thumbnails
/// ```
class AppPaths {
  AppPaths._(this.root, this.temp);

  static AppPaths? _instance;
  static AppPaths get I {
    final i = _instance;
    if (i == null) throw StateError('AppPaths not initialised');
    return i;
  }

  static bool get isReady => _instance != null;

  final Directory root;
  final Directory temp;

  static Future<AppPaths> init() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docs.path, 'family_tales'));
    await root.create(recursive: true);
    final tmp = Directory(p.join((await getTemporaryDirectory()).path, 'family_tales'));
    await tmp.create(recursive: true);
    final paths = AppPaths._(root, tmp);
    _instance = paths;
    await _excludeFromDeviceBackup(root.path);
    return paths;
  }

  /// For tests.
  static void initForTest(Directory root) {
    _instance = AppPaths._(root, Directory(p.join(root.path, 'tmp'))..createSync(recursive: true));
  }

  File get databaseFile => File(p.join(root.path, 'family_tales.db'));
  Directory get mediaRoot => Directory(p.join(root.path, 'media'));

  Directory mediaDir(String treeId) => Directory(p.join(mediaRoot.path, treeId));
  Directory thumbDir(String treeId) => Directory(p.join(mediaRoot.path, treeId, 'thumbs'));

  /// Converts a stored relative path to an absolute one.
  String resolve(String relative) => p.join(root.path, relative);

  String relative(String absolute) => p.relative(absolute, from: root.path);

  Directory exportsDir() {
    final d = Directory(p.join(temp.path, 'exports'));
    d.createSync(recursive: true);
    return d;
  }

  /// Keeps the family data out of iCloud device backups (iOS). Android
  /// excludes it through the manifest's data-extraction rules.
  static Future<void> _excludeFromDeviceBackup(String path) async {
    if (!Platform.isIOS) return;
    try {
      await const MethodChannel('family_tales/privacy')
          .invokeMethod('excludeFromBackup', {'path': path});
    } catch (_) {
      // Not fatal: the data simply remains eligible for device backup.
    }
  }

  /// Total bytes used under [dir] (recursive).
  static Future<int> sizeOf(Directory dir) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
    return total;
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  double v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}
