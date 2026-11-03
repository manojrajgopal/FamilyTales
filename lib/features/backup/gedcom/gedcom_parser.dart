/// GEDCOM 5.5.1 reader: decodes the file, splits it into lines and builds a
/// tree of [GedcomNode]s (levels, cross-references, CONC/CONT continuation).
library;

import 'dart:convert';
import 'dart:typed_data';

/// One GEDCOM line with its subordinate lines.
class GedcomNode {
  GedcomNode(this.level, this.tag, {this.xref, this.value = '', this.line = 0});

  final int level;
  final String tag;

  /// `@I1@` style identifier of a record (level 0) or null.
  final String? xref;

  /// Line value with CONC/CONT already applied (newline for CONT).
  String value;

  /// 1-based line number in the source file.
  final int line;
  final List<GedcomNode> children = [];

  /// True when the value is a pointer such as `@F12@`.
  bool get isPointer => _pointerRe.hasMatch(value);

  /// The pointer value (e.g. `@F12@`) or null.
  String? get pointer => isPointer ? value : null;

  static final _pointerRe = RegExp(r'^@[^@\s][^@]*@$');

  GedcomNode? first(String tag) {
    for (final c in children) {
      if (c.tag == tag) return c;
    }
    return null;
  }

  Iterable<GedcomNode> all(String tag) => children.where((c) => c.tag == tag);

  /// Trimmed value of the first child with [tag] (null when absent/empty).
  String? valueOf(String tag) {
    final v = first(tag)?.value.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Re-serialises this node (and its children) as GEDCOM lines, using
  /// CONT for embedded newlines. Used to preserve unmapped data verbatim.
  List<String> toLines() {
    final out = <String>[];
    void emit(GedcomNode n) {
      final parts = n.value.split('\n');
      final head = StringBuffer('${n.level}');
      if (n.xref != null) head.write(' ${n.xref}');
      head.write(' ${n.tag}');
      if (parts.first.isNotEmpty) head.write(' ${parts.first}');
      out.add(head.toString());
      for (final more in parts.skip(1)) {
        out.add('${n.level + 1} CONT${more.isEmpty ? '' : ' $more'}');
      }
      for (final c in n.children) {
        emit(c);
      }
    }

    emit(this);
    return out;
  }

  @override
  String toString() => '$level ${xref ?? ''} $tag $value'.replaceAll('  ', ' ');
}

/// A parsed GEDCOM file.
class GedcomDocument {
  GedcomDocument(this.records, this.warnings, {this.encoding = 'UTF-8', this.lineCount = 0});

  /// Level-0 records in file order (HEAD, INDI, FAM, SOUR, NOTE, TRLR…).
  final List<GedcomNode> records;
  final List<String> warnings;
  final String encoding;
  final int lineCount;

  late final Map<String, GedcomNode> byXref = {
    for (final r in records)
      if (r.xref != null) r.xref!: r,
  };

  GedcomNode? get head {
    for (final r in records) {
      if (r.tag == 'HEAD') return r;
    }
    return null;
  }

  Iterable<GedcomNode> recordsOf(String tag) => records.where((r) => r.tag == tag);
}

class GedcomParser {
  const GedcomParser._();

  /// Decodes raw file bytes. UTF-8 (with or without BOM) and UTF-16 (with
  /// BOM) are supported; anything else falls back to Latin-1 with a warning.
  static (String text, String encoding) decode(Uint8List bytes, List<String> warnings) {
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      return (utf8.decode(bytes.sublist(3), allowMalformed: true), 'UTF-8');
    }
    if (bytes.length >= 2 &&
        ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
      final little = bytes[0] == 0xFF;
      final units = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        units.add(little ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
      }
      return (String.fromCharCodes(units), 'UTF-16');
    }
    try {
      return (utf8.decode(bytes), 'UTF-8');
    } on FormatException {
      warnings.add('The file is not UTF-8 encoded (probably ANSEL or ANSI). '
          'It was read as Latin-1, so some accented letters may look wrong.');
      return (latin1.decode(bytes), 'Latin-1');
    }
  }

  static GedcomDocument parseBytes(Uint8List bytes) {
    final warnings = <String>[];
    final (text, enc) = decode(bytes, warnings);
    return parse(text, warnings: warnings, encoding: enc);
  }

  static final _lineRe = RegExp(r'^\s*(\d{1,2})\s+(?:(@[^@\s]+@)\s+)?([A-Za-z0-9_]+)(?: (.*))?$');

  static GedcomDocument parse(String text, {List<String>? warnings, String encoding = 'UTF-8'}) {
    final warn = warnings ?? <String>[];
    final records = <GedcomNode>[];
    final stack = <GedcomNode>[];
    final lines = text.split(RegExp(r'\r\n|\r|\n'));
    var bad = 0;
    for (var i = 0; i < lines.length; i++) {
      var raw = lines[i];
      if (i == 0 && raw.startsWith('﻿')) raw = raw.substring(1);
      if (raw.trim().isEmpty) continue;
      final m = _lineRe.firstMatch(raw);
      if (m == null) {
        bad++;
        if (bad <= 5) {
          final s = raw.trim();
          warn.add('Line ${i + 1} is not valid GEDCOM and was skipped: '
              '"${s.length > 60 ? '${s.substring(0, 60)}…' : s}"');
        }
        continue;
      }
      final level = int.parse(m.group(1)!);
      final xref = m.group(2);
      final tag = m.group(3)!.toUpperCase();
      final value = m.group(4) ?? '';

      if (tag == 'CONC' || tag == 'CONT') {
        GedcomNode? parent;
        for (var k = stack.length - 1; k >= 0; k--) {
          if (stack[k].level < level) {
            parent = stack[k];
            break;
          }
        }
        if (parent == null) {
          warn.add('Line ${i + 1}: $tag without a parent line was skipped.');
          continue;
        }
        parent.value += tag == 'CONT' ? '\n$value' : value;
        continue;
      }

      final node = GedcomNode(level, tag, xref: xref, value: value, line: i + 1);
      while (stack.isNotEmpty && stack.last.level >= level) {
        stack.removeLast();
      }
      if (level == 0) {
        records.add(node);
      } else if (stack.isEmpty) {
        warn.add('Line ${i + 1}: "$tag" appears outside any record and was skipped.');
        continue;
      } else {
        if (level > stack.last.level + 1 && bad < 1000) {
          warn.add('Line ${i + 1}: level jumps from ${stack.last.level} to $level.');
        }
        stack.last.children.add(node);
      }
      stack.add(node);
    }
    if (bad > 5) warn.add('${bad - 5} more invalid lines were skipped.');
    // Unescape "@@" in text values.
    void unescape(GedcomNode n) {
      if (!n.isPointer && n.value.contains('@@')) n.value = n.value.replaceAll('@@', '@');
      for (final c in n.children) {
        unescape(c);
      }
    }

    for (final r in records) {
      unescape(r);
    }
    if (records.isEmpty || records.first.tag != 'HEAD') {
      warn.add('The file has no GEDCOM header (HEAD).');
    }
    return GedcomDocument(records, warn, encoding: encoding, lineCount: lines.length);
  }
}
