import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/widgets/widgets.dart';
import 'media_tools.dart';

/// Rounded thumbnail for a photo (or a document tile). Decodes the image at
/// the rendered size to keep memory low.
class MediaThumb extends StatelessWidget {
  const MediaThumb({
    super.key,
    required this.media,
    this.radius = Radii.sm,
    this.onTap,
    this.onLongPress,
    this.selectable = false,
    this.selected = false,
    this.badge,
  });

  final MediaAsset media;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Shows a selection circle in the corner.
  final bool selectable;
  final bool selected;

  /// Optional small label in the bottom-left corner (e.g. "Cover").
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final br = BorderRadius.circular(radius);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final tile = LayoutBuilder(builder: (context, cons) {
      final w = cons.maxWidth.isFinite ? cons.maxWidth : 160.0;
      final image = media.isImage
          ? Image.file(
              File(media.thumbAbsolutePath),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              cacheWidth: (w * dpr).round().clamp(64, 1200),
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => MediaPlaceholder(icon: media.kindIcon),
            )
          : MediaPlaceholder(icon: media.kindIcon, label: media.displayTitle);
      return Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(borderRadius: br, child: ColoredBox(color: c.surfaceHigh, child: image)),
          if (badge != null)
            Positioned(
              left: 6,
              bottom: 6,
              right: 6,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  child: Text(badge!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.tx.micro.copyWith(color: Colors.white)),
                ),
              ),
            ),
          if (selectable)
            Positioned(
              top: 6,
              right: 6,
              child: AnimatedContainer(
                duration: Motion.fast,
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: selected ? c.accentGradient : null,
                  color: selected ? null : Colors.black.withValues(alpha: 0.35),
                  border: Border.all(color: selected ? Colors.transparent : Colors.white70, width: 1.5),
                ),
                child: selected ? Icon(AppIcons.check, size: 14, color: c.onAccent) : null,
              ),
            ),
          IgnorePointer(
            child: AnimatedContainer(
              duration: Motion.fast,
              decoration: BoxDecoration(
                borderRadius: br,
                border: Border.all(
                  color: selected ? c.accent : c.border,
                  width: selected ? 2 : 1,
                ),
              ),
            ),
          ),
        ],
      );
    });
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      scale: 0.97,
      semanticLabel: '${media.displayTitle}${selected ? ', selected' : ''}',
      child: tile,
    );
  }
}

/// Graphite placeholder used while a file is missing or for documents.
class MediaPlaceholder extends StatelessWidget {
  const MediaPlaceholder({super.key, required this.icon, this.label});
  final IconData icon;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return DecoratedBox(
      decoration: BoxDecoration(gradient: c.cardGradient),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 26, color: c.text3),
              if (label != null) ...[
                const SizedBox(height: 6),
                Text(label!,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: context.tx.micro),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact pill with a leading avatar / icon, used for linked people and
/// events (tap to open, optional remove).
class LinkPill extends StatelessWidget {
  const LinkPill({
    super.key,
    required this.label,
    this.leading,
    this.icon,
    this.onTap,
    this.onRemove,
    this.onDark = false,
  });

  final String label;
  final Widget? leading;
  final IconData? icon;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  /// Styled for the black photo viewer.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final fg = onDark ? Colors.white : c.text;
    final pill = Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: EdgeInsets.fromLTRB(leading != null ? 4 : 12, 4, onRemove != null ? 2 : 14, 4),
      decoration: BoxDecoration(
        color: onDark
            ? Colors.white.withValues(alpha: 0.12)
            : (c.isDark ? Colors.white.withValues(alpha: 0.06) : c.surfaceHigh),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: onDark ? Colors.white.withValues(alpha: 0.16) : c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 8),
          ] else if (icon != null) ...[
            Icon(icon, size: 15, color: onDark ? Colors.white70 : c.accent),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.tx.label.copyWith(color: fg)),
          ),
          if (onRemove != null)
            Semantics(
              button: true,
              label: 'Remove $label',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onRemove,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(AppIcons.close, size: 14, color: onDark ? Colors.white70 : c.text3),
                ),
              ),
            ),
        ],
      ),
    );
    if (onTap == null) return pill;
    return Pressable(onTap: onTap, semanticLabel: label, child: pill);
  }
}

/// Row describing a family event (icon badge, title, date · place).
class EventRow extends StatelessWidget {
  const EventRow({super.key, required this.event, this.onTap, this.selected = false, this.trailing});
  final FamilyEvent event;
  final VoidCallback? onTap;
  final bool selected;
  final Widget? trailing;

  static String subtitleOf(FamilyEvent e) {
    final parts = <String>[
      (e.type == EventType.custom && (e.customLabel?.isNotEmpty ?? false)) ? e.customLabel! : e.type.label,
      ?FuzzyDate.tryParse(e.date)?.format(),
      if (e.location != null && e.location!.trim().isNotEmpty) e.location!.trim(),
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final sub = subtitleOf(event);
    return Pressable(
      onTap: onTap,
      scale: 0.985,
      semanticLabel: '${event.title}, $sub',
      child: AnimatedContainer(
        duration: Motion.fast,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? c.accent.withValues(alpha: 0.10) : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: selected ? c.accent.withValues(alpha: 0.5) : Colors.transparent),
        ),
        child: Row(
          children: [
            IconBadge(icon: AppIcons.forEvent(event.type), size: 42, accent: selected),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(event.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                  if (sub.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.caption),
                  ],
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// Wrap of removable event pills with an "add" chip (forms).
class EventChips extends ConsumerWidget {
  const EventChips({super.key, required this.ids, this.onRemove, this.onAdd, this.addLabel = 'Link events'});
  final List<String> ids;
  final ValueChanged<String>? onRemove;
  final VoidCallback? onAdd;
  final String addLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = {for (final e in ref.watch(eventsProvider).value ?? const <FamilyEvent>[]) e.id: e};
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final id in ids)
          if (events[id] != null)
            LinkPill(
              label: events[id]!.title,
              icon: AppIcons.forEvent(events[id]!.type),
              onRemove: onRemove == null ? null : () => onRemove!(id),
            ),
        if (onAdd != null) FTChip(label: addLabel, icon: AppIcons.add, selected: false, onTap: onAdd),
      ],
    );
  }
}

// ================================================================ pickers

/// Multi-select sheet of gallery photos. Returns the selection, or null when
/// dismissed.
Future<List<String>?> pickMedia(
  BuildContext context, {
  String title = 'Choose photos',
  Set<String> initial = const {},
  Set<String> exclude = const {},
  bool multi = true,
}) {
  return showFTSheet<List<String>>(
    context,
    title: title,
    scrollable: false,
    builder: (_) => _MediaPicker(initial: initial, exclude: exclude, multi: multi),
  );
}

class _MediaPicker extends ConsumerStatefulWidget {
  const _MediaPicker({required this.initial, required this.exclude, required this.multi});
  final Set<String> initial;
  final Set<String> exclude;
  final bool multi;

  @override
  ConsumerState<_MediaPicker> createState() => _MediaPickerState();
}

class _MediaPickerState extends ConsumerState<_MediaPicker> {
  late final Set<String> _sel = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    final photos = [
      for (final m in ref.watch(mediaProvider).value ?? const <MediaAsset>[])
        if (m.isImage && !widget.exclude.contains(m.id)) m,
    ];
    final mq = MediaQuery.of(context);
    return SizedBox(
      height: (mq.size.height - mq.viewInsets.bottom) * 0.72,
      child: Column(
        children: [
          Expanded(
            child: photos.isEmpty
                ? const EmptyState(
                    icon: AppIcons.photos,
                    title: 'No photos to choose',
                    message: 'Photos you add to the gallery appear here.',
                    compact: true,
                  )
                : LayoutBuilder(builder: (context, cons) {
                    final cols = gridColumnsFor(cons.maxWidth - Gap.xl * 2, target: 104);
                    return GridView.builder(
                      padding: EdgeInsets.fromLTRB(
                          Gap.xl, Gap.xs, Gap.xl, widget.multi ? Gap.md : mq.padding.bottom + Gap.md),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                      ),
                      itemCount: photos.length,
                      itemBuilder: (context, i) {
                        final m = photos[i];
                        final selected = _sel.contains(m.id);
                        return MediaThumb(
                          media: m,
                          selectable: widget.multi,
                          selected: selected,
                          onTap: () {
                            if (!widget.multi) {
                              Navigator.of(context).pop([m.id]);
                              return;
                            }
                            setState(() => selected ? _sel.remove(m.id) : _sel.add(m.id));
                          },
                        );
                      },
                    );
                  }),
          ),
          if (widget.multi)
            Padding(
              padding: EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.xl, mq.padding.bottom + Gap.md),
              child: FTButton(
                label: _sel.isEmpty ? 'Done' : 'Done · ${_sel.length} selected',
                expand: true,
                onTap: () => Navigator.of(context).pop(_sel.toList()),
              ),
            ),
        ],
      ),
    );
  }
}

/// Multi-select event picker. Returns the selection, or null if dismissed.
Future<List<String>?> pickEvents(
  BuildContext context, {
  String title = 'Link events',
  Set<String> initial = const {},
}) {
  return showFTSheet<List<String>>(
    context,
    title: title,
    scrollable: false,
    builder: (_) => _EventPicker(multi: true, initial: initial),
  );
}

/// Single event picker. Returns the event id or null.
Future<String?> pickEvent(BuildContext context, {String title = 'Choose an event'}) async {
  final r = await showFTSheet<List<String>>(
    context,
    title: title,
    scrollable: false,
    builder: (_) => const _EventPicker(multi: false, initial: {}),
  );
  return (r == null || r.isEmpty) ? null : r.first;
}

class _EventPicker extends ConsumerStatefulWidget {
  const _EventPicker({required this.multi, required this.initial});
  final bool multi;
  final Set<String> initial;

  @override
  ConsumerState<_EventPicker> createState() => _EventPickerState();
}

class _EventPickerState extends ConsumerState<_EventPicker> {
  String _q = '';
  late final Set<String> _sel = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final events = [...ref.watch(eventsProvider).value ?? const <FamilyEvent>[]]
      ..sort((a, b) {
        final da = FuzzyDate.tryParse(a.date)?.sortKey ?? double.infinity;
        final db = FuzzyDate.tryParse(b.date)?.sortKey ?? double.infinity;
        final s = da.compareTo(db);
        return s != 0 ? s : a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    final shown = q.isEmpty
        ? events
        : [
            for (final e in events)
              if ([e.title, e.location, e.type.label, FuzzyDate.tryParse(e.date)?.format()]
                  .whereType<String>()
                  .any((s) => s.toLowerCase().contains(q)))
                e,
          ];
    final mq = MediaQuery.of(context);
    return SizedBox(
      height: (mq.size.height - mq.viewInsets.bottom) * 0.72,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.xl, Gap.sm),
            child: FTSearchField(hint: 'Search events', onChanged: (v) => setState(() => _q = v)),
          ),
          Expanded(
            child: shown.isEmpty
                ? EmptyState(
                    icon: AppIcons.event,
                    title: events.isEmpty ? 'No events yet' : 'No matching events',
                    message: events.isEmpty ? 'Create events from a person’s profile or the timeline.' : null,
                    compact: true,
                  )
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(
                        Gap.md, 0, Gap.md, widget.multi ? Gap.md : mq.padding.bottom + Gap.md),
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final e = shown[i];
                      final selected = _sel.contains(e.id);
                      return EventRow(
                        event: e,
                        selected: selected,
                        trailing: widget.multi
                            ? Icon(selected ? AppIcons.checkCircle : AppIcons.add,
                                color: selected ? context.ft.accent : context.ft.text3, size: 22)
                            : null,
                        onTap: () {
                          if (!widget.multi) {
                            Navigator.of(context).pop([e.id]);
                            return;
                          }
                          setState(() => selected ? _sel.remove(e.id) : _sel.add(e.id));
                        },
                      );
                    },
                  ),
          ),
          if (widget.multi)
            Padding(
              padding: EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.xl, mq.padding.bottom + Gap.md),
              child: FTButton(
                label: _sel.isEmpty ? 'Done' : 'Done · ${_sel.length} selected',
                expand: true,
                onTap: () => Navigator.of(context).pop(_sel.toList()),
              ),
            ),
        ],
      ),
    );
  }
}
