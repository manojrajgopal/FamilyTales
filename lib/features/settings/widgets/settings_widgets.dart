import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

/// Scrollable settings body: page padding, readable width on tablets, a
/// staggered entrance for each block and a bottom inset that clears the
/// system gesture area.
class SettingsBody extends StatelessWidget {
  const SettingsBody({super.key, required this.children, this.spacing = Gap.xl});

  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final pad = context.pagePadding;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, FTPage.bottomInset(context)),
      child: ContentWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++)
              Padding(
                padding: EdgeInsets.only(bottom: i == children.length - 1 ? 0 : spacing),
                child: FadeSlideIn(index: i, child: children[i]),
              ),
          ],
        ),
      ),
    );
  }
}

/// A titled group of rows on a lit card. Rows are separated by hairlines
/// unless [divided] is false (then they are spaced instead).
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    required this.children,
    this.footer,
    this.divided = true,
    this.padding,
    this.trailing,
  });

  final String? title;
  final List<Widget> children;
  final String? footer;
  final bool divided;
  final EdgeInsetsGeometry? padding;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(divided ? const HairLine(vertical: 2) : const SizedBox(height: Gap.md));
      }
      rows.add(children[i]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null) SectionHeader(title!, trailing: trailing),
        FTCard(
          padding: padding ??
              (divided
                  ? const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs)
                  : const EdgeInsets.all(Gap.lg)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: rows,
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.xs, Gap.xs, 0),
            child: Text(footer!, style: context.tx.caption),
          ),
      ],
    );
  }
}

/// Explanatory card: inset icon, title, message and optional extra content.
class InfoCard extends StatelessWidget {
  const InfoCard({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.child,
    this.accent = false,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? child;
  final bool accent;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return FTCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconBadge(
            icon: icon,
            accent: accent,
            color: danger ? c.danger.withValues(alpha: 0.16) : null,
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(title,
                      style: context.tx.section.copyWith(color: danger ? c.danger : null)),
                ),
                if (message != null) ...[
                  const SizedBox(height: Gap.xxs),
                  Text(message!, style: context.tx.body),
                ],
                if (child != null) ...[
                  const SizedBox(height: Gap.sm),
                  child!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Short list of statements with accent tick marks.
class BulletPoints extends StatelessWidget {
  const BulletPoints(this.items, {super.key, this.icon});
  final List<String> items;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : Gap.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Icon(icon ?? AppIcons.check, size: 15, color: c.accent),
                ),
                const SizedBox(width: Gap.xs),
                Expanded(child: Text(items[i], style: context.tx.body)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Small spinner used as the trailing widget of a row while it works.
class RowSpinner extends StatelessWidget {
  const RowSpinner({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: context.ft.accent),
      );
}

/// Six-dot grip used as a drag handle.
class GripDots extends StatelessWidget {
  const GripDots({super.key, this.color});
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 12,
        height: 18,
        child: CustomPaint(painter: _GripPainter(color ?? context.ft.text3)),
      );
}

class _GripPainter extends CustomPainter {
  _GripPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    for (var col = 0; col < 2; col++) {
      for (var row = 0; row < 3; row++) {
        canvas.drawCircle(
          Offset(size.width * (0.25 + col * 0.5), size.height * (1 / 6 + row / 3)),
          1.8,
          p,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_GripPainter old) => old.color != color;
}

/// "3 days ago" style label for past dates.
String timeAgo(DateTime when, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final d = n.difference(when);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return d.inHours == 1 ? '1 hour ago' : '${d.inHours} hours ago';
  if (d.inDays == 1) return 'yesterday';
  if (d.inDays < 30) return '${d.inDays} days ago';
  final months = (d.inDays / 30).floor();
  if (months < 12) return months == 1 ? '1 month ago' : '$months months ago';
  final years = (d.inDays / 365).floor();
  return years <= 1 ? '1 year ago' : '$years years ago';
}

/// "1 person" / "3 people" style pluralisation.
String plural(int n, String one, [String? many]) => '$n ${n == 1 ? one : (many ?? '${one}s')}';
