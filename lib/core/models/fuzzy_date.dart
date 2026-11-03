import 'package:intl/intl.dart';

/// How certain / precise a historical date is.
enum DateQualifier {
  /// The parts that are present are known exactly (day, month/year or year).
  exact,

  /// "About", "circa".
  about,

  /// Before the given date.
  before,

  /// After the given date.
  after,

  /// Between [FuzzyDate.year] … and [FuzzyDate.year2] ….
  between,

  /// Free-text phrase that could not be structured (e.g. imported from GEDCOM).
  text,
}

/// A structured, possibly incomplete date.
///
/// Family history rarely has exact dates. A [FuzzyDate] never invents
/// missing parts: a year-only record stays a year-only record, and is always
/// displayed as such.
///
/// Serialised form (stored in SQLite):
///  * `EX:1950-03-12`, `EX:1950-03`, `EX:1950`
///  * `ABT:1920`, `BEF:1920-03`, `AFT:1900`
///  * `BET:1920|1925-06`
///  * `TXT:Spring, before the war`
class FuzzyDate implements Comparable<FuzzyDate> {
  const FuzzyDate({
    this.qualifier = DateQualifier.exact,
    this.year,
    this.month,
    this.day,
    this.year2,
    this.month2,
    this.day2,
    this.phrase,
  });

  factory FuzzyDate.ymd(int year, [int? month, int? day]) =>
      FuzzyDate(year: year, month: month, day: month == null ? null : day);

  factory FuzzyDate.fromDateTime(DateTime d) =>
      FuzzyDate(year: d.year, month: d.month, day: d.day);

  factory FuzzyDate.text(String phrase) =>
      FuzzyDate(qualifier: DateQualifier.text, phrase: phrase);

  final DateQualifier qualifier;
  final int? year;
  final int? month;
  final int? day;
  final int? year2;
  final int? month2;
  final int? day2;
  final String? phrase;

  static const _codes = {
    DateQualifier.exact: 'EX',
    DateQualifier.about: 'ABT',
    DateQualifier.before: 'BEF',
    DateQualifier.after: 'AFT',
    DateQualifier.between: 'BET',
    DateQualifier.text: 'TXT',
  };

  bool get isEmpty =>
      qualifier == DateQualifier.text
          ? (phrase == null || phrase!.trim().isEmpty)
          : year == null;

  /// True when day, month and year are all known and not qualified.
  bool get isExactDay =>
      qualifier == DateQualifier.exact &&
      year != null &&
      month != null &&
      day != null;

  /// Month and day are known (year may be qualified). Used for anniversaries.
  bool get hasMonthDay =>
      (qualifier == DateQualifier.exact || qualifier == DateQualifier.about) &&
      month != null &&
      day != null;

  /// The most representative year, or null if unknown.
  int? get approxYear {
    if (qualifier == DateQualifier.text) return _yearFromPhrase(phrase);
    if (qualifier == DateQualifier.between && year != null && year2 != null) {
      return ((year! + year2!) / 2).round();
    }
    return year;
  }

  /// A sortable numeric key (yyyyMMdd with fractional adjustments).
  double get sortKey {
    final y = approxYear;
    if (y == null) return double.infinity;
    var k = y * 10000.0 + (month ?? 0) * 100 + (day ?? 0);
    if (qualifier == DateQualifier.before) k -= 0.5;
    if (qualifier == DateQualifier.after) k += 0.5;
    return k;
  }

  DateTime? toDateTime() {
    if (!isExactDay) return null;
    return DateTime(year!, month!, day!);
  }

  String serialize() {
    final code = _codes[qualifier]!;
    if (qualifier == DateQualifier.text) return '$code:${phrase ?? ''}';
    final a = _part(year, month, day);
    if (qualifier == DateQualifier.between) {
      return '$code:$a|${_part(year2, month2, day2)}';
    }
    return '$code:$a';
  }

  static String _part(int? y, int? m, int? d) {
    if (y == null) return '';
    final buf = StringBuffer(y.toString().padLeft(4, '0'));
    if (m != null) {
      buf.write('-${m.toString().padLeft(2, '0')}');
      if (d != null) buf.write('-${d.toString().padLeft(2, '0')}');
    }
    return buf.toString();
  }

  static FuzzyDate? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final idx = raw.indexOf(':');
    if (idx < 0) return null;
    final code = raw.substring(0, idx);
    final body = raw.substring(idx + 1);
    final q = _codes.entries
        .firstWhere((e) => e.value == code,
            orElse: () => const MapEntry(DateQualifier.text, 'TXT'))
        .key;
    if (q == DateQualifier.text) {
      return body.trim().isEmpty ? null : FuzzyDate.text(body);
    }
    if (q == DateQualifier.between) {
      final parts = body.split('|');
      final a = _parsePart(parts.first);
      final b = parts.length > 1 ? _parsePart(parts[1]) : null;
      if (a == null) return null;
      return FuzzyDate(
        qualifier: q,
        year: a.$1,
        month: a.$2,
        day: a.$3,
        year2: b?.$1,
        month2: b?.$2,
        day2: b?.$3,
      );
    }
    final a = _parsePart(body);
    if (a == null) return null;
    return FuzzyDate(qualifier: q, year: a.$1, month: a.$2, day: a.$3);
  }

  static (int, int?, int?)? _parsePart(String s) {
    if (s.isEmpty) return null;
    final p = s.split('-');
    final y = int.tryParse(p[0]);
    if (y == null) return null;
    var m = p.length > 1 ? int.tryParse(p[1]) : null;
    var d = p.length > 2 ? int.tryParse(p[2]) : null;
    // Drop impossible parts (month 13, 31 February) instead of letting
    // DateTime roll them over into another month.
    if (m != null && (m < 1 || m > 12)) m = d = null;
    if (m != null && d != null && (d < 1 || d > _daysIn(y, m))) d = null;
    return (y, m, d);
  }

  static int _daysIn(int y, int m) => DateTime.utc(y, m + 1, 0).day;

  static int? _yearFromPhrase(String? phrase) {
    if (phrase == null) return null;
    final m = RegExp(r'\b(1[0-9]{3}|20[0-9]{2})\b').firstMatch(phrase);
    return m == null ? null : int.parse(m.group(1)!);
  }

  /// Human readable form, e.g. "12 Mar 1950", "c. 1920", "1920 – 1925".
  String format({bool long = false}) {
    if (qualifier == DateQualifier.text) return phrase ?? '';
    final a = _fmt(year, month, day, long);
    switch (qualifier) {
      case DateQualifier.exact:
        return a;
      case DateQualifier.about:
        return 'c. $a';
      case DateQualifier.before:
        return 'before $a';
      case DateQualifier.after:
        return 'after $a';
      case DateQualifier.between:
        final b = _fmt(year2, month2, day2, long);
        return b.isEmpty ? a : '$a – $b';
      case DateQualifier.text:
        return phrase ?? '';
    }
  }

  /// Short year-oriented label for compact UI ("1950", "c.1920", "<1920").
  String formatYear() {
    switch (qualifier) {
      case DateQualifier.text:
        final y = approxYear;
        return y == null ? '?' : '~$y';
      case DateQualifier.exact:
        return year?.toString() ?? '?';
      case DateQualifier.about:
        return 'c.${year ?? '?'}';
      case DateQualifier.before:
        return '<${year ?? '?'}';
      case DateQualifier.after:
        return '>${year ?? '?'}';
      case DateQualifier.between:
        return '${year ?? '?'}–${year2 ?? '?'}';
    }
  }

  static String _fmt(int? y, int? m, int? d, bool long) {
    if (y == null) return '';
    if (m == null) return '$y';
    final dt = DateTime(y, m, d ?? 1);
    if (d == null) return DateFormat(long ? 'MMMM y' : 'MMM y').format(dt);
    return DateFormat(long ? 'd MMMM y' : 'd MMM y').format(dt);
  }

  // ---------------------------------------------------------------- GEDCOM

  static const _gedMonths = [
    'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
    'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
  ];

  String toGedcom() {
    String part(int? y, int? m, int? d) {
      if (y == null) return '';
      final b = StringBuffer();
      if (m != null && m >= 1 && m <= 12) {
        if (d != null) b.write('$d ');
        b.write('${_gedMonths[m - 1]} ');
      }
      b.write(y.toString());
      return b.toString();
    }

    final a = part(year, month, day);
    switch (qualifier) {
      case DateQualifier.exact:
        return a;
      case DateQualifier.about:
        return 'ABT $a';
      case DateQualifier.before:
        return 'BEF $a';
      case DateQualifier.after:
        return 'AFT $a';
      case DateQualifier.between:
        // An open-ended range is just "after" its start.
        return year2 == null ? 'AFT $a' : 'BET $a AND ${part(year2, month2, day2)}';
      case DateQualifier.text:
        return '(${phrase ?? ''})';
    }
  }

  /// Parses a GEDCOM 5.5.1 date value. Unrecognised values are preserved as
  /// a [DateQualifier.text] phrase rather than discarded.
  static FuzzyDate? fromGedcom(String? raw) {
    if (raw == null) return null;
    var s = raw.trim().toUpperCase();
    if (s.isEmpty) return null;
    if (s.startsWith('(') && s.endsWith(')')) {
      return FuzzyDate.text(raw.trim().substring(1, raw.trim().length - 1));
    }
    if (s.startsWith('FROM ') && s.contains(' TO ')) {
      final halves = s.substring(5).split(' TO ');
      final a = _parseGedPart(halves[0].trim());
      final b = _parseGedPart(halves[1].trim());
      if (a != null && b != null) {
        return FuzzyDate(
          qualifier: DateQualifier.between,
          year: a.$1,
          month: a.$2,
          day: a.$3,
          year2: b.$1,
          month2: b.$2,
          day2: b.$3,
        );
      }
      return FuzzyDate.text(raw.trim());
    }
    DateQualifier q = DateQualifier.exact;
    for (final (prefix, qual) in [
      ('ABT ', DateQualifier.about),
      ('EST ', DateQualifier.about),
      ('CAL ', DateQualifier.about),
      ('BEF ', DateQualifier.before),
      ('AFT ', DateQualifier.after),
      ('TO ', DateQualifier.before),
      ('FROM ', DateQualifier.after),
    ]) {
      if (s.startsWith(prefix)) {
        q = qual;
        s = s.substring(prefix.length).trim();
        break;
      }
    }
    if (s.startsWith('BET ') && s.contains(' AND ')) {
      final body = s.substring(4);
      final halves = body.split(' AND ');
      final a = _parseGedPart(halves[0].trim());
      final b = _parseGedPart(halves[1].trim());
      if (a != null && b != null) {
        return FuzzyDate(
          qualifier: DateQualifier.between,
          year: a.$1,
          month: a.$2,
          day: a.$3,
          year2: b.$1,
          month2: b.$2,
          day2: b.$3,
        );
      }
      return FuzzyDate.text(raw.trim());
    }
    final p = _parseGedPart(s);
    if (p == null) return FuzzyDate.text(raw.trim());
    return FuzzyDate(qualifier: q, year: p.$1, month: p.$2, day: p.$3);
  }

  static (int, int?, int?)? _parseGedPart(String s) {
    final tokens = s.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty || tokens.length > 3) return null;
    final y = int.tryParse(tokens.last.split('/').first);
    if (y == null) return null;
    if (tokens.length == 1) return (y, null, null);
    final mi = _gedMonths.indexOf(tokens[tokens.length - 2]);
    if (mi < 0) return null;
    if (tokens.length == 2) return (y, mi + 1, null);
    final d = int.tryParse(tokens[0]);
    if (d == null || d < 1 || d > _daysIn(y, mi + 1)) return null;
    return (y, mi + 1, d);
  }

  FuzzyDate copyWith({
    DateQualifier? qualifier,
    int? year,
    int? month,
    int? day,
  }) =>
      FuzzyDate(
        qualifier: qualifier ?? this.qualifier,
        year: year ?? this.year,
        month: month ?? this.month,
        day: day ?? this.day,
        year2: year2,
        month2: month2,
        day2: day2,
        phrase: phrase,
      );

  @override
  int compareTo(FuzzyDate other) => sortKey.compareTo(other.sortKey);

  @override
  bool operator ==(Object other) =>
      other is FuzzyDate && other.serialize() == serialize();

  @override
  int get hashCode => serialize().hashCode;

  @override
  String toString() => serialize();
}

/// An age or lifespan computed from two fuzzy dates.
class AgeSpan {
  const AgeSpan(this.years, {required this.approximate});
  final int years;
  final bool approximate;

  String format() => approximate ? 'about $years' : '$years';

  /// Computes the span between [from] and [to] (or today). Returns null if
  /// either year is unknown or the result would be nonsensical.
  static AgeSpan? between(FuzzyDate? from, FuzzyDate? to, {DateTime? now}) {
    if (from == null) return null;
    final fy = from.approxYear;
    if (fy == null) return null;
    final today = now ?? DateTime.now();
    final FuzzyDate end = to ?? FuzzyDate.fromDateTime(today);
    final ty = end.approxYear;
    if (ty == null) return null;
    final exact = from.isExactDay && end.isExactDay;
    int years;
    if (exact) {
      final a = from.toDateTime()!;
      final b = end.toDateTime()!;
      years = b.year - a.year;
      if (b.month < a.month || (b.month == a.month && b.day < a.day)) years--;
    } else {
      years = ty - fy;
      if (from.month != null &&
          end.month != null &&
          from.qualifier == DateQualifier.exact &&
          end.qualifier == DateQualifier.exact &&
          from.year != null &&
          end.year != null) {
        if (end.month! < from.month!) years--;
      }
    }
    if (years < 0 || years > 130) return null;
    return AgeSpan(years, approximate: !exact);
  }
}
