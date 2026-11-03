import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../../core/services/app_paths.dart';

/// Opens the system share sheet for a file. Returns false if sharing failed.
Future<bool> shareFile(
  BuildContext context,
  String path, {
  String? mimeType,
  String? subject,
}) async {
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null || !box.hasSize
      ? null
      : box.localToGlobal(Offset.zero) & box.size;
  try {
    await SharePlus.instance.share(ShareParams(
      files: [XFile(path, mimeType: mimeType, name: p.basename(path))],
      subject: subject ?? p.basename(path),
      sharePositionOrigin: origin,
    ));
    return true;
  } catch (_) {
    return false;
  }
}

/// Lets the user choose where to save a copy of [path] on the device.
/// Returns true when a location was chosen.
Future<bool> saveFileToDevice(String path, {String mimeType = 'application/octet-stream'}) async {
  final bytes = await File(path).readAsBytes();
  final uri = await FilePicker.saveFile(
    fileName: p.basename(path),
    bytes: bytes,
    mimeType: mimeType,
    dialogTitle: 'Save ${p.basename(path)}',
  );
  return uri != null;
}

/// Picks one file and returns a local path to read it from (copying content
/// URIs into the app's temporary folder when needed) plus its display name.
Future<(String path, String name)?> pickLocalFile({
  List<String>? extensions,
  String? dialogTitle,
}) async {
  final f = await FilePicker.pickFile(
    dialogTitle: dialogTitle,
    type: extensions == null ? FileType.any : FileType.custom,
    allowedExtensions: extensions,
  );
  if (f == null) return null;
  final direct = f.path;
  if (direct != null && await File(direct).exists()) return (direct, f.name);
  final dir = Directory(p.join(AppPaths.I.temp.path, 'picked'));
  await dir.create(recursive: true);
  final safe = f.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  final dest = File(p.join(dir.path, '${DateTime.now().millisecondsSinceEpoch}_$safe'));
  final sink = dest.openWrite();
  try {
    await sink.addStream(f.readAsByteStream());
  } finally {
    await sink.close();
  }
  return (dest.path, f.name);
}
