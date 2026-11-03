import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/database/app_database.dart';
import '../../core/widgets/widgets.dart';
import '../events/event_widgets.dart';
import '../family/domain/family_graph.dart';
import 'timeline_builder.dart';

/// Width of the left rail holding the connecting line and milestone dots.
const double kTimelineRail = 34;

/// Y position (from the row top) of a milestone dot, aligned with the first
/// text line of its card.
const double _kNodeY = 30;

IconData timelineIcon(TimelineItem i) => switch (i.category) {
      TimelineCategory.birth => AppIcons.baby,
      TimelineCategory.marriage => AppIcons.heartFill,
      TimelineCategory.death => AppIcons.flower,
      TimelineCategory.event =>
        i.eventType == null ? AppIcons.event : AppIcons.forEvent(i.eventType!),
      TimelineCategory.story => AppIcons.story,
      TimelineCategory.photo => AppIcons.photo,
    };

IconData categoryIcon(TimelineCategory c) => switch (c) {
      TimelineCategory.birth => AppIcons.baby,
      TimelineCategory.marriage => AppIcons.heartFill,
      TimelineCategory.death => AppIcons.flower,
      TimelineCategory.event => AppIcons.event,
      TimelineCategory.story => AppIcons.story,
      TimelineCategory.photo => AppIcons.photo,
    };

String categorySingular(TimelineCategory c) => switch (c) {
      TimelineCategory.birth => 'Birth',
      TimelineCategory.marriage => 'Partnership',
      TimelineCategory.death => 'Death',
      TimelineCategory.event => 'Event',
      TimelineCategory.story => 'Story',
      TimelineCategory.photo => 'Photo',
    };

/// Paints the vertical connecting line of the timeline rail.
class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.color,
    required this.top,
    required this.bottom,
    required this.nodeY,
  });

  final Color color;
  final bool top;
  final bool bottom;
  final double nodeY;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    if (top) canvas.drawLine(Offset(x, 0), Offset(x, nodeY), p);
    if (bottom) canvas.drawLine(Offset(x, nodeY), Offset(x, size.height), p);
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.color != color ||
      old.top != top ||
      old.bottom != bottom ||
      old.nodeY != nodeY;
}

/// Lays out [child] to the right of the rail; the rail stretches to the
/// child's height without intrinsic measurement.
class _RailRow extends StatelessWidget {
  const _RailRow({
    required this.child,
    required this.lineTop,
    required this.lineBottom,
    this.node,
    this.nodeY = _kNodeY,
    this.nodeSize = 12,
  });

  final Widget child;
  final bool lineTop;
  final bool lineBottom;
  final Widget? node;
  final double nodeY;
  final double nodeSize;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: kTimelineRail,
          child: CustomPaint(
            painter: _RailPainter(
              color: c.text.withValues(alpha: c.isDark ? 0.12 : 0.14),
              top: lineTop,
              bottom: lineBottom,
              nodeY: nodeY,
            ),
          ),
        ),
        if (node != null)
          Positioned(
            left: (kTimelineRail - nodeSize) / 2,
            top: nodeY - nodeSize / 2,
            width: nodeSize,
            height: nodeSize,
            child: node!,
          ),
        Padding(
          padding: const EdgeInsets.only(left: kTimelineRail + Gap.xs),
          child: child,
        ),
      ],
    );
  }
}

/// "1950s ........ 12 milestones" header with a ring node on the rail.
class TimelineDecadeHeader extends StatelessWidget {
  const TimelineDecadeHeader({
    super.key,
    required this.section,
    required this.first,
  });

  final TimelineSection section;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final n = section.itemCount;
    return Semantics(
      header: true,
      label: '${section.label}, $n ${n == 1 ? 'milestone' : 'milestones'}',
      excludeSemantics: true,
      child: _RailRow(
        lineTop: !first,
        lineBottom: true,
        nodeY: 34,
        nodeSize: 18,
        node: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.bg0,
            border: Border.all(color: c.text.withValues(alpha: 0.35), width: 1.6),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(top: first ? Gap.xs : Gap.xl, bottom: Gap.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  section.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.tx.headline,
                ),
              ),
              FTTag('$n ${n == 1 ? 'milestone' : 'milestones'}'),
            ],
          ),
        ),
      ),
    );
  }
}

class TimelineYearHeader extends StatelessWidget {
  const TimelineYearHeader({super.key, required this.row});
  final TimelineYearRow row;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Semantics(
      header: true,
      child: _RailRow(
        lineTop: true,
        lineBottom: true,
        nodeY: 22,
        nodeSize: 6,
        node: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.text.withValues(alpha: 0.35),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.xs),
          child: Text(
            '${row.year}',
            style: context.tx.section.copyWith(color: c.text2),
          ),
        ),
      ),
    );
  }
}

/// A milestone card on the rail. [accent] paints the dot mint.
class TimelineItemTile extends ConsumerWidget {
  const TimelineItemTile({
    super.key,
    required this.item,
    required this.accent,
    required this.selected,
    required this.lineBottom,
    required this.onTap,
  });

  final TimelineItem item;
  final bool accent;
  final bool selected;
  final bool lineBottom;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ft;
    final t = context.tx;
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final avatars = avatarPairsFor(ref, g, item.personIds);
    MediaAsset? photo;
    if (item.category == TimelineCategory.photo) {
      photo = ref.watch(mediaByIdProvider)[item.targetId];
    }
    final approximate = item.date != null && !item.date!.isExactDay;

    final node = AnimatedContainer(
      duration: Motion.fast,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: accent ? c.accentGradient : null,
        color: accent ? null : c.surfaceHigher,
        border: accent ? null : Border.all(color: c.borderStrong),
        boxShadow: accent
            ? [BoxShadow(color: c.accent.withValues(alpha: 0.45), blurRadius: 10)]
            : null,
      ),
    );

    return _RailRow(
      lineTop: true,
      lineBottom: lineBottom,
      node: node,
      child: Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: FTCard(
          onTap: onTap,
          highlighted: selected,
          padding: const EdgeInsets.all(Gap.md),
          semanticLabel: '${categorySingular(item.category)}, ${item.dateLabel}, '
              '${item.title}${item.subtitle == null ? '' : ', ${item.subtitle}'}',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (photo != null)
                MediaThumb(media: photo, size: 52, radius: Radii.sm)
              else
                IconBadge(icon: timelineIcon(item), size: 44, accent: accent),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.dateLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.label.copyWith(
                              color: approximate ? c.text2 : c.accent,
                              fontStyle: approximate ? FontStyle.italic : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: Gap.xs),
                        Text(
                          categorySingular(item.category).toUpperCase(),
                          style: t.micro.copyWith(letterSpacing: 0.8),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.bodyStrong),
                    if (item.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(item.subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.caption),
                    ],
                    if (avatars.isNotEmpty) ...[
                      const SizedBox(height: Gap.sm),
                      AvatarStack(people: avatars, size: 26, max: 4),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
