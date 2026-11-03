import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme/app_theme.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/services/system_ui.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../members/widgets/person_widgets.dart';
import 'media_tools.dart';
import 'media_widgets.dart';
import 'photo_actions.dart';

enum _MoreAction { profile, album, trash }

/// Full-screen black photo viewer: swipe between photos, pinch or
/// double-tap to zoom, tap to hide the chrome. The bottom overlay shows the
/// caption, date, place, tagged people and linked events.
class PhotoViewerScreen extends ConsumerStatefulWidget {
  const PhotoViewerScreen({super.key, required this.mediaId, this.contextIds});
  final String mediaId;

  /// Order of photos to swipe through (e.g. an album). Defaults to all
  /// photos of the gallery.
  final List<String>? contextIds;

  @override
  ConsumerState<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends ConsumerState<PhotoViewerScreen> {
  late String _currentId = widget.mediaId;
  int _lastIndex = 0;
  int _lastCount = -1;
  PageController? _pc;
  bool _chrome = true;
  bool _zoomed = false;
  late final bool _fullScreen;

  @override
  void initState() {
    super.initState();
    _fullScreen = ref.read(settingsProvider).fullScreen;
  }

  @override
  void dispose() {
    _pc?.dispose();
    applySystemUiMode(fullScreen: _fullScreen);
    super.dispose();
  }

  void _toggleChrome() {
    setState(() => _chrome = !_chrome);
    applySystemUiMode(fullScreen: _fullScreen || !_chrome);
  }

  List<MediaAsset> _photos(List<MediaAsset> all, Map<String, MediaAsset> byId) {
    final ctx = widget.contextIds;
    final List<MediaAsset> list;
    if (ctx != null && ctx.isNotEmpty) {
      list = [
        for (final id in ctx)
          if (byId[id] != null && byId[id]!.isImage) byId[id]!,
      ];
    } else {
      list = [for (final m in all) if (m.kind == MediaKind.photo) m];
    }
    // Opened on an item outside the context list: show it first.
    if (!list.any((m) => m.id == widget.mediaId)) {
      final m = byId[widget.mediaId];
      if (m != null && m.isImage) list.insert(0, m);
    }
    return list;
  }

  Future<void> _more(BuildContext context, MediaAsset m) async {
    final a = await showFTOptions<_MoreAction>(
      context,
      title: m.displayTitle,
      options: const [
        FTOption(_MoreAction.profile, 'Use as profile photo', icon: AppIcons.person),
        FTOption(_MoreAction.album, 'Add to album', icon: AppIcons.album),
        FTOption(_MoreAction.trash, 'Move to trash',
            icon: AppIcons.trash, danger: true, subtitle: 'Tagged people are not affected'),
      ],
    );
    if (a == null || !context.mounted) return;
    switch (a) {
      case _MoreAction.profile:
        await setProfilePhotoFlow(context, ref, m);
      case _MoreAction.album:
        await addToAlbumFlow(context, ref, [m.id]);
      case _MoreAction.trash:
        await trashMediaFlow(context, ref, m);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(settingsProvider.select((s) => s.accent));
    final async = ref.watch(mediaProvider);
    final byId = ref.watch(mediaByIdProvider);
    return Theme(
      data: AppTheme.build(dark: true, accent: accent),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.overlayStyle(true),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Builder(builder: (context) => _body(context, async, byId)),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, AsyncValue<List<MediaAsset>> async, Map<String, MediaAsset> byId) {
    if (!async.hasValue) {
      return async.hasError ? _Missing(error: async.error) : const LoadingView();
    }
    final photos = _photos(async.value!, byId);
    if (photos.isEmpty) return const _Missing();

    var idx = photos.indexWhere((m) => m.id == _currentId);
    if (idx < 0) {
      idx = _lastIndex.clamp(0, photos.length - 1);
      _currentId = photos[idx].id;
    }
    _lastIndex = idx;
    final pc = _pc ??= PageController(initialPage: idx);
    if (_lastCount >= 0 && _lastCount != photos.length) {
      // Items were added or removed: keep the current photo in view.
      final target = idx;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && pc.hasClients && (pc.page?.round() ?? target) != target) pc.jumpToPage(target);
      });
    }
    _lastCount = photos.length;
    final current = photos[idx];

    return Stack(
      children: [
        Positioned.fill(
          child: PageView.builder(
            controller: pc,
            physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
            itemCount: photos.length,
            onPageChanged: (i) => setState(() {
              _currentId = photos[i].id;
              _lastIndex = i;
              _zoomed = false;
            }),
            itemBuilder: (context, i) => _ZoomablePhoto(
              key: ValueKey(photos[i].id),
              media: photos[i],
              onTap: _toggleChrome,
              onZoomChanged: (z) {
                if (z != _zoomed) setState(() => _zoomed = z);
              },
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: _Chrome(
            visible: _chrome,
            child: _TopBar(
              index: idx,
              count: photos.length,
              onEdit: () => context.push(Routes.mediaEdit(current.id)),
              onShare: () => shareMediaFile(context, current),
              onMore: () => _more(context, current),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _Chrome(visible: _chrome, child: _InfoPanel(media: current)),
        ),
      ],
    );
  }
}

class _Chrome extends StatelessWidget {
  const _Chrome({required this.visible, required this.child});
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: context.reduceMotion ? Duration.zero : Motion.fast,
          child: child,
        ),
      );
}

class _Missing extends StatelessWidget {
  const _Missing({this.error});
  final Object? error;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.fromLTRB(context.pagePadding - 4, Gap.xs, 0, 0),
              child: FTIconButton(icon: AppIcons.back, tooltip: 'Back', onTap: () => context.pop()),
            ),
          ),
          Expanded(
            child: error != null
                ? ErrorView(error: error!)
                : const EmptyState(
                    icon: AppIcons.photo,
                    title: 'No photo to show',
                    message: 'It may have been moved to the trash.',
                  ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.index,
    required this.count,
    required this.onEdit,
    required this.onShare,
    required this.onMore,
  });

  final int index;
  final int count;
  final VoidCallback onEdit;
  final VoidCallback onShare;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final pad = context.pagePadding;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(pad - 4, Gap.xs, pad - 4, Gap.lg),
          child: Row(
            children: [
              FTIconButton(icon: AppIcons.back, tooltip: 'Close', onTap: () => context.pop()),
              const SizedBox(width: Gap.xs),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(Radii.pill),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                  ),
                  child: Text('${index + 1} / $count',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      semanticsLabel: 'Photo ${index + 1} of $count',
                      style: context.tx.label.copyWith(color: Colors.white)),
                ),
              ),
              const Spacer(),
              FTIconButton(icon: AppIcons.edit, tooltip: 'Edit details', onTap: onEdit),
              FTIconButton(icon: AppIcons.share, tooltip: 'Share', onTap: onShare),
              FTIconButton(icon: AppIcons.moreHoriz, tooltip: 'More actions', onTap: onMore),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoPanel extends ConsumerWidget {
  const _InfoPanel({required this.media});
  final MediaAsset media;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final graph = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final people = [
      for (final r in ref.watch(mediaPeopleProvider).value ?? const <MediaPerson>[])
        if (r.mediaId == media.id && graph[r.personId] != null) graph[r.personId]!,
    ]..sort((a, b) => a.displayName.compareTo(b.displayName));
    final events = {for (final e in ref.watch(eventsProvider).value ?? const <FamilyEvent>[]) e.id: e};
    final linked = [
      for (final r in ref.watch(mediaEventsProvider).value ?? const <MediaEvent>[])
        if (r.mediaId == media.id && events[r.eventId] != null) events[r.eventId]!,
    ];
    final caption = media.caption?.trim() ?? '';
    final desc = media.description?.trim() ?? '';
    final date = media.fuzzyDate?.format(long: true);
    final place = media.location?.trim() ?? '';
    final category = media.category?.trim() ?? '';
    final hasAnything = caption.isNotEmpty ||
        desc.isNotEmpty ||
        date != null ||
        place.isNotEmpty ||
        people.isNotEmpty ||
        linked.isNotEmpty;
    final pad = context.pagePadding;
    final mq = MediaQuery.of(context);
    const white70 = Color(0xB3FFFFFF);

    Widget meta(IconData icon, String text) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: white70),
            const SizedBox(width: 6),
            Flexible(
              child: Text(text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.tx.caption.copyWith(color: white70)),
            ),
          ],
        );

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xA6000000), Color(0xE6000000)],
          stops: [0, 0.35, 1],
        ),
      ),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: mq.size.height * 0.42),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(pad, Gap.xxl, pad, Gap.md),
            child: ContentWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (caption.isNotEmpty)
                    Text(caption, style: context.tx.title.copyWith(color: Colors.white)),
                  if (date != null || place.isNotEmpty || category.isNotEmpty) ...[
                    const SizedBox(height: Gap.xs),
                    Wrap(
                      spacing: Gap.md,
                      runSpacing: 4,
                      children: [
                        if (date != null) meta(AppIcons.calendar, date),
                        if (place.isNotEmpty) meta(AppIcons.location, place),
                        if (category.isNotEmpty) meta(AppIcons.tag, category),
                      ],
                    ),
                  ],
                  if (desc.isNotEmpty) ...[
                    const SizedBox(height: Gap.sm),
                    Text(desc, style: context.tx.body.copyWith(color: const Color(0xE6FFFFFF))),
                  ],
                  if (people.isNotEmpty) ...[
                    const SizedBox(height: Gap.md),
                    Wrap(
                      spacing: Gap.xs,
                      runSpacing: Gap.xs,
                      children: [
                        for (final p in people)
                          LinkPill(
                            label: p.displayName,
                            leading: PersonAvatarFor(p, size: 28),
                            onDark: true,
                            onTap: () => context.push(Routes.person(p.id)),
                          ),
                      ],
                    ),
                  ],
                  if (linked.isNotEmpty) ...[
                    const SizedBox(height: Gap.xs),
                    Wrap(
                      spacing: Gap.xs,
                      runSpacing: Gap.xs,
                      children: [
                        for (final e in linked)
                          LinkPill(
                            label: e.title,
                            icon: AppIcons.forEvent(e.type),
                            onDark: true,
                            onTap: () => context.push(Routes.event(e.id)),
                          ),
                      ],
                    ),
                  ],
                  if (!hasAnything)
                    Row(
                      children: [
                        Flexible(
                          child: Text('No details yet',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.tx.caption.copyWith(color: white70)),
                        ),
                        const SizedBox(width: Gap.xs),
                        FTTextAction('Add caption & people',
                            accent: true, onTap: () => context.push(Routes.mediaEdit(media.id))),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One zoomable page. Pinch to zoom, double-tap to zoom at the tapped point
/// (or back out), single tap toggles the chrome.
class _ZoomablePhoto extends StatefulWidget {
  const _ZoomablePhoto({super.key, required this.media, required this.onTap, required this.onZoomChanged});
  final MediaAsset media;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ZoomablePhoto> createState() => _ZoomablePhotoState();
}

class _ZoomablePhotoState extends State<_ZoomablePhoto> with SingleTickerProviderStateMixin {
  final _tc = TransformationController();
  late final AnimationController _ac = AnimationController(vsync: this, duration: Motion.medium)
    ..addListener(_tick);
  Matrix4Tween? _tween;
  Offset _tapPos = Offset.zero;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onTransform);
  }

  @override
  void dispose() {
    _ac.dispose();
    _tc.dispose();
    super.dispose();
  }

  void _tick() {
    final t = _tween;
    if (t != null) _tc.value = t.transform(Motion.emphasized.transform(_ac.value));
  }

  void _onTransform() {
    final z = _tc.value.getMaxScaleOnAxis() > 1.01;
    if (z != _zoomed) {
      _zoomed = z;
      widget.onZoomChanged(z);
    }
  }

  void _doubleTap() {
    final Matrix4 end;
    if (_zoomed) {
      end = Matrix4.identity();
    } else {
      const s = 2.5;
      end = Matrix4.diagonal3Values(s, s, 1)
        ..setTranslationRaw(-_tapPos.dx * (s - 1), -_tapPos.dy * (s - 1), 0);
    }
    if (context.reduceMotion) {
      _tc.value = end;
      return;
    }
    _tween = Matrix4Tween(begin: _tc.value.clone(), end: end);
    _ac.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.media;
    final mq = MediaQuery.of(context);
    final target = (mq.size.longestSide * mq.devicePixelRatio * 1.25).round().clamp(1024, 3072);
    final w = m.width, h = m.height;
    // Decode at most ~screen resolution along the image's long side.
    int? cacheW, cacheH;
    if (w != null && h != null && h > w) {
      cacheH = h < target ? null : target;
    } else {
      cacheW = (w != null && w < target) ? null : target;
    }
    return Semantics(
      image: true,
      label: m.displayTitle,
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTapDown: (d) => _tapPos = d.localPosition,
        onDoubleTap: _doubleTap,
        child: InteractiveViewer(
          transformationController: _tc,
          minScale: 1,
          maxScale: 5,
          child: SizedBox.expand(
            child: Image.file(
              File(m.absolutePath),
              fit: BoxFit.contain,
              cacheWidth: cacheW,
              cacheHeight: cacheH,
              gaplessPlayback: true,
              frameBuilder: (context, child, frame, sync) {
                if (sync || context.reduceMotion) return child;
                return AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: Motion.medium,
                  child: child,
                );
              },
              errorBuilder: (context, _, _) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const IconBadge(icon: AppIcons.warning, size: 56),
                    const SizedBox(height: Gap.md),
                    Text('This image can’t be displayed',
                        style: context.tx.body.copyWith(color: Colors.white70)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
