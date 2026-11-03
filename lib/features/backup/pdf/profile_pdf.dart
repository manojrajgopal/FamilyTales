/// Biography-style PDF for one family member.
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/database/app_database.dart';
import '../../../core/models/enums.dart';
import '../../../core/models/fuzzy_date.dart';
import '../../family/domain/family_graph.dart';
import '../export/export_data.dart';
import 'pdf_theme.dart';

Future<Uint8List> buildProfilePdf({
  required TreeExportData data,
  required String personId,
  required PdfFonts fonts,
  Uint8List? photo,
  DateTime? now,
}) async {
  final doc = pw.Document(theme: fonts.theme, author: 'Family Tales', creator: 'Family Tales');
  final date = formatPrintDate(now ?? DateTime.now());
  final g = data.graph;
  final person = g[personId];

  pw.TextStyle st(pw.Font f, double size, [PdfColor color = PdfPalette.ink]) =>
      pw.TextStyle(font: f, fontSize: size, color: color, lineSpacing: 2);

  pw.Widget footer(pw.Context ctx) => pw.Container(
        margin: const pw.EdgeInsets.only(top: 16),
        padding: const pw.EdgeInsets.only(top: 8),
        decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: PdfPalette.line))),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('${data.tree.name} · Family Tales · $date', style: st(fonts.regular, 8, PdfPalette.ink3)),
            pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: st(fonts.regular, 8, PdfPalette.ink3)),
          ],
        ),
      );

  if (person == null) {
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (_) => pw.Center(
        child: pw.Text('This person is private and hidden by the sharing filters.',
            style: st(fonts.medium, 14, PdfPalette.ink2)),
      ),
    ));
    return doc.save();
  }

  String? fmt(String? serialized, {bool long = true}) {
    final d = FuzzyDate.tryParse(serialized);
    return d == null || d.isEmpty ? null : d.format(long: long);
  }

  // ---------------------------------------------------------- sections
  pw.Widget sectionTitle(String t) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 22, bottom: 8),
        child: pw.Row(children: [
          pw.Container(width: 3, height: 14, color: PdfPalette.accent),
          pw.SizedBox(width: 8),
          pw.Text(t.toUpperCase(), style: pw.TextStyle(font: fonts.semiBold, fontSize: 10, letterSpacing: 1.2, color: PdfPalette.ink2)),
        ]),
      );

  pw.Widget factRow(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(width: 120, child: pw.Text(label, style: st(fonts.regular, 10, PdfPalette.ink3))),
            pw.Expanded(child: pw.Text(value, style: st(fonts.medium, 10.5))),
          ],
        ),
      );

  final facts = <(String, String)>[];
  void fact(String label, String? v) {
    if (v != null && v.trim().isNotEmpty) facts.add((label, v.trim()));
  }

  fact('Born', fmt(person.birthDate));
  fact('Birthplace', [person.birthPlace, person.birthCountry].whereType<String>().where((s) => s.trim().isNotEmpty).join(', '));
  if (!person.isLiving) {
    fact('Died', fmt(person.deathDate) ?? 'Deceased');
    fact('Place of death', person.deathPlace);
    fact('Cause of death', person.causeOfDeath);
    fact('Resting place', person.burialPlace);
    final age = person.age;
    if (age != null) fact('Age at death', age.format());
  } else {
    final age = person.age;
    if (age != null && person.birthDate != null) fact('Age', age.format());
  }
  fact('Birth name', person.birthName);
  fact('Also known as', person.nickname);
  fact('Gender', person.gender == Gender.unknown ? null : person.gender.label);
  fact('Pronouns', person.pronouns);
  fact('Occupation', person.occupation);
  fact('Education', person.education);
  fact('Nationality', person.nationality);
  fact('Languages', person.languages);
  fact('Interests', person.interests);
  fact('Achievements', person.achievements);
  fact('Email', person.email);
  fact('Phone', person.phone);
  fact('Address', person.address);
  final fieldById = {for (final f in data.fields) f.id: f};
  for (final v in data.values.where((v) => v.personId == personId)) {
    final f = fieldById[v.fieldId];
    if (f != null) fact(f.name, v.value);
  }

  // Family
  String nameOf(String id) => g[id]?.displayName ?? 'Unknown';
  String lifeOf(String id) {
    final l = g[id]?.lifespanLabel ?? '';
    return l.isEmpty ? '' : '  ($l)';
  }

  final family = <(String, List<String>)>[];
  final parents = [
    for (final l in g.parentLinksOf(personId))
      '${nameOf(l.parentId)}${lifeOf(l.parentId)}${l.type == ParentType.biological ? '' : ' – ${l.type.label.toLowerCase()} parent'}'
  ];
  if (parents.isNotEmpty) family.add(('Parents', parents));
  final partners = [
    for (final s in g.partnershipsOf(personId))
      () {
        final other = s.personAId == personId ? s.personBId : s.personAId;
        final since = fmt(s.startDate, long: false);
        final bits = <String>[
          s.type.label,
          if (since != null) 'from $since',
          if (s.status != PartnerStatus.current) s.status.label.toLowerCase(),
        ];
        return '${nameOf(other)}${lifeOf(other)} – ${bits.join(', ')}';
      }()
  ];
  if (partners.isNotEmpty) family.add(('Partners', partners));
  final children = [
    for (final l in g.childLinksOf(personId))
      '${nameOf(l.childId)}${lifeOf(l.childId)}${l.type == ParentType.biological ? '' : ' – ${l.type.label.toLowerCase()}'}'
  ];
  if (children.isNotEmpty) family.add(('Children', children));
  final siblings = [
    for (final s in g.siblings(personId))
      '${nameOf(s.personId)}${lifeOf(s.personId)}${switch (s.kind) {
        SiblingKind.full => '',
        SiblingKind.half => ' – half-sibling',
        SiblingKind.step => ' – step-sibling',
        SiblingKind.adoptive => ' – adoptive sibling',
      }}'
  ];
  if (siblings.isNotEmpty) family.add(('Siblings', siblings));

  // Events
  final eventIds = {for (final ep in data.eventPeople) if (ep.personId == personId) ep.eventId};
  final events = data.events.where((e) => eventIds.contains(e.id)).toList()
    ..sort((a, b) => (FuzzyDate.tryParse(a.date)?.sortKey ?? double.infinity)
        .compareTo(FuzzyDate.tryParse(b.date)?.sortKey ?? double.infinity));

  // Sources cited for this person or their events.
  final sourceById = {for (final s in data.sources) s.id: s};
  final cites = data.citations
      .where((c) => (c.entityType == 'person' && c.entityId == personId) ||
          (c.entityType == 'event' && eventIds.contains(c.entityId)))
      .toList();

  // Photo / initials
  const photoSize = 104.0;
  final avatar = photo != null
      ? pw.Container(
          width: photoSize + 6,
          height: photoSize + 6,
          padding: const pw.EdgeInsets.all(3),
          decoration: const pw.BoxDecoration(color: PdfPalette.accentSoft, shape: pw.BoxShape.circle),
          child: pw.ClipOval(child: pw.Image(pw.MemoryImage(photo), fit: pw.BoxFit.cover)),
        )
      : pw.Container(
          width: photoSize,
          height: photoSize,
          alignment: pw.Alignment.center,
          decoration: const pw.BoxDecoration(color: PdfPalette.avatar, shape: pw.BoxShape.circle),
          child: pw.Text(initialsOf(person.displayName), style: st(fonts.medium, 34, PdfPalette.ink2)),
        );

  final lifespan = () {
    final b = fmt(person.birthDate);
    final d = fmt(person.deathDate);
    if (!person.isLiving) return '${b ?? 'Unknown'} – ${d ?? 'Unknown'}';
    return b == null ? 'Living' : 'Born $b';
  }();

  // Top-level Text widgets with TextOverflow.span can flow across pages in a
  // MultiPage (Padding cannot).
  List<pw.Widget> paragraphs(String text) => [
        for (final para in text.split(RegExp(r'\n\s*\n')))
          if (para.trim().isNotEmpty) ...[
            pw.Text(para.trim(), overflow: pw.TextOverflow.span, style: st(fonts.regular, 10.5, PdfPalette.ink2)),
            pw.SizedBox(height: 8),
          ],
      ];

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(48, 44, 48, 36),
    footer: footer,
    build: (ctx) => [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          avatar,
          pw.SizedBox(width: 22),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(data.tree.name.toUpperCase(),
                    style: pw.TextStyle(font: fonts.semiBold, fontSize: 9, letterSpacing: 1.4, color: PdfPalette.accent)),
                pw.SizedBox(height: 6),
                pw.Text(person.displayName, style: st(fonts.semiBold, 26)),
                pw.SizedBox(height: 4),
                pw.Text(lifespan, style: st(fonts.regular, 12, PdfPalette.ink2)),
                if (person.nickname != null && person.nickname!.trim().isNotEmpty) ...[
                  pw.SizedBox(height: 2),
                  pw.Text('“${person.nickname!.trim()}”', style: st(fonts.regular, 11, PdfPalette.ink3)),
                ],
              ],
            ),
          ),
        ],
      ),
      pw.SizedBox(height: 18),
      pw.Container(height: 1, color: PdfPalette.line),
      if (facts.isNotEmpty) ...[
        sectionTitle('Life at a glance'),
        for (final (l, v) in facts) factRow(l, v),
      ],
      if (person.biography != null && person.biography!.trim().isNotEmpty) ...[
        sectionTitle('Biography'),
        ...paragraphs(person.biography!),
      ],
      if (family.isNotEmpty) ...[
        sectionTitle('Family'),
        for (final (label, names) in family) ...[
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 4, bottom: 2),
            child: pw.Text(label, style: st(fonts.semiBold, 10.5)),
          ),
          for (final n in names)
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 10, bottom: 2),
              child: pw.Text('•  $n', style: st(fonts.regular, 10.5, PdfPalette.ink2)),
            ),
        ],
      ],
      if (events.isNotEmpty) ...[
        sectionTitle('Life events'),
        for (final e in events)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 4),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.SizedBox(
                    width: 110,
                    child: pw.Text(fmt(e.date, long: false) ?? 'Date unknown',
                        style: st(fonts.medium, 10, PdfPalette.accent))),
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(e.title, style: st(fonts.semiBold, 10.5)),
                      if (e.location != null && e.location!.trim().isNotEmpty)
                        pw.Text(e.location!, style: st(fonts.regular, 9.5, PdfPalette.ink3)),
                      if (e.description != null && e.description!.trim().isNotEmpty)
                        pw.Text(e.description!, maxLines: 12, style: st(fonts.regular, 10, PdfPalette.ink2)),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
      if (person.notes != null && person.notes!.trim().isNotEmpty) ...[
        sectionTitle('Notes'),
        ...paragraphs(person.notes!),
      ],
      if (cites.isNotEmpty) ...[
        sectionTitle('Sources'),
        for (final c in cites)
          if (sourceById[c.sourceId] != null)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 4),
              child: pw.Text(
                _citationLine(sourceById[c.sourceId]!, c),
                style: st(fonts.regular, 9.5, PdfPalette.ink2),
              ),
            ),
      ],
    ],
  ));
  return doc.save();
}

String _citationLine(Source s, Citation c) {
  final parts = <String>[
    s.title,
    if (s.author != null && s.author!.trim().isNotEmpty) s.author!.trim(),
    if (c.detail != null && c.detail!.trim().isNotEmpty) c.detail!.trim(),
  ];
  final fact = c.fact == 'general' ? '' : ' (${c.fact})';
  return '•  ${parts.join(' · ')}$fact';
}
