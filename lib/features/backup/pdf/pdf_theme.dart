import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/database/app_database.dart';
import '../../../core/services/app_paths.dart';

/// Inter fonts embedded from the app bundle (never downloaded).
class PdfFonts {
  PdfFonts({required this.regular, required this.medium, required this.semiBold, required this.bold});

  final pw.Font regular;
  final pw.Font medium;
  final pw.Font semiBold;
  final pw.Font bold;

  static PdfFonts? _cache;

  static Future<PdfFonts> load() async {
    final c = _cache;
    if (c != null) return c;
    Future<pw.Font> f(String name) async => pw.Font.ttf(await rootBundle.load('assets/fonts/Inter-$name.ttf'));
    return _cache = PdfFonts(
      regular: await f('Regular'),
      medium: await f('Medium'),
      semiBold: await f('SemiBold'),
      bold: await f('Bold'),
    );
  }

  pw.ThemeData get theme => pw.ThemeData.withFont(
        base: regular,
        bold: bold,
        italic: regular,
        boldItalic: bold,
      );
}

/// Print palette: light paper, graphite ink, a restrained mint accent.
abstract final class PdfPalette {
  static const ink = PdfColor.fromInt(0xFF111215);
  static const ink2 = PdfColor.fromInt(0xFF4A4D55);
  static const ink3 = PdfColor.fromInt(0xFF7A7E87);
  static const line = PdfColor.fromInt(0xFFD9DCE1);
  static const connector = PdfColor.fromInt(0xFF9AA0A8);
  static const card = PdfColor.fromInt(0xFFF6F7F8);
  static const cardDeceased = PdfColor.fromInt(0xFFEFF0F2);
  static const accent = PdfColor.fromInt(0xFF2F9C89);
  static const accentSoft = PdfColor.fromInt(0xFFE3F5F1);
  static const avatar = PdfColor.fromInt(0xFFE4E6E9);
}

/// True for image bytes the PDF library can embed directly (JPEG / PNG).
bool isEmbeddableImage(Uint8List b) {
  if (b.length < 8) return false;
  final jpeg = b[0] == 0xFF && b[1] == 0xD8;
  final png = b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;
  return jpeg || png;
}

/// Reads a photo for a PDF: the original when it is a JPEG/PNG and
/// [preferOriginal], otherwise the (JPEG) thumbnail.
Future<Uint8List?> readPdfImage(MediaAsset m, {bool preferOriginal = false}) async {
  if (!AppPaths.isReady) return null;
  final candidates = <String?>[
    if (preferOriginal) m.filePath,
    m.thumbPath,
    if (!preferOriginal) m.filePath,
  ];
  for (final rel in candidates) {
    if (rel == null) continue;
    final ext = p.extension(rel).toLowerCase();
    if (!const {'.jpg', '.jpeg', '.png'}.contains(ext)) continue;
    try {
      final f = File(AppPaths.I.resolve(rel));
      if (!await f.exists()) continue;
      if (await f.length() > 12 * 1024 * 1024) continue;
      final bytes = await f.readAsBytes();
      if (isEmbeddableImage(bytes)) return bytes;
    } catch (_) {}
  }
  return null;
}

String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  final f = String.fromCharCodes(parts.first.runes.take(1));
  final l = parts.length > 1 ? String.fromCharCodes(parts.last.runes.take(1)) : '';
  return (f + l).toUpperCase();
}

String formatPrintDate(DateTime d) {
  const m = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
    'October', 'November', 'December'];
  return '${d.day} ${m[d.month - 1]} ${d.year}';
}
