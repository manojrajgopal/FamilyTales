/// Family tree poster PDF built from [TreeLayoutEngine] (the same layout the
/// app's tree screen uses): orthogonal connectors, rounded person cards,
/// scaled to fit a large landscape page.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/models/enums.dart';
import '../../family/domain/family_graph.dart';
import '../../family_tree/layout/tree_layout.dart';
import '../export/export_data.dart';
import 'pdf_theme.dart';

enum TreePdfPageSize {
  fit('Fit tree', 'Custom page sized to the tree'),
  a3('A3', 'A3 landscape'),
  a4('A4', 'A4 landscape');

  const TreePdfPageSize(this.label, this.description);
  final String label;
  final String description;
}

class TreePdfOptions {
  const TreePdfOptions({
    this.mode = TreeViewMode.full,
    this.pageSize = TreePdfPageSize.fit,
    this.focusId,
    this.generations = 4,
  });

  final TreeViewMode mode;
  final TreePdfPageSize pageSize;
  final String? focusId;
  final int generations;

  TreePdfOptions copyWith({TreeViewMode? mode, TreePdfPageSize? pageSize, int? generations}) =>
      TreePdfOptions(
        mode: mode ?? this.mode,
        pageSize: pageSize ?? this.pageSize,
        focusId: focusId,
        generations: generations ?? this.generations,
      );

  @override
  bool operator ==(Object other) =>
      other is TreePdfOptions &&
      other.mode == mode &&
      other.pageSize == pageSize &&
      other.focusId == focusId &&
      other.generations == generations;

  @override
  int get hashCode => Object.hash(mode, pageSize, focusId, generations);
}

/// Points per layout unit on a "Fit tree" page (keeps names legible).
const _fitScale = 0.75;

/// PDF pages are limited to 200 inches per side.
const _maxPagePoints = 14400.0;

class TreePdfResult {
  const TreePdfResult(this.bytes, this.scale, this.people);
  final Uint8List bytes;

  /// Points per layout unit actually used (small values = tiny text).
  final double scale;
  final int people;
}

Future<TreePdfResult> buildTreePdf({
  required TreeExportData data,
  required PdfFonts fonts,
  required TreePdfOptions options,
  Map<String, Uint8List> photos = const {},
  DateTime? now,
}) async {
  final g = data.graph;
  final full = options.mode == TreeViewMode.full || options.mode == TreeViewMode.compact;
  final layout = TreeLayoutEngine(g).compute(TreeLayoutOptions(
    mode: options.mode,
    focusId: options.focusId,
    generationsUp: full ? 999 : options.generations,
    generationsDown: full ? 999 : options.generations,
  ));
  final o = layout.options;
  final doc = pw.Document(
    theme: fonts.theme,
    title: '${data.tree.name} – family tree',
    author: 'Family Tales',
    creator: 'Family Tales',
  );
  final date = formatPrintDate(now ?? DateTime.now());
  const margin = 28.0;
  const headerH = 64.0;
  const footerH = 22.0;

  if (layout.isEmpty) {
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4.landscape,
      build: (_) => pw.Center(
        child: pw.Text('This family tree has no people yet.',
            style: pw.TextStyle(font: fonts.medium, fontSize: 16, color: PdfPalette.ink2)),
      ),
    ));
    return TreePdfResult(await doc.save(), 1, 0);
  }

  // Bounds of the drawn content (cards and every line).
  final content = layout.contentBounds;
  const pad = 24.0;
  final w = content.width + pad * 2;
  final h = content.height + pad * 2;
  final dx = pad - content.left, dy = pad - content.top;

  PdfPageFormat format;
  switch (options.pageSize) {
    case TreePdfPageSize.a4:
      format = PdfPageFormat.a4.landscape;
    case TreePdfPageSize.a3:
      format = PdfPageFormat.a3.landscape;
    case TreePdfPageSize.fit:
      var s = _fitScale;
      final maxContentW = _maxPagePoints - margin * 2;
      final maxContentH = _maxPagePoints - margin * 2 - headerH - footerH;
      s = math.min(s, math.min(maxContentW / w, maxContentH / h));
      final pw0 = math.max(PdfPageFormat.a4.landscape.width, w * s + margin * 2);
      final ph0 = math.max(PdfPageFormat.a4.landscape.height, h * s + margin * 2 + headerH + footerH);
      format = PdfPageFormat(pw0, ph0, marginAll: margin);
  }
  final contentW = format.width - margin * 2;
  final contentH = format.height - margin * 2 - headerH - footerH;
  final scale = math.min(contentW / w, contentH / h);

  final k = o.nodeWidth / 132; // compact mode shrinks text and avatars
  final homeId = data.tree.homePersonId;

  pw.Widget node(LayoutNode n) {
    final person = g[n.id]!;
    final photo = photos[n.id];
    final avatarSize = 58.0 * k;
    final highlight = n.id == homeId || n.isFocus;
    final avatar = photo != null
        ? pw.ClipOval(
            child: pw.Image(pw.MemoryImage(photo),
                width: avatarSize, height: avatarSize, fit: pw.BoxFit.cover))
        : pw.Container(
            width: avatarSize,
            height: avatarSize,
            alignment: pw.Alignment.center,
            decoration: const pw.BoxDecoration(color: PdfPalette.avatar, shape: pw.BoxShape.circle),
            child: pw.Text(initialsOf(person.displayName),
                style: pw.TextStyle(font: fonts.medium, fontSize: 18 * k, color: PdfPalette.ink2)),
          );
    final life = person.lifespanLabel;
    return pw.Container(
      width: o.nodeWidth,
      height: o.nodeHeight,
      padding: pw.EdgeInsets.fromLTRB(8 * k, 12 * k, 8 * k, 8 * k),
      decoration: pw.BoxDecoration(
        color: person.isLiving ? PdfColors.white : PdfPalette.cardDeceased,
        borderRadius: pw.BorderRadius.circular(16 * k),
        border: pw.Border.all(
            color: highlight ? PdfPalette.accent : PdfPalette.line, width: highlight ? 1.8 : 1),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          avatar,
          pw.SizedBox(height: 8 * k),
          pw.Text(
            person.displayName,
            maxLines: 2,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(font: fonts.semiBold, fontSize: 12.5 * k, color: PdfPalette.ink, lineSpacing: 1),
          ),
          if (life.isNotEmpty) ...[
            pw.SizedBox(height: 3 * k),
            pw.Text(life,
                maxLines: 1,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(font: fonts.regular, fontSize: 10 * k, color: PdfPalette.ink3)),
          ],
        ],
      ),
    );
  }

  void paintConnectors(PdfGraphics c, PdfPoint size) {
    double x(double v) => v + dx;
    double y(double v) => size.y - (v + dy); // PDF y axis points up
    c
      ..setLineCap(PdfLineCap.round)
      ..setLineJoin(PdfLineJoin.round);
    void polyline(List<Offset> pts) {
      c.moveTo(x(pts.first.dx), y(pts.first.dy));
      for (final p in pts.skip(1)) {
        c.lineTo(x(p.dx), y(p.dy));
      }
      c.strokePath();
    }

    // Couple lines.
    for (final pc in layout.partners) {
      final dashed = pc.status != PartnerStatus.current && pc.status != PartnerStatus.widowed;
      c
        ..setStrokeColor(pc.status == PartnerStatus.current ? PdfPalette.accent : PdfPalette.connector)
        ..setLineWidth(1.6);
      if (dashed) c.setLineDashPattern([5, 4]);
      polyline(pc.points(o));
      if (dashed) c.setLineDashPattern();
    }
    // Parent → children buses.
    for (final f in layout.families) {
      if (f.children.isEmpty) continue;
      c
        ..setStrokeColor(PdfPalette.connector)
        ..setLineWidth(1.3);
      polyline([f.origin, Offset(f.origin.dx, f.busY)]);
      for (final ch in f.children) {
        final dashed = ch.type != ParentType.biological && ch.type != ParentType.unknown;
        if (dashed) c.setLineDashPattern([4, 3]);
        polyline(ch.points(f.origin.dx, f.busY));
        if (dashed) c.setLineDashPattern();
      }
    }
  }

  final canvas = pw.SizedBox(
    width: w,
    height: h,
    child: pw.Stack(
      children: [
        pw.Positioned.fill(child: pw.CustomPaint(size: PdfPoint(w, h), painter: paintConnectors)),
        for (final n in layout.nodes.values)
          pw.Positioned(left: n.x + dx, top: n.y + dy, child: node(n)),
      ],
    ),
  );

  final modeLabel = switch (options.mode) {
    TreeViewMode.full => 'Complete family',
    TreeViewMode.compact => 'Complete family (compact)',
    TreeViewMode.descendants => 'Descendants of ${g[options.focusId ?? '']?.displayName ?? 'the home person'}',
    TreeViewMode.ancestors => 'Ancestors of ${g[options.focusId ?? '']?.displayName ?? 'the home person'}',
    TreeViewMode.focus => 'Close family of ${g[options.focusId ?? '']?.displayName ?? 'the home person'}',
  };

  doc.addPage(pw.Page(
    pageFormat: format,
    margin: const pw.EdgeInsets.all(margin),
    build: (ctx) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.SizedBox(
          height: headerH,
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Container(width: 4, height: 40, color: PdfPalette.accent),
              pw.SizedBox(width: 12),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(data.tree.name,
                        maxLines: 1, style: pw.TextStyle(font: fonts.semiBold, fontSize: 22, color: PdfPalette.ink)),
                    pw.SizedBox(height: 4),
                    pw.Text('Family tree · $modeLabel · ${layout.nodes.length} people',
                        style: pw.TextStyle(font: fonts.regular, fontSize: 10.5, color: PdfPalette.ink3)),
                  ],
                ),
              ),
              pw.Text(date, style: pw.TextStyle(font: fonts.regular, fontSize: 10.5, color: PdfPalette.ink3)),
            ],
          ),
        ),
        pw.Expanded(child: pw.FittedBox(fit: pw.BoxFit.contain, child: canvas)),
        pw.SizedBox(
          height: footerH,
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text('Solid lines: birth parents · dashed: adoptive, step or foster · dashed couple line: ended relationship',
                  style: pw.TextStyle(font: fonts.regular, fontSize: 8, color: PdfPalette.ink3)),
              pw.Text('Created with Family Tales',
                  style: pw.TextStyle(font: fonts.medium, fontSize: 8, color: PdfPalette.accent)),
            ],
          ),
        ),
      ],
    ),
  ));
  return TreePdfResult(await doc.save(), scale, layout.nodes.length);
}
