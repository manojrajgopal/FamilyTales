/// Maps a parsed GEDCOM 5.5.1 document onto Family Tales records for a NEW
/// tree. Nothing is silently dropped: unsupported tags are counted in the
/// [GedcomImportReport] and their raw lines are appended to the owning
/// record's notes under "Unmapped GEDCOM data".
library;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/models/enums.dart';
import '../../../core/models/fuzzy_date.dart';
import 'gedcom_parser.dart';

String _id() => const Uuid().v4();

/// Heading used when raw GEDCOM lines are preserved in notes.
const unmappedNotesHeading = 'Unmapped GEDCOM data';

/// What happened during an import (shown before and after importing).
class GedcomImportReport {
  int people = 0;
  int families = 0;
  int partnerships = 0;
  int parentLinks = 0;
  int events = 0;
  int sources = 0;
  int citations = 0;
  int customValues = 0;
  int notes = 0;
  int inferredDeceased = 0;
  int unmappedLines = 0;

  /// Tag path (e.g. `INDI.OBJE`) → occurrences.
  final Map<String, int> unsupported = {};

  /// Tag path → up to three example lines.
  final Map<String, List<String>> examples = {};

  /// Administrative tags that carry no family information (CHAN, RIN…).
  final Map<String, int> skippedMetadata = {};
  final List<String> warnings = [];

  int get unsupportedTotal => unsupported.values.fold(0, (a, b) => a + b);

  void addUnsupported(String path, String example) {
    unsupported[path] = (unsupported[path] ?? 0) + 1;
    final ex = examples[path] ??= [];
    if (ex.length < 3) ex.add(example.length > 120 ? '${example.substring(0, 120)}…' : example);
  }

  void addMetadata(String tag) => skippedMetadata[tag] = (skippedMetadata[tag] ?? 0) + 1;

  void warn(String w) {
    if (warnings.length < 200) warnings.add(w);
  }
}

/// Records ready to be inserted into a new tree.
class GedcomImportPlan {
  GedcomImportPlan({required this.treeId, required this.suggestedName, required this.report});

  final String treeId;
  final String suggestedName;
  final GedcomImportReport report;

  final List<PersonsCompanion> persons = [];
  final List<ParentChildLinksCompanion> parentLinks = [];
  final List<PartnershipsCompanion> partnerships = [];
  final List<FamilyEventsCompanion> events = [];
  final List<EventPersonsCompanion> eventPersons = [];
  final List<SourcesCompanion> sources = [];
  final List<CitationsCompanion> citations = [];
  final List<CustomFieldsCompanion> customFields = [];
  final List<PersonCustomValuesCompanion> customValues = [];
  String? homePersonId;

  /// Raw lines of top-level records that have no owner (kept in the tree's
  /// description).
  final List<String> treeUnmapped = [];

  bool get isEmpty => persons.isEmpty;

  String get treeDescription {
    if (treeUnmapped.isEmpty) return 'Imported from GEDCOM';
    var raw = treeUnmapped.join('\n');
    if (raw.length > 50000) raw = '${raw.substring(0, 50000)}\n…';
    return 'Imported from GEDCOM\n\n$unmappedNotesHeading:\n$raw';
  }

  /// Inserts the tree and every record in one transaction. Returns the tree
  /// id.
  Future<String> write(AppDatabase db, {required String treeName}) async {
    final name = treeName.trim().isEmpty ? suggestedName : treeName.trim();
    await db.transaction(() async {
      await db.into(db.familyTrees).insert(FamilyTreesCompanion.insert(
            id: treeId,
            name: name.length > 120 ? name.substring(0, 120) : name,
            description: Value(treeDescription),
            homePersonId: Value(homePersonId),
          ));
      await db.batch((b) {
        b.insertAll(db.persons, persons);
        b.insertAll(db.parentChildLinks, parentLinks);
        b.insertAll(db.partnerships, partnerships);
        b.insertAll(db.familyEvents, events);
        b.insertAll(db.eventPersons, eventPersons, mode: InsertMode.insertOrIgnore);
        b.insertAll(db.sources, sources);
        b.insertAll(db.citations, citations);
        b.insertAll(db.customFields, customFields);
        b.insertAll(db.personCustomValues, customValues, mode: InsertMode.insertOrIgnore);
      });
    });
    return treeId;
  }
}

/// Mutable person under construction.
class _P {
  _P(this.id, this.xref);
  final String id;
  final String xref;
  String first = '';
  String? middle, last, full, birthName, nickname;
  Gender gender = Gender.unknown;
  String? birthDate, birthPlace, birthNotes;
  bool died = false;
  String? deathDate, deathPlace, cause, burialPlace, deathNotes;
  final List<String> occupation = [], education = [], nationality = [];
  String? languages, interests, achievements, pronouns, biography;
  String? email, phone, address;
  bool isPrivate = false;
  final List<String> notes = [];
  final List<String> unmapped = [];
  String? marriedSurname;

  /// FAM xref → pedigree value from INDI.FAMC.PEDI.
  final Map<String, String> pedigree = {};
}

class _EventDraft {
  _EventDraft(this.id, this.type, this.title, this.customLabel, this.date, this.place, this.description);
  final String id;
  final EventType type;
  final String title;
  final String? customLabel;
  final String? date;
  final String? place;
  final String? description;
  final Set<String> people = {};
}

class GedcomImporter {
  GedcomImporter(this.doc, {this.fileName});

  final GedcomDocument doc;
  final String? fileName;

  late final GedcomImportReport _r;
  late final GedcomImportPlan _plan;
  final Map<String, _P> _people = {};
  final Map<String, String> _sourceIds = {};
  final Map<String, _EventDraft> _eventsByKey = {};
  final List<_EventDraft> _events = [];
  final Map<String, String> _customFieldIds = {};

  /// NOTE records that were referenced by something.
  final Set<String> _usedNotes = {};

  /// FAM xref → individuals whose FAMC points at it.
  final Map<String, List<String>> _famcChildren = {};

  static const _metadataTags = {
    'CHAN', 'RIN', '_UID', 'UID', 'REFN', 'RFN', 'AFN', '_UPD', 'SUBM', 'ANCI', 'DESI',
    '_FSFTID', '_FID', 'EXID', 'CREA', '_CREA', '_PRIM', '_TIME',
  };

  /// INDI/FAM event tags → (type, label).
  static const Map<String, (EventType, String)> _eventTags = {
    'ADOP': (EventType.adoption, 'Adoption'),
    'BAPM': (EventType.baptism, 'Baptism'),
    'CHR': (EventType.baptism, 'Christening'),
    'CHRA': (EventType.baptism, 'Adult christening'),
    'BAPL': (EventType.baptism, 'Baptism (LDS)'),
    'BARM': (EventType.custom, 'Bar mitzvah'),
    'BASM': (EventType.custom, 'Bat mitzvah'),
    'BLES': (EventType.custom, 'Blessing'),
    'CONF': (EventType.custom, 'Confirmation'),
    'FCOM': (EventType.custom, 'First communion'),
    'ORDN': (EventType.custom, 'Ordination'),
    'NATU': (EventType.migration, 'Naturalization'),
    'EMIG': (EventType.migration, 'Emigration'),
    'IMMI': (EventType.migration, 'Immigration'),
    'CENS': (EventType.custom, 'Census'),
    'PROB': (EventType.custom, 'Probate'),
    'WILL': (EventType.custom, 'Will'),
    'GRAD': (EventType.graduation, 'Graduation'),
    'RETI': (EventType.retirement, 'Retirement'),
    'CREM': (EventType.burial, 'Cremation'),
    'RESI': (EventType.relocation, 'Residence'),
    '_MILT': (EventType.militaryService, 'Military service'),
    '_MILI': (EventType.militaryService, 'Military service'),
    '_MIL': (EventType.militaryService, 'Military service'),
    'MARB': (EventType.custom, 'Marriage banns'),
    'MARC': (EventType.custom, 'Marriage contract'),
    'MARL': (EventType.custom, 'Marriage licence'),
    'MARS': (EventType.custom, 'Marriage settlement'),
    'DIVF': (EventType.custom, 'Divorce filed'),
    'EVEN': (EventType.custom, 'Event'),
  };

  /// INDI attribute tags stored as custom fields.
  static const Map<String, String> _attributeFields = {
    'RELI': 'Religion',
    'TITL': 'Title',
    'CAST': 'Caste',
    'DSCR': 'Physical description',
    'IDNO': 'ID number',
    'NCHI': 'Number of children',
    'NMR': 'Number of marriages',
    'PROP': 'Possessions',
    'SSN': 'Social security number',
  };

  /// FACT types that map to built-in person fields (written by our exporter).
  static const _factFields = {'languages', 'interests', 'achievements', 'pronouns', 'biography'};

  /// Builds the import plan. Pure: no database access.
  GedcomImportPlan analyze() {
    _r = GedcomImportReport()..warnings.addAll(doc.warnings);
    _plan = GedcomImportPlan(treeId: _id(), suggestedName: _suggestName(), report: _r);

    // Pass 1: create people and sources so pointers resolve.
    for (final rec in doc.recordsOf('INDI')) {
      if (rec.xref == null) {
        _r.warn('An individual record without an identifier (line ${rec.line}) was skipped.');
        continue;
      }
      _people[rec.xref!] = _P(_id(), rec.xref!);
      for (final f in rec.all('FAMC')) {
        (_famcChildren[f.value.trim()] ??= []).add(rec.xref!);
      }
    }
    for (final rec in doc.recordsOf('SOUR')) {
      if (rec.xref != null) _sourceIds[rec.xref!] = _id();
    }

    // Records.
    for (final rec in doc.records) {
      switch (rec.tag) {
        case 'HEAD':
        case 'TRLR':
        case 'NOTE':
        case 'REPO':
          break; // HEAD read for the name; NOTE/REPO resolved on reference
        case 'SUBM':
        case 'SUBN':
          _r.addMetadata(rec.tag);
        case 'INDI':
          final p = rec.xref == null ? null : _people[rec.xref!];
          if (p != null) _individual(rec, p);
        case 'SOUR':
          if (rec.xref != null) _source(rec);
        case 'FAM':
          break; // second pass (needs every pedigree)
        default:
          final lines = rec.toLines();
          _r.addUnsupported(rec.tag, lines.first);
          _r.unmappedLines += lines.length;
          _plan.treeUnmapped.addAll(lines);
      }
    }
    for (final rec in doc.recordsOf('FAM')) {
      _family(rec);
    }
    for (final rec in doc.recordsOf('NOTE')) {
      if (rec.xref != null && !_usedNotes.contains(rec.xref)) {
        final lines = rec.toLines();
        _r.addUnsupported('NOTE (not linked to anyone)', lines.first);
        _r.unmappedLines += lines.length;
        _plan.treeUnmapped.addAll(lines);
      }
    }

    // Flush people.
    final now = DateTime.now().year;
    for (final p in _people.values) {
      var living = !p.died;
      if (living) {
        final by = FuzzyDate.tryParse(p.birthDate)?.approxYear;
        if (by != null && by < now - 110) {
          living = false;
          _r.inferredDeceased++;
        }
      }
      if (p.marriedSurname != null && p.marriedSurname != p.last) {
        p.birthName ??= [p.first, p.middle, p.last].whereType<String>().where((s) => s.isNotEmpty).join(' ');
        p.last = p.marriedSurname;
      }
      final notes = [...p.notes];
      if (p.unmapped.isNotEmpty) {
        notes.add('$unmappedNotesHeading:\n${p.unmapped.join('\n')}');
      }
      _plan.persons.add(PersonsCompanion.insert(
        id: p.id,
        treeId: _plan.treeId,
        firstName: Value(p.first),
        middleName: Value(_nz(p.middle)),
        lastName: Value(_nz(p.last)),
        fullName: Value(_nz(p.full)),
        birthName: Value(_nz(p.birthName)),
        nickname: Value(_nz(p.nickname)),
        gender: Value(p.gender),
        pronouns: Value(p.pronouns),
        birthDate: Value(p.birthDate),
        birthPlace: Value(p.birthPlace),
        birthNotes: Value(p.birthNotes),
        isLiving: Value(living),
        deathDate: Value(p.deathDate),
        deathPlace: Value(p.deathPlace),
        causeOfDeath: Value(p.cause),
        burialPlace: Value(p.burialPlace),
        deathNotes: Value(p.deathNotes),
        occupation: Value(_join(p.occupation)),
        education: Value(_join(p.education)),
        nationality: Value(_join(p.nationality)),
        languages: Value(p.languages),
        interests: Value(p.interests),
        achievements: Value(p.achievements),
        biography: Value(p.biography),
        notes: Value(notes.isEmpty ? null : notes.join('\n\n')),
        email: Value(p.email),
        phone: Value(p.phone),
        address: Value(p.address),
        isPrivate: Value(p.isPrivate),
      ));
      _r.unmappedLines += p.unmapped.length;
    }
    _r.people = _plan.persons.length;
    _plan.homePersonId = _plan.persons.isEmpty ? null : _plan.persons.first.id.value;

    for (final e in _events) {
      _plan.events.add(FamilyEventsCompanion.insert(
        id: e.id,
        treeId: _plan.treeId,
        title: e.title,
        type: Value(e.type),
        customLabel: Value(e.customLabel),
        date: Value(e.date),
        location: Value(e.place),
        description: Value(e.description),
      ));
      for (final pid in e.people) {
        _plan.eventPersons.add(EventPersonsCompanion.insert(eventId: e.id, personId: pid));
      }
    }
    _r.events = _plan.events.length;
    _r.sources = _plan.sources.length;
    _r.citations = _plan.citations.length;
    _r.customValues = _plan.customValues.length;
    _r.partnerships = _plan.partnerships.length;
    _r.parentLinks = _plan.parentLinks.length;
    if (_plan.persons.isEmpty) _r.warn('No individuals were found in this file.');
    return _plan;
  }

  // ------------------------------------------------------------ helpers

  String _suggestName() {
    final f = fileName?.trim();
    if (f != null && f.isNotEmpty) {
      final base = f.replaceAll(RegExp(r'\.(ged|gedcom)$', caseSensitive: false), '');
      final clean = base.replaceAll(RegExp(r'[_]+'), ' ').trim();
      if (clean.isNotEmpty) return clean;
    }
    final head = doc.head;
    final file = head?.valueOf('FILE');
    if (file != null) {
      return file.replaceAll(RegExp(r'\.(ged|gedcom)$', caseSensitive: false), '');
    }
    final src = head?.first('SOUR')?.valueOf('NAME');
    if (src != null) return 'Imported from $src';
    return 'Imported family';
  }

  static String? _nz(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();
  static String? _join(List<String> l) => l.isEmpty ? null : l.join('; ');

  String? _date(GedcomNode? n) {
    final v = n?.value.trim();
    if (v == null || v.isEmpty) return null;
    return FuzzyDate.fromGedcom(v)?.serialize();
  }

  /// Inline or referenced note text.
  String? _noteText(GedcomNode n) {
    if (n.isPointer) {
      _usedNotes.add(n.value);
      final rec = doc.byXref[n.value];
      if (rec == null) {
        _r.warn('Note ${n.value} is referenced but missing.');
        return null;
      }
      return rec.value.trim().isEmpty ? null : rec.value.trim();
    }
    final t = n.value.trim();
    return t.isEmpty ? null : t;
  }

  void _unmappedChild(String ctx, GedcomNode parent, GedcomNode child, List<String> sink) {
    if (_metadataTags.contains(child.tag)) {
      _r.addMetadata(child.tag);
      return;
    }
    final lines = child.toLines();
    _r.addUnsupported('$ctx.${parent.tag}.${child.tag}', lines.first);
    sink.add('${parent.level} ${parent.tag}');
    sink.addAll(lines);
  }

  void _unmapped(String ctx, GedcomNode node, List<String> sink) {
    if (_metadataTags.contains(node.tag)) {
      _r.addMetadata(node.tag);
      return;
    }
    final lines = node.toLines();
    _r.addUnsupported('$ctx.${node.tag}', lines.first);
    sink.addAll(lines);
  }

  void _cite(GedcomNode s, String entityType, String entityId, String fact, List<String> sink) {
    String? sourceId;
    if (s.isPointer) {
      sourceId = _sourceIds[s.value];
      if (sourceId == null) {
        _r.warn('Source ${s.value} is referenced but missing.');
        return;
      }
    } else {
      final title = s.value.trim();
      if (title.isEmpty) return;
      sourceId = _id();
      final text = s.valueOf('TEXT');
      _plan.sources.add(SourcesCompanion.insert(
        id: sourceId,
        treeId: _plan.treeId,
        title: title.length > 200 ? '${title.substring(0, 200)}…' : title,
        notes: Value(text ?? (title.length > 200 ? title : null)),
      ));
    }
    final details = <String>[];
    var confidence = 2;
    for (final c in s.children) {
      switch (c.tag) {
        case 'PAGE':
          if (c.value.trim().isNotEmpty) details.add(c.value.trim());
        case 'QUAY':
          confidence = (int.tryParse(c.value.trim()) ?? 2).clamp(0, 3);
        case 'NOTE':
          final t = _noteText(c);
          if (t != null) details.add(t);
        case 'TEXT':
          if (c.value.trim().isNotEmpty) details.add(c.value.trim());
        case 'DATA':
          for (final d in c.children) {
            if (d.tag == 'TEXT' && d.value.trim().isNotEmpty) {
              details.add(d.value.trim());
            } else if (d.tag == 'DATE' && d.value.trim().isNotEmpty) {
              details.add('Recorded ${d.value.trim()}');
            } else {
              _unmappedChild('SOUR', c, d, sink);
            }
          }
        default:
          _unmappedChild('CITATION', s, c, sink);
      }
    }
    _plan.citations.add(CitationsCompanion.insert(
      id: _id(),
      sourceId: sourceId,
      entityType: entityType,
      entityId: entityId,
      fact: Value(fact),
      detail: Value(details.isEmpty ? null : details.join('\n')),
      confidence: Value(confidence),
    ));
  }

  String? _customField(String name) {
    final key = name.trim().toLowerCase();
    if (key.isEmpty) return null;
    return _customFieldIds.putIfAbsent(key, () {
      final id = _id();
      _plan.customFields.add(CustomFieldsCompanion.insert(
        id: id,
        treeId: _plan.treeId,
        name: name.trim(),
        sortOrder: Value(_customFieldIds.length),
      ));
      return id;
    });
  }

  void _setCustom(_P p, String fieldName, String value) {
    final fid = _customField(fieldName);
    if (fid == null || value.trim().isEmpty) return;
    final existing = _plan.customValues.indexWhere(
        (v) => v.personId.value == p.id && v.fieldId.value == fid);
    if (existing >= 0) {
      final old = _plan.customValues[existing];
      _plan.customValues[existing] =
          old.copyWith(value: Value('${old.value.value}; ${value.trim()}'));
    } else {
      _plan.customValues.add(
          PersonCustomValuesCompanion.insert(personId: p.id, fieldId: fid, value: value.trim()));
    }
  }

  // ------------------------------------------------------------- INDI

  void _individual(GedcomNode rec, _P p) {
    var primaryName = true;
    for (final c in rec.children) {
      switch (c.tag) {
        case 'NAME':
          _name(c, p, primaryName);
          primaryName = false;
        case 'SEX':
          p.gender = switch (c.value.trim().toUpperCase()) {
            'M' => Gender.male,
            'F' => Gender.female,
            'X' => (c.valueOf('TYPE') ?? '').toLowerCase().replaceAll(RegExp('[^a-z]'), '') == 'nonbinary'
                ? Gender.nonBinary
                : Gender.other,
            _ => Gender.unknown,
          };
        case 'BIRT':
          _vital(c, p, birth: true);
        case 'DEAT':
          p.died = true;
          _vital(c, p, birth: false);
        case 'BURI':
          p.died = true;
          final place = c.valueOf('PLAC');
          if (place != null) p.burialPlace = place;
          final hasMore = c.children.any((x) => x.tag != 'PLAC');
          if (hasMore) _personEvent(c, p, EventType.burial, 'Burial');
        case 'CREM':
          p.died = true;
          _personEvent(c, p, EventType.burial, 'Cremation');
        case 'OCCU':
        case 'EDUC':
        case 'NATI':
          final v = c.value.trim();
          if (v.isNotEmpty) {
            (c.tag == 'OCCU' ? p.occupation : c.tag == 'EDUC' ? p.education : p.nationality).add(v);
          }
          for (final x in c.children) {
            if (x.tag == 'SOUR') {
              _cite(x, 'person', p.id, 'general', p.unmapped);
            } else if (x.tag == 'NOTE') {
              final t = _noteText(x);
              if (t != null) p.notes.add(t);
            } else {
              _unmappedChild('INDI', c, x, p.unmapped);
            }
          }
        case 'FACT':
          final type = c.valueOf('TYPE') ?? 'Fact';
          final v = c.value.trim();
          final lower = type.toLowerCase();
          if (_factFields.contains(lower)) {
            switch (lower) {
              case 'languages':
                p.languages = v;
              case 'interests':
                p.interests = v;
              case 'achievements':
                p.achievements = v;
              case 'pronouns':
                p.pronouns = v;
              case 'biography':
                p.biography = v;
            }
          } else {
            _setCustom(p, type, v);
          }
          for (final x in c.children) {
            if (x.tag == 'TYPE') continue;
            if (x.tag == 'SOUR') {
              _cite(x, 'person', p.id, 'general', p.unmapped);
            } else {
              _unmappedChild('INDI', c, x, p.unmapped);
            }
          }
        case 'RESI':
          if (_isContactOnly(c)) {
            _contact(c, p);
          } else {
            _personEvent(c, p, EventType.relocation, 'Residence');
          }
        case 'NOTE':
          final t = _noteText(c);
          if (t != null) {
            p.notes.add(t);
            _r.notes++;
          }
          for (final x in c.children) {
            if (x.tag != 'CONC' && x.tag != 'CONT') _unmappedChild('INDI', c, x, p.unmapped);
          }
        case 'SOUR':
          _cite(c, 'person', p.id, 'general', p.unmapped);
        case 'FAMC':
          final fam = c.value.trim();
          final pedi = c.valueOf('PEDI');
          if (pedi != null) p.pedigree[fam] = pedi;
          for (final x in c.children) {
            if (x.tag != 'PEDI') _unmappedChild('INDI', c, x, p.unmapped);
          }
        case 'FAMS':
          for (final x in c.children) {
            _unmappedChild('INDI', c, x, p.unmapped);
          }
        case '_MARNM':
          final v = c.value.replaceAll('/', '').trim();
          if (v.isNotEmpty) p.marriedSurname = v;
        case 'RESN':
          final v = c.value.trim().toLowerCase();
          if (v == 'privacy' || v == 'confidential') p.isPrivate = true;
        case 'EMAIL':
          p.email ??= _nz(c.value);
        case 'PHON':
          p.phone ??= _nz(c.value);
        case 'ADDR':
          p.address ??= _address(c);
        default:
          if (_attributeFields.containsKey(c.tag)) {
            _setCustom(p, _attributeFields[c.tag]!, c.value);
            for (final x in c.children) {
              if (x.tag == 'SOUR') {
                _cite(x, 'person', p.id, 'general', p.unmapped);
              } else {
                _unmappedChild('INDI', c, x, p.unmapped);
              }
            }
          } else if (_eventTags.containsKey(c.tag)) {
            final (type, label) = _eventTags[c.tag]!;
            _personEvent(c, p, type, label);
          } else {
            _unmapped('INDI', c, p.unmapped);
          }
      }
    }
  }

  void _name(GedcomNode n, _P p, bool primary) {
    final raw = n.value.trim();
    String given = raw, surname = '', suffix = '';
    final m = RegExp(r'^(.*?)\s*/([^/]*)/\s*(.*)$').firstMatch(raw);
    if (m != null) {
      given = m.group(1)!.trim();
      surname = m.group(2)!.trim();
      suffix = m.group(3)!.trim();
    }
    final givn = n.valueOf('GIVN');
    final surn = n.valueOf('SURN');
    if (givn != null && given.isEmpty) given = givn;
    if (surn != null && surname.isEmpty) surname = surn;
    final npfx = n.valueOf('NPFX');
    final nsfx = n.valueOf('NSFX') ?? (suffix.isEmpty ? null : suffix);
    final type = n.valueOf('TYPE')?.toLowerCase();
    final display = [npfx, given, surname, nsfx].whereType<String>().where((s) => s.isNotEmpty).join(' ');

    if (primary) {
      final tokens = given.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
      p.first = tokens.isEmpty ? '' : tokens.first;
      p.middle = tokens.length > 1 ? tokens.sublist(1).join(' ') : null;
      p.last = surname.isEmpty ? null : surname;
      if (npfx != null || nsfx != null) p.full = display;
    } else if (type == 'birth' || type == 'maiden') {
      p.birthName ??= display;
    } else if (type == 'married' && surname.isNotEmpty) {
      p.marriedSurname ??= surname;
    } else if ((type == 'aka' || type == 'nickname') && p.nickname == null) {
      p.nickname = display;
    } else if (display.isNotEmpty) {
      p.notes.add('Also known as: $display${type == null ? '' : ' ($type)'}');
    }

    for (final c in n.children) {
      switch (c.tag) {
        case 'GIVN':
        case 'SURN':
        case 'NPFX':
        case 'NSFX':
        case 'SPFX':
        case 'TYPE':
          break;
        case 'NICK':
          if (c.value.trim().isNotEmpty) p.nickname ??= c.value.trim();
        case '_MARNM':
          final v = c.value.replaceAll('/', '').trim();
          if (v.isNotEmpty) p.marriedSurname = v;
        case 'SOUR':
          _cite(c, 'person', p.id, 'name', p.unmapped);
        case 'NOTE':
          final t = _noteText(c);
          if (t != null) p.notes.add(t);
        default:
          _unmappedChild('INDI', n, c, p.unmapped);
      }
    }
  }

  void _vital(GedcomNode n, _P p, {required bool birth}) {
    final fact = birth ? 'birth' : 'death';
    final notes = <String>[];
    for (final c in n.children) {
      switch (c.tag) {
        case 'DATE':
          final d = _date(c);
          if (birth) {
            p.birthDate ??= d;
          } else {
            p.deathDate ??= d;
          }
        case 'PLAC':
          final v = _nz(c.value);
          if (birth) {
            p.birthPlace ??= v;
          } else {
            p.deathPlace ??= v;
          }
          for (final x in c.children) {
            _unmappedChild('INDI.${n.tag}', c, x, p.unmapped);
          }
        case 'ADDR':
          final a = _address(c);
          if (birth) {
            p.birthPlace ??= a;
          } else {
            p.deathPlace ??= a;
          }
        case 'CAUS':
          if (!birth) p.cause = _nz(c.value);
        case 'NOTE':
          final t = _noteText(c);
          if (t != null) notes.add(t);
        case 'SOUR':
          _cite(c, 'person', p.id, fact, p.unmapped);
        case 'TYPE':
          if (c.value.trim().isNotEmpty) notes.add(c.value.trim());
        default:
          _unmappedChild('INDI', n, c, p.unmapped);
      }
    }
    if (notes.isNotEmpty) {
      if (birth) {
        p.birthNotes = notes.join('\n');
      } else {
        p.deathNotes = notes.join('\n');
      }
    }
  }

  bool _isContactOnly(GedcomNode n) =>
      n.children.isNotEmpty &&
      n.children.every((c) => const {'ADDR', 'PHON', 'EMAIL', 'WWW', 'FAX'}.contains(c.tag)) &&
      n.value.trim().isEmpty;

  void _contact(GedcomNode n, _P p) {
    for (final c in n.children) {
      switch (c.tag) {
        case 'ADDR':
          p.address ??= _address(c);
        case 'PHON':
          p.phone ??= _nz(c.value);
        case 'EMAIL':
          p.email ??= _nz(c.value);
        default:
          _unmappedChild('INDI', n, c, p.unmapped);
      }
    }
  }

  String? _address(GedcomNode a) {
    final parts = <String>[
      if (a.value.trim().isNotEmpty) a.value.trim(),
      for (final t in ['ADR1', 'ADR2', 'ADR3', 'CITY', 'STAE', 'POST', 'CTRY'])
        if (a.valueOf(t) != null && !a.value.contains(a.valueOf(t)!)) a.valueOf(t)!,
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// Creates (or joins) an event for one person.
  void _personEvent(GedcomNode n, _P p, EventType type, String label) {
    final e = _event(n, type, label, 'INDI', p.unmapped);
    e.people.add(p.id);
  }

  _EventDraft _event(GedcomNode n, EventType type, String label, String ctx, List<String> sink) {
    var t = type;
    String? custom = t == EventType.custom ? label : null;
    String? typeText;
    final desc = <String>[];
    String? date, place;
    final cites = <GedcomNode>[];
    for (final c in n.children) {
      switch (c.tag) {
        case 'TYPE':
          typeText = _nz(c.value);
        case 'DATE':
          date = _date(c);
        case 'PLAC':
          place = _nz(c.value);
          for (final x in c.children) {
            _unmappedChild('$ctx.${n.tag}', c, x, sink);
          }
        case 'ADDR':
          place ??= _address(c);
        case 'NOTE':
          final tx = _noteText(c);
          if (tx != null) desc.add(tx);
        case 'CAUS':
          if (c.value.trim().isNotEmpty) desc.add('Cause: ${c.value.trim()}');
        case 'AGNC':
          if (c.value.trim().isNotEmpty) desc.add('Agency: ${c.value.trim()}');
        case 'SOUR':
          cites.add(c);
        default:
          _unmappedChild(ctx, n, c, sink);
      }
    }
    if (n.tag == 'EVEN') {
      final label2 = typeText ?? 'Event';
      final match = EventType.values.where((e) =>
          e != EventType.custom &&
          (e.label.toLowerCase() == label2.toLowerCase() || e.name.toLowerCase() == label2.toLowerCase()));
      if (match.isNotEmpty) {
        t = match.first;
        custom = null;
      } else {
        t = EventType.custom;
        custom = label2;
      }
      label = label2;
    } else if (typeText != null) {
      desc.insert(0, typeText);
    }
    final v = n.value.trim();
    final title = (v.isNotEmpty && v.toUpperCase() != 'Y') ? v : label;
    final description = desc.isEmpty ? null : desc.join('\n');
    final key = [n.tag, t.name, custom, title, date, place, description].join('|');
    var e = _eventsByKey[key];
    if (e == null) {
      e = _EventDraft(_id(), t, title.length > 200 ? title.substring(0, 200) : title, custom, date, place,
          description);
      _eventsByKey[key] = e;
      _events.add(e);
      for (final s in cites) {
        _cite(s, 'event', e.id, 'general', sink);
      }
    }
    return e;
  }

  // -------------------------------------------------------------- SOUR

  void _source(GedcomNode rec) {
    final id = _sourceIds[rec.xref!]!;
    String? title, author, date, repo;
    var type = SourceType.document;
    final notes = <String>[];
    final unmapped = <String>[];
    for (final c in rec.children) {
      switch (c.tag) {
        case 'TITL':
          title = _nz(c.value);
        case 'ABBR':
          title ??= _nz(c.value);
        case 'AUTH':
          author = _nz(c.value);
        case 'PUBL':
          if (c.value.trim().isNotEmpty) notes.add('Publication: ${c.value.trim()}');
        case 'TEXT':
          if (c.value.trim().isNotEmpty) notes.add(c.value.trim());
        case 'NOTE':
          final t = _noteText(c);
          if (t != null) notes.add(t);
        case 'DATE':
          date ??= _date(c);
        case '_TYPE':
          final v = c.value.trim().toLowerCase();
          type = SourceType.values.firstWhere(
              (s) => s.name.toLowerCase() == v || s.label.toLowerCase() == v,
              orElse: () => SourceType.document);
        case 'DATA':
          for (final d in c.children) {
            if (d.tag == 'DATE') {
              date ??= _date(d);
            } else if (d.tag == 'EVEN') {
              final dd = d.first('DATE');
              if (dd != null) date ??= _date(dd);
              if (d.value.trim().isNotEmpty) notes.add('Events recorded: ${d.value.trim()}');
            } else if (d.tag == 'AGNC') {
              if (d.value.trim().isNotEmpty) notes.add('Agency: ${d.value.trim()}');
            } else if (d.tag == 'NOTE') {
              final t = _noteText(d);
              if (t != null) notes.add(t);
            } else {
              _unmappedChild('SOUR', c, d, unmapped);
            }
          }
        case 'REPO':
          if (c.isPointer) {
            repo ??= doc.byXref[c.value]?.valueOf('NAME');
          } else {
            repo ??= c.valueOf('NAME') ?? _nz(c.value);
          }
          final call = c.first('CALN');
          if (call != null && call.value.trim().isNotEmpty) notes.add('Call number: ${call.value.trim()}');
          final medi = call?.valueOf('MEDI')?.toLowerCase();
          if (medi != null) {
            type = switch (medi) {
              'book' => SourceType.book,
              'census' => SourceType.census,
              'photo' => SourceType.photograph,
              'letter' => SourceType.letter,
              _ => type,
            };
          }
        default:
          _unmapped('SOUR', c, unmapped);
      }
    }
    if (unmapped.isNotEmpty) {
      notes.add('$unmappedNotesHeading:\n${unmapped.join('\n')}');
      _r.unmappedLines += unmapped.length;
    }
    _plan.sources.add(SourcesCompanion.insert(
      id: id,
      treeId: _plan.treeId,
      title: title ?? (_nz(rec.value) ?? 'Untitled source'),
      type: Value(type),
      author: Value(author),
      repository: Value(repo),
      date: Value(date),
      notes: Value(notes.isEmpty ? null : notes.join('\n\n')),
    ));
  }

  // --------------------------------------------------------------- FAM

  static ParentType? _pedigreeType(String raw, GedcomImportReport r) {
    final v = raw.trim().toLowerCase();
    switch (v) {
      case '':
        return null;
      case 'birth':
      case 'natural':
      case 'biological':
        return ParentType.biological;
      case 'adopted':
      case 'adoptive':
        return ParentType.adoptive;
      case 'foster':
        return ParentType.foster;
      case 'step':
      case 'stepchild':
      case 'step-child':
        return ParentType.step;
      case 'guardian':
      case 'legal guardian':
        return ParentType.guardian;
      case 'unknown':
      case 'sealing':
        return ParentType.unknown;
      default:
        r.addUnsupported('PEDI.$v', 'PEDI $raw');
        return ParentType.unknown;
    }
  }

  final Map<String, int> _bioCount = {};
  final Set<String> _linkKeys = {};
  final Map<String, Set<String>> _childrenOf = {};

  bool _isDescendant(String id, {required String of}) {
    final seen = <String>{of};
    final stack = [of];
    while (stack.isNotEmpty) {
      for (final c in _childrenOf[stack.removeLast()] ?? const <String>{}) {
        if (c == id) return true;
        if (seen.add(c)) stack.add(c);
      }
    }
    return false;
  }

  void _addLink(String parentId, String childId, ParentType type) {
    if (parentId == childId) {
      _r.warn('A person was listed as their own parent; the link was skipped.');
      return;
    }
    if (_isDescendant(parentId, of: childId)) {
      _r.warn('A person was listed as their own ancestor; the looping link was skipped.');
      return;
    }
    if (!_linkKeys.add('$parentId>$childId')) return;
    (_childrenOf[parentId] ??= {}).add(childId);
    var t = type;
    if (t == ParentType.biological) {
      final n = _bioCount[childId] ?? 0;
      if (n >= 2) {
        t = ParentType.unknown;
        _r.warn('A person has more than two birth parents; the extra link was imported as "Unspecified".');
      } else {
        _bioCount[childId] = n + 1;
      }
    }
    _plan.parentLinks.add(ParentChildLinksCompanion.insert(
      id: _id(),
      treeId: _plan.treeId,
      parentId: parentId,
      childId: childId,
      type: Value(t),
    ));
  }

  void _family(GedcomNode rec) {
    _r.families++;
    final xref = rec.xref;
    _P? person(GedcomNode? n) {
      if (n == null) return null;
      final p = _people[n.value.trim()];
      if (p == null) _r.warn('Family ${xref ?? ''} refers to a missing person ${n.value}.');
      return p;
    }

    final husb = person(rec.first('HUSB'));
    final wife = person(rec.first('WIFE'));
    final parents = [?husb, ?wife];
    final firstParent = parents.isEmpty ? null : parents.first;
    final sink = <String>[];

    // Children: FAM.CHIL plus individuals whose FAMC points here.
    final children = <String, ({String? frel, String? mrel})>{};
    for (final c in rec.all('CHIL')) {
      final p = _people[c.value.trim()];
      if (p == null) {
        _r.warn('Family ${xref ?? ''} lists a missing child ${c.value}.');
        continue;
      }
      children[p.xref] = (frel: c.valueOf('_FREL'), mrel: c.valueOf('_MREL'));
      for (final x in c.children) {
        if (x.tag != '_FREL' && x.tag != '_MREL') _unmappedChild('FAM', c, x, sink);
      }
    }
    if (xref != null) {
      for (final c in _famcChildren[xref] ?? const <String>[]) {
        children.putIfAbsent(c, () => (frel: null, mrel: null));
      }
    }
    for (final e in children.entries) {
      final child = _people[e.key];
      if (child == null) continue;
      final pedi = xref == null ? null : child.pedigree[xref];
      final base = pedi == null ? ParentType.biological : (_pedigreeType(pedi, _r) ?? ParentType.biological);
      if (husb != null) {
        final t = e.value.frel == null ? base : (_pedigreeType(e.value.frel!, _r) ?? base);
        _addLink(husb.id, child.id, t);
      }
      if (wife != null) {
        final t = e.value.mrel == null ? base : (_pedigreeType(e.value.mrel!, _r) ?? base);
        _addLink(wife.id, child.id, t);
      }
    }

    // Couple.
    GedcomNode? marr, enga, div, anul, sepr, partStart;
    String? stat;
    final notes = <String>[];
    final famCites = <(GedcomNode, String)>[];
    final famEvents = <_EventDraft>[];
    for (final c in rec.children) {
      switch (c.tag) {
        case 'HUSB':
        case 'WIFE':
        case 'CHIL':
          break;
        case 'MARR':
          marr ??= c;
        case 'ENGA':
          enga ??= c;
        case 'DIV':
          div ??= c;
        case 'ANUL':
          anul ??= c;
        case '_SEPR':
        case 'SEPR':
          sepr ??= c;
        case '_STAT':
          stat = c.value.trim().toLowerCase();
          final d = c.first('DATE');
          if (d != null) sepr ??= c;
        case 'NOTE':
          final t = _noteText(c);
          if (t != null) notes.add(t);
        case 'SOUR':
          famCites.add((c, 'general'));
        case 'NCHI':
          _r.addMetadata('NCHI');
        default:
          final evType = c.tag == 'EVEN' ? c.valueOf('TYPE')?.toLowerCase() : null;
          if (evType == 'separation' && sepr == null) {
            sepr = c;
          } else if (evType == 'partnership' && partStart == null) {
            partStart = c;
          } else if (_eventTags.containsKey(c.tag)) {
            final (type, label) = _eventTags[c.tag]!;
            final e = _event(c, type, label, 'FAM', sink);
            famEvents.add(e);
          } else {
            _unmapped('FAM', c, sink);
          }
      }
    }
    for (final e in famEvents) {
      for (final p in parents) {
        e.people.add(p.id);
      }
    }

    const noCouple = {'never married', 'not married', 'single', 'none', 'friends', 'not a couple'};
    String? partnershipId;
    if (husb != null && wife != null && husb.id != wife.id && !noCouple.contains(stat)) {
      var type = PartnerType.marriage;
      final marrType = marr?.valueOf('TYPE')?.toLowerCase() ?? '';
      if (stat == 'partners' || stat == 'partner' || stat == 'unmarried' ||
          RegExp(r'partner|common|unmarried|cohabit').hasMatch(marrType)) {
        type = PartnerType.partner;
      } else if (RegExp(r'civil|union|registered').hasMatch(marrType)) {
        type = PartnerType.civilUnion;
      } else if (marr == null && (enga != null || stat == 'engaged')) {
        type = PartnerType.engaged;
      }
      var status = PartnerStatus.current;
      String? end;
      if (div != null || stat == 'divorced') {
        status = PartnerStatus.divorced;
        end = _date(div?.first('DATE'));
      } else if (anul != null || stat == 'annulled') {
        status = PartnerStatus.annulled;
        end = _date(anul?.first('DATE'));
      } else if (sepr != null || stat == 'separated') {
        status = stat == 'widowed'
            ? PartnerStatus.widowed
            : stat == 'ended'
                ? PartnerStatus.ended
                : PartnerStatus.separated;
        end = _date(sepr?.first('DATE'));
      } else if (stat == 'widowed') {
        status = PartnerStatus.widowed;
      } else if (stat == 'ended') {
        status = PartnerStatus.ended;
      }
      final startNode = type == PartnerType.engaged
          ? enga
          : type == PartnerType.partner
              ? (partStart ?? marr ?? enga)
              : (marr ?? enga ?? partStart);
      final start = _date(startNode?.first('DATE'));
      final place = _nz(startNode?.valueOf('PLAC'));
      partnershipId = _id();

      // Sub-structures of the couple events.
      for (final ev in [marr, enga, div, anul, sepr, partStart].whereType<GedcomNode>()) {
        for (final c in ev.children) {
          switch (c.tag) {
            case 'DATE':
            case 'TYPE':
              break;
            case 'PLAC':
              if (ev != startNode) {
                notes.add('${_tagLabel(ev.tag)} place: ${c.value.trim()}');
              }
            case 'NOTE':
              final t = _noteText(c);
              if (t != null) notes.add(t);
            case 'SOUR':
              famCites.add((c, ev.tag == 'MARR' ? 'marriage' : ev.tag.toLowerCase()));
            default:
              _unmappedChild('FAM', ev, c, sink);
          }
        }
        if (ev == enga && type != PartnerType.engaged && marr != null) {
          final d = ev.valueOf('DATE');
          if (d != null) notes.add('Engaged: $d');
        }
      }
      if (sink.isNotEmpty) {
        notes.add('$unmappedNotesHeading:\n${sink.join('\n')}');
        _r.unmappedLines += sink.length;
      }
      _plan.partnerships.add(PartnershipsCompanion.insert(
        id: partnershipId,
        treeId: _plan.treeId,
        personAId: husb.id,
        personBId: wife.id,
        type: Value(type),
        status: Value(status),
        startDate: Value(start),
        endDate: Value(end),
        place: Value(place),
        notes: Value(notes.isEmpty ? null : notes.join('\n\n')),
      ));
      for (final (s, fact) in famCites) {
        _cite(s, 'partnership', partnershipId, fact, firstParent!.unmapped);
      }
    } else {
      // No couple record: keep notes / unmapped data on a parent.
      for (final ev in [marr, enga, div, anul, sepr, partStart].whereType<GedcomNode>()) {
        _unmapped('FAM', ev, sink);
      }
      if (firstParent != null) {
        for (final n in notes) {
          firstParent.notes.add(n);
        }
        firstParent.unmapped.addAll(sink);
        for (final (s, _) in famCites) {
          _cite(s, 'person', firstParent.id, 'general', firstParent.unmapped);
        }
      } else if (sink.isNotEmpty || notes.isNotEmpty) {
        _r.warn('Family ${xref ?? ''} has no parents; its notes could not be attached.');
      }
    }
  }

  static String _tagLabel(String tag) => switch (tag) {
        'MARR' => 'Marriage',
        'ENGA' => 'Engagement',
        'DIV' => 'Divorce',
        'ANUL' => 'Annulment',
        _ => 'Separation',
      };
}
