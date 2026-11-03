import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'app_paths.dart';

/// Result of copying a file into app storage.
class StoredMedia {
  const StoredMedia({
    required this.relativePath,
    required this.thumbRelativePath,
    required this.width,
    required this.height,
    required this.sizeBytes,
    required this.mimeType,
    required this.originalName,
  });

  final String relativePath;
  final String? thumbRelativePath;
  final int? width;
  final int? height;
  final int sizeBytes;
  final String mimeType;
  final String originalName;
}

/// Stores photos and documents as files in the private documents directory
/// (never as database blobs) and generates small thumbnails off the UI
/// isolate.
class MediaStorage {
  const MediaStorage();

  static const thumbSize = 420;
  static const _imageExt = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.heic', '.heif'};

  static bool isImagePath(String path) =>
      _imageExt.contains(p.extension(path).toLowerCase());

  static String mimeFor(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      case '.heic':
      case '.heif':
        return 'image/heic';
      case '.pdf':
        return 'application/pdf';
      case '.txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  /// Copies [source] into the tree's media folder and creates a thumbnail.
  Future<StoredMedia> importFile(File source, String treeId, {String? originalName}) async {
    final paths = AppPaths.I;
    final dir = paths.mediaDir(treeId);
    await dir.create(recursive: true);
    final ext = p.extension(source.path).toLowerCase();
    final id = const Uuid().v4();
    final dest = File(p.join(dir.path, '$id${ext.isEmpty ? '.bin' : ext}'));
    await source.copy(dest.path);
    final size = await dest.length();
    String? thumbRel;
    int? w, h;
    if (isImagePath(dest.path)) {
      final t = await _makeThumb(dest, treeId, id);
      thumbRel = t.$1;
      w = t.$2;
      h = t.$3;
    }
    return StoredMedia(
      relativePath: paths.relative(dest.path),
      thumbRelativePath: thumbRel,
      width: w,
      height: h,
      sizeBytes: size,
      mimeType: mimeFor(dest.path),
      originalName: originalName ?? p.basename(source.path),
    );
  }

  /// Writes raw bytes (used by restore / GEDCOM import).
  Future<String> writeBytes(String treeId, String fileName, Uint8List bytes) async {
    final dir = AppPaths.I.mediaDir(treeId);
    await dir.create(recursive: true);
    final f = File(p.join(dir.path, fileName));
    await f.writeAsBytes(bytes, flush: true);
    return AppPaths.I.relative(f.path);
  }

  Future<(String?, int?, int?)> _makeThumb(File file, String treeId, String id) async {
    final tdir = AppPaths.I.thumbDir(treeId);
    await tdir.create(recursive: true);
    final out = p.join(tdir.path, '$id.jpg');
    final res = await compute(_thumbIsolate, (file.path, out, thumbSize));
    if (res == null) return (null, null, null);
    return (AppPaths.I.relative(out), res.$1, res.$2);
  }

  /// Regenerates the thumbnail for an existing file (after rotate / crop).
  Future<(String?, int?, int?)> regenerateThumb(String relPath, String treeId) async {
    final f = File(AppPaths.I.resolve(relPath));
    final id = p.basenameWithoutExtension(f.path);
    return _makeThumb(f, treeId, '${id}_${DateTime.now().millisecondsSinceEpoch}');
  }

  /// Rotates an image file 90° clockwise in place (re-encoded as JPEG/PNG).
  Future<void> rotate(String relPath, {int degrees = 90}) async {
    final abs = AppPaths.I.resolve(relPath);
    final ok = await compute(_rotateIsolate, (abs, degrees));
    if (!ok) throw Exception('This image format cannot be edited.');
  }

  /// Crops an image file in place. Rect is in source pixel coordinates.
  Future<void> crop(String relPath, int x, int y, int w, int h) async {
    final abs = AppPaths.I.resolve(relPath);
    final ok = await compute(_cropIsolate, (abs, x, y, w, h));
    if (!ok) throw Exception('This image format cannot be edited.');
  }

  Future<void> deleteFiles(String? relPath, String? thumbRel) async {
    for (final r in [relPath, thumbRel]) {
      if (r == null) continue;
      final f = File(AppPaths.I.resolve(r));
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}

(int, int)? _thumbIsolate((String, String, int) args) {
  final (src, out, size) = args;
  try {
    final bytes = File(src).readAsBytesSync();
    var image = img.decodeImage(bytes);
    if (image == null) return null;
    image = img.bakeOrientation(image);
    final w = image.width, h = image.height;
    final thumb = w >= h
        ? img.copyResize(image, width: w > size ? size : w, interpolation: img.Interpolation.average)
        : img.copyResize(image, height: h > size ? size : h, interpolation: img.Interpolation.average);
    File(out).writeAsBytesSync(img.encodeJpg(thumb, quality: 82));
    return (w, h);
  } catch (_) {
    return null;
  }
}

bool _rotateIsolate((String, int) args) {
  final (path, deg) = args;
  try {
    final bytes = File(path).readAsBytesSync();
    var image = img.decodeImage(bytes);
    if (image == null) return false;
    image = img.bakeOrientation(image);
    final rotated = img.copyRotate(image, angle: deg);
    File(path).writeAsBytesSync(_encodeLike(path, rotated));
    return true;
  } catch (_) {
    return false;
  }
}

bool _cropIsolate((String, int, int, int, int) args) {
  final (path, x, y, w, h) = args;
  try {
    var image = img.decodeImage(File(path).readAsBytesSync());
    if (image == null) return false;
    image = img.bakeOrientation(image);
    final cx = x.clamp(0, image.width - 1);
    final cy = y.clamp(0, image.height - 1);
    final cw = w.clamp(1, image.width - cx);
    final ch = h.clamp(1, image.height - cy);
    final cropped = img.copyCrop(image, x: cx, y: cy, width: cw, height: ch);
    File(path).writeAsBytesSync(_encodeLike(path, cropped));
    return true;
  } catch (_) {
    return false;
  }
}

List<int> _encodeLike(String path, img.Image image) {
  final ext = p.extension(path).toLowerCase();
  if (ext == '.png') return img.encodePng(image);
  return img.encodeJpg(image, quality: 92);
}
