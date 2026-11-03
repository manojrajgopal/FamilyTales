import 'package:flutter/material.dart';

import '../../core/widgets/widgets.dart';
import 'story_text.dart';

enum MarkdownBlockType { h1, h2, h3, paragraph, quote, bullets }

/// One block of the lightweight story markdown.
class MarkdownBlock {
  MarkdownBlock(this.type, [List<String>? lines]) : lines = lines ?? [];
  final MarkdownBlockType type;
  final List<String> lines;

  static final _h = RegExp(r'^\s{0,3}(#{1,3})\s+(.*)$');
  static final _quote = RegExp(r'^\s{0,3}>\s?(.*)$');
  static final _bullet = RegExp(r'^\s{0,3}[-*•]\s+(.*)$');

  /// Splits [text] into blocks. Blank lines end paragraphs, quotes and lists;
  /// single line breaks inside a paragraph are kept.
  static List<MarkdownBlock> parse(String text) {
    final blocks = <MarkdownBlock>[];
    MarkdownBlock? open;
    for (final raw in text.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        open = null;
        continue;
      }
      final h = _h.firstMatch(line);
      if (h != null) {
        final level = h[1]!.length;
        blocks.add(MarkdownBlock(
          level == 1 ? MarkdownBlockType.h1 : (level == 2 ? MarkdownBlockType.h2 : MarkdownBlockType.h3),
          [h[2]!.trim()],
        ));
        open = null;
        continue;
      }
      final q = _quote.firstMatch(line);
      if (q != null) {
        if (open?.type != MarkdownBlockType.quote) {
          open = MarkdownBlock(MarkdownBlockType.quote);
          blocks.add(open);
        }
        open!.lines.add(q[1]!);
        continue;
      }
      final b = _bullet.firstMatch(line);
      if (b != null) {
        if (open?.type != MarkdownBlockType.bullets) {
          open = MarkdownBlock(MarkdownBlockType.bullets);
          blocks.add(open);
        }
        open!.lines.add(b[1]!);
        continue;
      }
      if (open?.type == MarkdownBlockType.bullets && raw.startsWith('  ')) {
        // Indented continuation of the previous bullet.
        open!.lines[open.lines.length - 1] = '${open.lines.last} ${line.trim()}';
        continue;
      }
      if (open?.type != MarkdownBlockType.paragraph) {
        open = MarkdownBlock(MarkdownBlockType.paragraph);
        blocks.add(open);
      }
      open!.lines.add(line);
    }
    return blocks;
  }
}

/// Renders story markdown – `#`/`##`/`###` headings, **bold**, _italic_,
/// `>` quotes, `-` bullet lists and paragraphs – with the app's typography.
/// Pure Flutter rich text, no packages.
class MarkdownView extends StatelessWidget {
  const MarkdownView(this.text, {super.key, this.style});
  final String text;

  /// Paragraph style; defaults to a comfortable reading style.
  final TextStyle? style;

  /// Inline spans for **bold** / _italic_ (nesting supported).
  static List<InlineSpan> inlineSpans(String s, TextStyle style, {Color? strongColor}) {
    final spans = <InlineSpan>[];
    var i = 0;
    for (final m in StoryText.inlinePattern.allMatches(s)) {
      if (m.start > i) spans.add(TextSpan(text: s.substring(i, m.start), style: style));
      final bold = m[1] ?? m[2];
      if (bold != null) {
        spans.addAll(inlineSpans(
          bold,
          style.copyWith(fontWeight: FontWeight.w600, color: strongColor ?? style.color),
          strongColor: strongColor,
        ));
      } else {
        spans.addAll(inlineSpans(m[3] ?? m[4]!, style.copyWith(fontStyle: FontStyle.italic),
            strongColor: strongColor));
      }
      i = m.end;
    }
    if (i < s.length) spans.add(TextSpan(text: s.substring(i), style: style));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final t = context.tx;
    final base = style ??
        t.body.copyWith(fontSize: 16.5, height: 1.72, color: c.text.withValues(alpha: c.isDark ? 0.86 : 0.88));
    final blocks = MarkdownBlock.parse(text);
    final children = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      final isHeading = b.type == MarkdownBlockType.h1 ||
          b.type == MarkdownBlockType.h2 ||
          b.type == MarkdownBlockType.h3;
      if (i > 0) children.add(SizedBox(height: isHeading ? Gap.xl : Gap.md));
      children.add(_block(context, b, base));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _block(BuildContext context, MarkdownBlock b, TextStyle base) {
    final c = context.ft;
    final t = context.tx;
    Widget rich(String s, TextStyle st) =>
        Text.rich(TextSpan(children: inlineSpans(s, st, strongColor: c.text)));
    switch (b.type) {
      case MarkdownBlockType.h1:
        return Semantics(header: true, child: rich(b.lines.first, t.headline));
      case MarkdownBlockType.h2:
        return Semantics(header: true, child: rich(b.lines.first, t.title.copyWith(fontSize: 21)));
      case MarkdownBlockType.h3:
        return Semantics(header: true, child: rich(b.lines.first, t.section.copyWith(fontSize: 17)));
      case MarkdownBlockType.paragraph:
        return rich(b.lines.join('\n'), base);
      case MarkdownBlockType.quote:
        return Container(
          decoration: BoxDecoration(
            color: c.accent.withValues(alpha: c.isDark ? 0.06 : 0.08),
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
                child: rich(
                  b.lines.join('\n'),
                  base.copyWith(fontStyle: FontStyle.italic, color: c.text2),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 3,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ],
          ),
        );
      case MarkdownBlockType.bullets:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < b.lines.length; i++)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExcludeSemantics(
                      child: Text('•', style: base.copyWith(color: c.accent, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: rich(b.lines[i], base)),
                  ],
                ),
              ),
          ],
        );
    }
  }
}
