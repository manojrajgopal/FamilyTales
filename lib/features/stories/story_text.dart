import 'package:flutter/services.dart';

/// Plain-text helpers for the lightweight story markdown (headings, bold,
/// italic, quotes and bullet lists).
abstract final class StoryText {
  /// `**bold**`, `__bold__`, `*italic*`, `_italic_` (underscores only at word
  /// boundaries so names like snake_case stay intact).
  static final inlinePattern = RegExp(
    r'\*\*(.+?)\*\*'
    r'|__(.+?)__'
    r'|(?<![\w*])\*(?![\s*])(.+?)(?<![\s*])\*(?![\w*])'
    r'|(?<![A-Za-z0-9_])_(?![\s_])(.+?)(?<![\s_])_(?![A-Za-z0-9_])',
  );

  static final _heading = RegExp(r'^\s{0,3}#{1,6}\s+');
  static final _quote = RegExp(r'^\s{0,3}>\s?');
  static final _bullet = RegExp(r'^\s{0,3}[-*•]\s+');

  static String stripInline(String s) =>
      s.replaceAllMapped(inlinePattern, (m) => m[1] ?? m[2] ?? m[3] ?? m[4] ?? '');

  /// Readable plain text (for sharing): markers removed, bullets as "•".
  static String toPlain(String body) {
    final out = <String>[];
    for (final raw in body.replaceAll('\r\n', '\n').split('\n')) {
      var line = raw.trimRight();
      if (_heading.hasMatch(line)) {
        line = line.replaceFirst(_heading, '');
      } else if (_quote.hasMatch(line)) {
        line = line.replaceFirst(_quote, '    ');
      } else if (_bullet.hasMatch(line)) {
        line = line.replaceFirst(_bullet, '• ');
      }
      out.add(stripInline(line));
    }
    return out.join('\n').trim();
  }

  /// Single-paragraph excerpt for cards.
  static String excerpt(String body, {int max = 220}) {
    final flat = toPlain(body).replaceAll('• ', '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= max) return flat;
    final cut = flat.substring(0, max);
    final space = cut.lastIndexOf(' ');
    return '${(space > max * 0.6 ? cut.substring(0, space) : cut).trimRight()}…';
  }

  static final _word = RegExp(r"[\p{L}\p{N}][\p{L}\p{N}'’\-]*", unicode: true);

  static int wordCount(String body) => _word.allMatches(toPlain(body)).length;

  /// Minutes to read at ~200 words per minute (at least 1).
  static int readingMinutes(String body) {
    final w = wordCount(body);
    return w == 0 ? 0 : (w / 200).ceil();
  }
}

/// Markdown insertion used by the story editor toolbar. Pure functions on
/// [TextEditingValue], so they are easy to test.
abstract final class MarkdownEditing {
  static TextSelection _sel(TextEditingValue v) => v.selection.isValid
      ? v.selection
      : TextSelection.collapsed(offset: v.text.length);

  /// Wraps the selection in [marker] (e.g. `**`), or removes it when the
  /// selection is already wrapped. With no selection, inserts a pair and
  /// puts the caret between them.
  static TextEditingValue wrap(TextEditingValue v, String marker) {
    final text = v.text;
    final sel = _sel(v);
    final start = sel.start, end = sel.end;
    final n = marker.length;
    final wrapped = start >= n &&
        end + n <= text.length &&
        text.substring(start - n, start) == marker &&
        text.substring(end, end + n) == marker;
    if (wrapped) {
      final t = text.replaceRange(end, end + n, '').replaceRange(start - n, start, '');
      return TextEditingValue(
        text: t,
        selection: TextSelection(baseOffset: start - n, extentOffset: end - n),
      );
    }
    final inner = text.substring(start, end);
    final t = text.replaceRange(start, end, '$marker$inner$marker');
    return TextEditingValue(
      text: t,
      selection: inner.isEmpty
          ? TextSelection.collapsed(offset: start + n)
          : TextSelection(baseOffset: start + n, extentOffset: end + n),
    );
  }

  /// Toggles a line prefix (`## `, `> `, `- `) on every line touched by the
  /// selection, replacing any other block prefix on those lines.
  static TextEditingValue linePrefix(TextEditingValue v, String prefix) {
    final text = v.text;
    final sel = _sel(v);
    final lineStart = sel.start == 0 ? 0 : text.lastIndexOf('\n', sel.start - 1) + 1;
    var lineEnd = text.indexOf('\n', sel.end);
    if (lineEnd < 0) lineEnd = text.length;
    final block = text.substring(lineStart, lineEnd);
    final lines = block.split('\n');
    final content = lines.where((l) => l.trim().isNotEmpty).toList();
    final allHave = content.isNotEmpty && content.every((l) => l.startsWith(prefix));
    // A line has one block style: applying a new one replaces the old.
    final existing = RegExp(r'^(#{1,6} |> ?|[-*•] )');
    final next = [
      for (final l in lines)
        if (allHave)
          (l.startsWith(prefix) ? l.substring(prefix.length) : l)
        else if (l.trim().isEmpty && lines.length > 1)
          l
        else
          '$prefix${l.replaceFirst(existing, '')}',
    ].join('\n');
    final t = text.replaceRange(lineStart, lineEnd, next);
    final delta = next.length - block.length;
    return TextEditingValue(
      text: t,
      selection: sel.isCollapsed
          ? TextSelection.collapsed(offset: (sel.end + delta).clamp(lineStart, lineStart + next.length))
          : TextSelection(baseOffset: lineStart, extentOffset: lineStart + next.length),
    );
  }
}
