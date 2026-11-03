import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/repositories/content_repository.dart';
import '../../core/services/app_paths.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import 'event_logic.dart';

/// (name, avatar path) pairs for [AvatarStack], resolving profile photos.
List<(String, String?)> avatarPairsFor(
    WidgetRef ref, FamilyGraph graph, Iterable<String> personIds) {
  return [
    for (final id in personIds)
      if (graph[id] != null)
        (
          graph[id]!.displayName,
          ref.watch(avatarPathProvider(graph[id]!.profileMediaId)),
        ),
  ];
}

/// Absolute path of a media asset's thumbnail (or original), if storage is
/// ready.
String? mediaThumbPath(MediaAsset m) {
  if (!AppPaths.isReady) return null;
  return AppPaths.I.resolve(m.thumbPath ?? m.filePath);
}

/// Rounded photo thumbnail decoded at display size.
class MediaThumb extends StatelessWidget {
  const MediaThumb({
    super.key,
    required this.media,
    this.size,
    this.radius = Radii.sm,
    this.selected = false,
  });

  final MediaAsset media;

  /// Square size; when null the thumbnail fills its parent.
  final double? size;
  final double radius;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final path = mediaThumbPath(media);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final fallback = Container(
      color: c.surfaceHigh,
      alignment: Alignment.center,
      child: Icon(AppIcons.photo, color: c.text3, size: 22),
    );
    return LayoutBuilder(builder: (context, cons) {
      final w = size ??
          (cons.maxWidth.isFinite ? cons.maxWidth : (cons.maxHeight.isFinite ? cons.maxHeight : 120));
      return SizedBox(
        width: size,
        height: size,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: selected ? c.accent : c.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius - 1),
            child: path == null
                ? fallback
                : Image.file(
                    File(path),
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                    cacheWidth: (w * dpr).round().clamp(48, 720),
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => fallback,
                  ),
          ),
        ),
      );
    });
  }
}

/// Event list card: inset type icon, title, date, place and participants.
class EventCard extends ConsumerWidget {
  const EventCard({super.key, required this.item, required this.onTap});
  final EventWithPeople item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ft;
    final t = context.tx;
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final ev = item.event;
    final date = ev.dateLabel;
    final place = ev.location?.trim();
    final people = avatarPairsFor(ref, g, item.personIds);
    return FTCard(
      onTap: onTap,
      padding: const EdgeInsets.all(Gap.md),
      semanticLabel: [ev.title, ev.typeLabel, ?date, if (place != null && place.isNotEmpty) place].join(', '),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconBadge(icon: AppIcons.forEvent(ev.type), size: 46),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(ev.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.bodyStrong),
                const SizedBox(height: 3),
                Text(
                  [ev.typeLabel, date ?? 'Date unknown'].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.caption.copyWith(color: date == null ? c.text3 : c.text2),
                ),
                if (place != null && place.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(AppIcons.location, size: 13, color: c.text3),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(place, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.caption),
                      ),
                    ],
                  ),
                ],
                if (people.isNotEmpty) ...[
                  const SizedBox(height: Gap.sm),
                  AvatarStack(people: people, size: 28, max: 4),
                ],
              ],
            ),
          ),
          if (ev.remind) ...[
            const SizedBox(width: Gap.xs),
            Tooltip(
              message: 'Yearly reminder',
              child: Icon(AppIcons.bellRinging, size: 16, color: c.accent),
            ),
          ],
        ],
      ),
    );
  }
}

/// Opens a multi-select grid of the tree's existing photos. Returns the full
/// selection, or null when dismissed.
Future<Set<String>?> pickExistingPhotos(
  BuildContext context, {
  Set<String> initial = const {},
  String title = 'Choose photos',
}) {
  return showFTSheet<Set<String>>(
    context,
    title: title,
    scrollable: false,
    builder: (_) => _PhotoPicker(initial: initial),
  );
}

class _PhotoPicker extends ConsumerStatefulWidget {
  const _PhotoPicker({required this.initial});
  final Set<String> initial;

  @override
  ConsumerState<_PhotoPicker> createState() => _PhotoPickerState();
}

class _PhotoPickerState extends ConsumerState<_PhotoPicker> {
  late final Set<String> _sel = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final mq = MediaQuery.of(context);
    final photos = [
      for (final m in ref.watch(mediaProvider).value ?? const <MediaAsset>[])
        if (m.kind == MediaKind.photo) m,
    ];
    return SizedBox(
      height: (mq.size.height - mq.viewInsets.bottom) * 0.72,
      child: Column(
        children: [
          Expanded(
            child: photos.isEmpty
                ? const EmptyState(
                    icon: AppIcons.photos,
                    title: 'No photos yet',
                    message: 'Import photos first, or add new ones after saving.',
                    compact: true,
                  )
                : LayoutBuilder(builder: (context, cons) {
                    final cols = (cons.maxWidth / 110).floor().clamp(3, 6);
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.xl, Gap.md),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        mainAxisSpacing: Gap.xs,
                        crossAxisSpacing: Gap.xs,
                      ),
                      itemCount: photos.length,
                      itemBuilder: (context, i) {
                        final m = photos[i];
                        final selected = _sel.contains(m.id);
                        return Semantics(
                          selected: selected,
                          child: Pressable(
                            semanticLabel: m.caption ?? m.originalName ?? 'Photo ${i + 1}',
                            onTap: () => setState(() => selected ? _sel.remove(m.id) : _sel.add(m.id)),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                MediaThumb(media: m, selected: selected),
                                Positioned(
                                  top: 6,
                                  right: 6,
                                  child: AnimatedContainer(
                                    duration: Motion.fast,
                                    width: 22,
                                    height: 22,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: selected ? c.accentGradient : null,
                                      color: selected ? null : Colors.black.withValues(alpha: 0.35),
                                      border: Border.all(
                                          color: selected ? Colors.transparent : Colors.white.withValues(alpha: 0.7)),
                                    ),
                                    child: selected ? Icon(AppIcons.check, size: 13, color: c.onAccent) : null,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  }),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.xl, mq.padding.bottom + Gap.md),
            child: FTButton(
              label: _sel.isEmpty ? 'Done' : 'Done · ${_sel.length} selected',
              expand: true,
              onTap: () => Navigator.of(context).pop(_sel),
            ),
          ),
        ],
      ),
    );
  }
}
