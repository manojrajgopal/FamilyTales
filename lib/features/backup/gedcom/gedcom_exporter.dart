/// Writes a tree as GEDCOM 5.5.1 (UTF-8, LINEAGE-LINKED).
///
/// * INDI per person (NAME/GIVN/SURN/NICK, SEX, BIRT, DEAT, BURI, OCCU,
///   EDUC, NATI, FACT, RESN, NOTE, SOUR citations, FAMC + PEDI, FAMS).
/// * FAM records: children grouped per parent pair, partnerships without
///   children, and single-parent families. `_STAT` carries relationship
///   states that GEDCOM 5.5.1 cannot express (partners, widowed, separated,
///   "Never Married" for co-parents who were not a couple).
/// * Events as `EVEN` + `TYPE`.
/// * Long values are split with CONC, line breaks become CONT.
library;

import '../../../core/database/app_database.dart';
import '../../../core/models/enums.dart';
import '../../../core/models/fuzzy_date.dart';
import '../../family/domain/family_graph.dart';
import '../backup_format.dart' show backupAppVersion;
import '../export/export_data.dart';
import '../export/export_privacy.dart';

class GedcomExportResult {
  const GedcomExportResult({
    required this.text,
    required this.people,
    required this.families,
    required this.events,
    required this.sources,
    required this.citations,
    required this.livingAnonymized,
    required this.excludedPeople,
    required this.skippedCitations,
    required this.skippedEvents,
  });

  final String text;
  final int people;
  final int families;
  final int events;
  final int sources;
  final int citations;
  final int livingAnonymized;
  final int excludedPeople;
  final int skippedCitations;
  final int skippedEvents;

  String get summary {
    final b = StringBuffer('$people people, $families families, $events events, $sources sources');
    if (livingAnonymized > 0) b.write(' · $livingAnonymized living people shown as "Living"');
    if (excludedPeople > 0) b.write(' · $excludedPeople private people left out');
    return b.toString();
  }
}

/// Splits values into GEDCOM lines (CONT for newlines, CONC for long text).
class GedcomWriter {
  final StringBuffer _b = StringBuffer();

  /// Maximum characters of a value per physical line.
  static const maxValue = 200;

  void raw(int level, String tag, {String? xref, String? value}) {
    _b.write(level);
    if (xref != null) _b.write(' $xref');
    _b.write(' $tag');
    if (value != null && value.isNotEmpty) _b.write(' $value');
    _b.write('\r\n');
  }

  /// Writes a pointer value (not escaped).
  void pointer(int level, String tag, String xref) => raw(level, tag, value: xref);

  /// Writes a text value, escaping `@` and splitting as needed.
  void text(int level, String tag, String? value, {String? xref}) {
    final v = (value ?? '').replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll('@', '@@');
    final paras = v.split('\n');
    for (var i = 0; i < paras.length; i++) {
      final pieces = _split(paras[i]);
      for (var j = 0; j < pieces.length; j++) {
        if (i == 0 && j == 0) {
          raw(level, tag, xref: xref, value: pieces[j]);
        } else if (j == 0) {
          raw(level + 1, 'CONT', value: pieces[j]);
        } else {
          raw(level + 1, 'CONC', value: pieces[j]);
        }
      }
    }
  }

  static List<String> _split(String s) {
    if (s.length <= maxValue) return [s];
    final out = <String>[];
    var rest = s;
    while (rest.length > maxValue) {
      var i = maxValue;
      // Never split next to a space (readers may trim), inside "@@" or a
      // surrogate pair.
      var k = i;
      while (k > maxValue - 60 &&
          (rest[k - 1] == ' ' || rest[k] == ' ' || (rest[k - 1] == '@' && rest[k] == '@') ||
              _isHighSurrogate(rest.codeUnitAt(k - 1)))) {
        k--;
      }
      if (k > maxValue - 60) i = k;
      if (_isHighSurrogate(rest.codeUnitAt(i - 1))) i--;
      out.add(rest.substring(0, i));
      rest = rest.substring(i);
    }
    out.add(rest);
    return out;
  }

  static bool _isHighSurrogate(int c) => c >= 0xD800 && c <= 0xDBFF;

  @override
  String toString() => _b.toString();
}

class _Fam {
  _Fam(this.parents);
  final List<String> parents; // 1 or 2 person ids
  Partnership? partnership;
  final List<(String childId, ParentType type)> children = [];
  String xref = '';
}

class GedcomExporter {
  GedcomExporter(this.data, {this.privacy = ExportPrivacy.none, DateTime? now})
      : now = now ?? DateTime.now();

  final TreeExportData data;
  final ExportPrivacy privacy;
  final DateTime now;

  static const _months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];

  GedcomExportResult build() {
    final w = GedcomWriter();
    final g = data.graph;
    final people = data.people.toList()
      ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    final pid = <String, String>{};
    for (var i = 0; i < people.length; i++) {
      pid[people[i].id] = '@I${i + 1}@';
    }
    bool anon(Person p) => privacy.anonymizesLiving && p.isLiving;

    // ---- families
    final fams = <_Fam>[];
    final famByPair = <String, _Fam>{};
    String key(List<String> ids) => (ids.toList()..sort()).join('|');
    for (final s in data.partnerships) {
      final k = key([s.personAId, s.personBId]);
      final f = _Fam(_ordered(s.personAId, s.personBId))..partnership = s;
      fams.add(f);
      famByPair.putIfAbsent(k, () => f);
    }
    for (final child in people) {
      final ls = g.parentLinksOf(child.id).toList();
      final used = <String>{};
      // Pair same-type parents, preferring couples with a partnership.
      final candidates = <(int, ParentChildLink, ParentChildLink)>[];
      for (var i = 0; i < ls.length; i++) {
        for (var j = i + 1; j < ls.length; j++) {
          if (ls[i].type != ls[j].type) continue;
          final partnered = g.partnershipBetween(ls[i].parentId, ls[j].parentId) != null;
          candidates.add((partnered ? 0 : 1, ls[i], ls[j]));
        }
      }
      candidates.sort((a, b) => a.$1.compareTo(b.$1));
      for (final (_, a, b) in candidates) {
        if (used.contains(a.parentId) || used.contains(b.parentId)) continue;
        used..add(a.parentId)..add(b.parentId);
        final k = key([a.parentId, b.parentId]);
        final f = famByPair.putIfAbsent(k, () {
          final nf = _Fam(_ordered(a.parentId, b.parentId));
          fams.add(nf);
          return nf;
        });
        f.children.add((child.id, a.type));
      }
      for (final l in ls) {
        if (used.contains(l.parentId)) continue;
        final k = 'single:${l.parentId}';
        final f = famByPair.putIfAbsent(k, () {
          final nf = _Fam([l.parentId]);
          fams.add(nf);
          return nf;
        });
        f.children.add((child.id, l.type));
      }
    }
    for (var i = 0; i < fams.length; i++) {
      fams[i].xref = '@F${i + 1}@';
    }
    final famc = <String, List<(String, ParentType)>>{};
    final famsOf = <String, List<String>>{};
    for (final f in fams) {
      for (final (c, t) in f.children) {
        (famc[c] ??= []).add((f.xref, t));
      }
      for (final p in f.parents) {
        (famsOf[p] ??= []).add(f.xref);
      }
    }

    // ---- sources
    final sources = data.sources.toList()..sort((a, b) => a.title.compareTo(b.title));
    final sid = <String, String>{for (var i = 0; i < sources.length; i++) sources[i].id: '@S${i + 1}@'};
    final repos = <String, String>{};
    for (final s in sources) {
      final r = s.repository?.trim();
      if (r != null && r.isNotEmpty) repos.putIfAbsent(r, () => '@R${repos.length + 1}@');
    }
    final citesBy = <String, List<Citation>>{};
    var skippedCitations = 0;
    for (final c in data.citations) {
      if (!sid.containsKey(c.sourceId)) continue;
      (citesBy['${c.entityType}:${c.entityId}'] ??= []).add(c);
    }
    var writtenCitations = 0;
    void cite(int level, Citation c) {
      w.pointer(level, 'SOUR', sid[c.sourceId]!);
      if (c.detail != null && c.detail!.trim().isNotEmpty) w.text(level + 1, 'PAGE', c.detail);
      w.raw(level + 1, 'QUAY', value: '${c.confidence.clamp(0, 3)}');
      writtenCitations++;
    }

    // ---- events per participant
    final eventsBy = <String, List<FamilyEvent>>{};
    final eventById = {for (final e in data.events) e.id: e};
    final withPeople = <String>{};
    for (final ep in data.eventPeople) {
      final e = eventById[ep.eventId];
      if (e == null || !pid.containsKey(ep.personId)) continue;
      (eventsBy[ep.personId] ??= []).add(e);
      withPeople.add(e.id);
    }
    final skippedEvents = data.events.where((e) => !withPeople.contains(e.id)).length;
    final valuesBy = <String, List<PersonCustomValue>>{};
    for (final v in data.values) {
      (valuesBy[v.personId] ??= []).add(v);
    }
    final fieldById = {for (final f in data.fields) f.id: f};

    // ---- HEAD
    w.raw(0, 'HEAD');
    w.raw(1, 'SOUR', value: 'FAMILY_TALES');
    w.raw(2, 'VERS', value: backupAppVersion);
    w.raw(2, 'NAME', value: 'Family Tales');
    w.raw(1, 'DATE', value: '${now.day} ${_months[now.month - 1]} ${now.year}');
    w.raw(2, 'TIME',
        value: '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:'
            '${now.second.toString().padLeft(2, '0')}');
    w.pointer(1, 'SUBM', '@U1@');
    w.text(1, 'FILE', '${_fileSafe(data.tree.name)}.ged');
    w.raw(1, 'GEDC');
    w.raw(2, 'VERS', value: '5.5.1');
    w.raw(2, 'FORM', value: 'LINEAGE-LINKED');
    w.raw(1, 'CHAR', value: 'UTF-8');
    if (data.tree.description != null && data.tree.description!.trim().isNotEmpty) {
      w.text(1, 'NOTE', data.tree.description);
    }
    w.raw(0, 'SUBM', xref: '@U1@');
    w.raw(1, 'NAME', value: 'Family Tales user');

    // ---- INDI
    var anonymized = 0;
    var eventCount = 0;
    for (final p in people) {
      final x = pid[p.id]!;
      w.raw(0, 'INDI', xref: x);
      final a = anon(p);
      if (a) {
        anonymized++;
        w.raw(1, 'NAME', value: 'Living //');
        w.raw(2, 'GIVN', value: 'Living');
      } else {
        final given = [p.firstName, p.middleName].whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty).join(' ');
        final sur = (p.lastName ?? '').trim();
        w.text(1, 'NAME', '$given /$sur/'.trim());
        if (given.isNotEmpty) w.text(2, 'GIVN', given);
        if (sur.isNotEmpty) w.text(2, 'SURN', sur);
        if (p.nickname != null && p.nickname!.trim().isNotEmpty) w.text(2, 'NICK', p.nickname);
        for (final c in citesBy['person:${p.id}'] ?? const <Citation>[]) {
          if (c.fact == 'name') cite(2, c);
        }
        final bn = p.birthName?.trim();
        if (bn != null && bn.isNotEmpty && bn != p.displayName) {
          w.text(1, 'NAME', _nameWithSurname(bn, sur));
          w.raw(2, 'TYPE', value: 'birth');
        }
      }
      w.raw(1, 'SEX', value: switch (p.gender) {
        Gender.male => 'M',
        Gender.female => 'F',
        _ => 'U',
      });
      if (p.isPrivate) w.raw(1, 'RESN', value: 'privacy');
      if (!a) {
        final personCites = citesBy['person:${p.id}'] ?? const <Citation>[];
        // Birth
        final bCites = personCites.where((c) => c.fact == 'birth').toList();
        final bPlace = _join([p.birthPlace, p.birthCountry]);
        if (p.birthDate != null || bPlace != null || _has(p.birthNotes) || bCites.isNotEmpty) {
          w.raw(1, 'BIRT');
          _date(w, 2, p.birthDate);
          if (bPlace != null) w.text(2, 'PLAC', bPlace);
          if (_has(p.birthNotes)) w.text(2, 'NOTE', p.birthNotes);
          for (final c in bCites) {
            cite(2, c);
          }
        }
        // Death
        final dCites = personCites.where((c) => c.fact == 'death').toList();
        if (!p.isLiving) {
          final details = p.deathDate != null || _has(p.deathPlace) || _has(p.causeOfDeath) ||
              _has(p.deathNotes) || dCites.isNotEmpty;
          w.raw(1, 'DEAT', value: details ? null : 'Y');
          _date(w, 2, p.deathDate);
          if (_has(p.deathPlace)) w.text(2, 'PLAC', p.deathPlace);
          if (_has(p.causeOfDeath)) w.text(2, 'CAUS', p.causeOfDeath);
          if (_has(p.deathNotes)) w.text(2, 'NOTE', p.deathNotes);
          for (final c in dCites) {
            cite(2, c);
          }
          if (_has(p.burialPlace)) {
            w.raw(1, 'BURI');
            w.text(2, 'PLAC', p.burialPlace);
          }
        }
        if (_has(p.occupation)) w.text(1, 'OCCU', p.occupation);
        if (_has(p.education)) w.text(1, 'EDUC', p.education);
        if (_has(p.nationality)) w.text(1, 'NATI', p.nationality);
        for (final (label, v) in [
          ('Pronouns', p.pronouns),
          ('Languages', p.languages),
          ('Interests', p.interests),
          ('Achievements', p.achievements),
        ]) {
          if (_has(v)) {
            w.text(1, 'FACT', v);
            w.raw(2, 'TYPE', value: label);
          }
        }
        for (final v in valuesBy[p.id] ?? const <PersonCustomValue>[]) {
          final f = fieldById[v.fieldId];
          if (f == null || v.value.trim().isEmpty) continue;
          w.text(1, 'FACT', v.value);
          w.text(2, 'TYPE', f.name);
        }
        if (_has(p.address) || _has(p.phone) || _has(p.email)) {
          w.raw(1, 'RESI');
          if (_has(p.address)) w.text(2, 'ADDR', p.address);
          if (_has(p.phone)) w.text(2, 'PHON', p.phone);
          if (_has(p.email)) w.text(2, 'EMAIL', p.email);
        }
        // Events
        final evs = (eventsBy[p.id] ?? const <FamilyEvent>[]).toList()
          ..sort((x, y) => (FuzzyDate.tryParse(x.date)?.sortKey ?? double.infinity)
              .compareTo(FuzzyDate.tryParse(y.date)?.sortKey ?? double.infinity));
        for (final e in evs) {
          final label = e.type == EventType.custom ? (e.customLabel ?? 'Event') : e.type.label;
          w.text(1, 'EVEN', e.title.trim() == label ? null : e.title);
          w.text(2, 'TYPE', label);
          _date(w, 2, e.date);
          if (_has(e.location)) w.text(2, 'PLAC', e.location);
          if (_has(e.description)) w.text(2, 'NOTE', e.description);
          for (final c in citesBy['event:${e.id}'] ?? const <Citation>[]) {
            cite(2, c);
          }
          eventCount++;
        }
        if (_has(p.biography)) w.text(1, 'NOTE', p.biography);
        if (_has(p.notes)) w.text(1, 'NOTE', p.notes);
        for (final c in personCites) {
          if (c.fact != 'birth' && c.fact != 'death' && c.fact != 'name') cite(1, c);
        }
      }
      for (final (fx, t) in famc[p.id] ?? const <(String, ParentType)>[]) {
        w.pointer(1, 'FAMC', fx);
        final pedi = switch (t) {
          ParentType.biological => null,
          ParentType.adoptive => 'adopted',
          ParentType.foster => 'foster',
          ParentType.step => 'step',
          ParentType.guardian => 'guardian',
          ParentType.unknown => 'unknown',
        };
        if (pedi != null) w.raw(2, 'PEDI', value: pedi);
      }
      for (final fx in famsOf[p.id] ?? const <String>[]) {
        w.pointer(1, 'FAMS', fx);
      }
    }

    // ---- FAM
    for (final f in fams) {
      w.raw(0, 'FAM', xref: f.xref);
      final ps = f.parents;
      if (ps.length == 2) {
        w.pointer(1, 'HUSB', pid[ps[0]]!);
        w.pointer(1, 'WIFE', pid[ps[1]]!);
      } else {
        final only = data.byId[ps.first]!;
        w.pointer(1, only.gender == Gender.female ? 'WIFE' : 'HUSB', pid[ps.first]!);
      }
      for (final (c, _) in f.children) {
        w.pointer(1, 'CHIL', pid[c]!);
      }
      final s = f.partnership;
      if (s == null) {
        if (ps.length == 2) w.raw(1, '_STAT', value: 'Never Married');
        continue;
      }
      final private = ps.any((id) => anon(data.byId[id]!));
      final pCites = citesBy['partnership:${s.id}'] ?? const <Citation>[];
      if (s.type == PartnerType.partner) w.raw(1, '_STAT', value: 'Partners');
      if (s.type == PartnerType.engaged) {
        w.raw(1, 'ENGA', value: private || (s.startDate == null && !_has(s.place)) ? 'Y' : null);
        if (!private) {
          _date(w, 2, s.startDate);
          if (_has(s.place)) w.text(2, 'PLAC', s.place);
        }
      } else if (s.type == PartnerType.marriage || s.type == PartnerType.civilUnion) {
        final hasDetails = !private && (s.startDate != null || _has(s.place));
        final mCites = private ? const <Citation>[] : pCites.where((c) => c.fact == 'marriage').toList();
        w.raw(1, 'MARR',
            value: hasDetails || s.type == PartnerType.civilUnion || mCites.isNotEmpty ? null : 'Y');
        if (s.type == PartnerType.civilUnion) w.raw(2, 'TYPE', value: 'Civil union');
        if (!private) {
          _date(w, 2, s.startDate);
          if (_has(s.place)) w.text(2, 'PLAC', s.place);
        }
        for (final c in mCites) {
          cite(2, c);
        }
      } else if (!private && (s.startDate != null || _has(s.place))) {
        // Partners: keep the start of the relationship as an event.
        w.raw(1, 'EVEN');
        w.raw(2, 'TYPE', value: 'Partnership');
        _date(w, 2, s.startDate);
        if (_has(s.place)) w.text(2, 'PLAC', s.place);
      }
      switch (s.status) {
        case PartnerStatus.current:
          break;
        case PartnerStatus.divorced:
          w.raw(1, 'DIV', value: private || s.endDate == null ? 'Y' : null);
          if (!private) _date(w, 2, s.endDate);
        case PartnerStatus.annulled:
          w.raw(1, 'ANUL', value: private || s.endDate == null ? 'Y' : null);
          if (!private) _date(w, 2, s.endDate);
        case PartnerStatus.separated:
          w.raw(1, '_SEPR', value: private || s.endDate == null ? 'Y' : null);
          if (!private) _date(w, 2, s.endDate);
        case PartnerStatus.widowed:
        case PartnerStatus.ended:
          w.raw(1, '_STAT', value: s.status == PartnerStatus.widowed ? 'Widowed' : 'Ended');
          if (!private) _date(w, 2, s.endDate);
      }
      if (!private) {
        if (_has(s.notes) && !privacy.hidesNotes) w.text(1, 'NOTE', s.notes);
        for (final c in pCites) {
          if (c.fact != 'marriage' || s.type == PartnerType.partner || s.type == PartnerType.engaged) {
            cite(1, c);
          }
        }
      }
    }

    // ---- SOUR / REPO
    for (final s in sources) {
      w.raw(0, 'SOUR', xref: sid[s.id]);
      w.text(1, 'TITL', s.title);
      if (_has(s.author)) w.text(1, 'AUTH', s.author);
      w.raw(1, '_TYPE', value: s.type.name);
      final d = s.date;
      if (d != null && d.trim().isNotEmpty) {
        w.raw(1, 'DATA');
        w.raw(2, 'EVEN');
        final fd = FuzzyDate.tryParse(d);
        w.text(3, 'DATE', fd != null ? fd.toGedcom() : '(${d.trim()})');
      }
      final r = s.repository?.trim();
      if (r != null && r.isNotEmpty) w.pointer(1, 'REPO', repos[r]!);
      if (_has(s.notes)) w.text(1, 'NOTE', s.notes);
    }
    for (final e in repos.entries) {
      w.raw(0, 'REPO', xref: e.value);
      w.text(1, 'NAME', e.key);
    }
    w.raw(0, 'TRLR');

    // Citations that could not be placed (stories, relationship links, or
    // facts of anonymised people).
    skippedCitations = data.citations.length - writtenCitations;

    return GedcomExportResult(
      text: w.toString(),
      people: people.length,
      families: fams.length,
      events: eventCount,
      sources: sources.length,
      citations: writtenCitations,
      livingAnonymized: anonymized,
      excludedPeople: data.excludedPeople,
      skippedCitations: skippedCitations < 0 ? 0 : skippedCitations,
      skippedEvents: skippedEvents,
    );
  }

  /// Orders a couple HUSB-first (male, then non-female) for 5.5.1 readers.
  List<String> _ordered(String a, String b) {
    final pa = data.byId[a], pb = data.byId[b];
    if (pa?.gender == Gender.female && pb?.gender != Gender.female) return [b, a];
    return [a, b];
  }

  static bool _has(String? s) => s != null && s.trim().isNotEmpty;

  static String? _join(List<String?> parts) {
    final l = parts.whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (l.length == 2 && l[0].toLowerCase().contains(l[1].toLowerCase())) return l[0];
    return l.isEmpty ? null : l.join(', ');
  }

  static void _date(GedcomWriter w, int level, String? serialized) {
    final d = FuzzyDate.tryParse(serialized);
    if (d == null || d.isEmpty) return;
    w.text(level, 'DATE', d.toGedcom());
  }

  static String _nameWithSurname(String full, String surname) {
    if (full.contains('/')) return full;
    final parts = full.split(RegExp(r'\s+'));
    if (parts.length > 1) {
      final last = parts.removeLast();
      return '${parts.join(' ')} /$last/';
    }
    return '$full //';
  }

  static String _fileSafe(String s) {
    final t = s.replaceAll(RegExp(r'[^A-Za-z0-9 _-]+'), '').trim();
    return t.isEmpty ? 'family' : t;
  }
}
