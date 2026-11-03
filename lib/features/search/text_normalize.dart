/// Text folding helpers shared by search, insights and duplicate detection.
///
/// [foldText] is *length preserving*: every UTF-16 code unit maps to exactly
/// one code unit, so match offsets found in folded text can be used to
/// highlight the original text.
library;

const _diacriticGroups = <String, String>{
  'a': 'àáâãäåāăąǎ',
  'c': 'çćĉċč',
  'd': 'ďđ',
  'e': 'èéêëēĕėęě',
  'g': 'ĝğġģ',
  'h': 'ĥħ',
  'i': 'ìíîïĩīĭįıǐİ',
  'j': 'ĵ',
  'k': 'ķ',
  'l': 'ĺļľŀł',
  'n': 'ñńņňŉ',
  'o': 'òóôõöøōŏőǒ',
  'r': 'ŕŗř',
  's': 'śŝşšș',
  't': 'ţťŧț',
  'u': 'ùúûüũūŭůűųǔ',
  'w': 'ŵ',
  'y': 'ýÿŷ',
  'z': 'źżž',
};

Map<int, int>? _foldTable;

Map<int, int> get _table {
  final existing = _foldTable;
  if (existing != null) return existing;
  final t = <int, int>{};
  _diacriticGroups.forEach((base, chars) {
    final b = base.codeUnitAt(0);
    for (final u in chars.codeUnits) {
      t[u] = b;
    }
  });
  return _foldTable = t;
}

/// Lower-cases [s] and strips common Latin diacritics, keeping the length
/// unchanged ("Ñuñez" → "nunez").
String foldText(String s) {
  if (s.isEmpty) return s;
  final t = _table;
  final out = List<int>.filled(s.length, 0);
  for (var i = 0; i < s.length; i++) {
    var u = s.codeUnitAt(i);
    // ASCII fast path.
    if (u >= 0x41 && u <= 0x5A) {
      out[i] = u + 32;
      continue;
    }
    if (u < 0x80) {
      out[i] = u;
      continue;
    }
    final mapped = t[u];
    if (mapped != null) {
      out[i] = mapped;
      continue;
    }
    final lower = String.fromCharCode(u).toLowerCase();
    if (lower.length == 1) u = lower.codeUnitAt(0);
    out[i] = t[u] ?? u;
  }
  return String.fromCharCodes(out);
}

final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Canonical comparison key: folded, punctuation removed, whitespace
/// collapsed ("  São  Paulo, " → "sao paulo").
String normalizeKey(String? s) {
  if (s == null) return '';
  return foldText(s).replaceAll(_nonWord, ' ').trim();
}

/// Splits a search query into folded, non-empty tokens.
List<String> queryTokens(String query) => foldText(query)
    .split(RegExp(r'\s+'))
    .map((t) => t.trim())
    .where((t) => t.isNotEmpty)
    .toList();

/// Character ranges of [text] that match any of the (already folded)
/// [tokens], merged and sorted. Used for highlighting.
List<(int, int)> matchRanges(String text, List<String> tokens) {
  if (text.isEmpty || tokens.isEmpty) return const [];
  final folded = foldText(text);
  final ranges = <(int, int)>[];
  for (final t in tokens) {
    if (t.isEmpty) continue;
    var from = 0;
    while (true) {
      final i = folded.indexOf(t, from);
      if (i < 0) break;
      ranges.add((i, i + t.length));
      from = i + t.length;
    }
  }
  if (ranges.isEmpty) return const [];
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[ranges.first];
  for (final r in ranges.skip(1)) {
    final last = merged.last;
    if (r.$1 <= last.$2) {
      merged[merged.length - 1] = (last.$1, r.$2 > last.$2 ? r.$2 : last.$2);
    } else {
      merged.add(r);
    }
  }
  return merged;
}
