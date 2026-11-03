import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/app_shell.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme/app_theme.dart';
import '../../core/database/app_database.dart';
import '../../core/services/app_paths.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../members/widgets/add_relative_sheet.dart';
import '../members/widgets/person_widgets.dart';
import 'layout/tree_layout.dart';
import 'widgets/tree_controls.dart';
import 'widgets/tree_node.dart';
import 'widgets/tree_painter.dart';

/// The interactive family tree: generated from the database, zoomable,
/// pannable, with several layouts, collapsible branches and lineage
/// highlighting.
class FamilyTreeScreen extends ConsumerStatefulWidget {
  const FamilyTreeScreen({super.key, this.focusId});
  final String? focusId;

  @override
  ConsumerState<FamilyTreeScreen> createState() => _FamilyTreeScreenState();
}

class _FamilyTreeScreenState extends ConsumerState<FamilyTreeScreen>
    with SingleTickerProviderStateMixin {
  final _tc = TransformationController();
  late final AnimationController _anim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
  Animation<Matrix4>? _matrixAnim;

  late TreeViewMode _mode = ref.read(settingsProvider).treeMode;
  late int _gens = ref.read(settingsProvider).treeGenerations;
  String? _focusId;
  String? _selectedId;
  final Set<String> _collapsed = {};

  // Layout memo.
  FamilyGraph? _layoutGraph;
  TreeLayoutOptions? _layoutOpts;
  TreeLayout? _layout;
  String? _layoutTreeId;

  Size _viewport = Size.zero;
  bool _needsInitialCamera = true;
  String? _pendingCenterId;

  // Manual double-tap detection (keeps node taps instant).
  DateTime? _lastTapUp;
  Offset? _lastTapPos;
  Offset? _downPos;
  DateTime? _downTime;

  @override
  void initState() {
    super.initState();
    _focusId = widget.focusId;
    _pendingCenterId = widget.focusId;
    _anim.addListener(() {
      final a = _matrixAnim;
      if (a != null) _tc.value = a.value;
    });
  }

  @override
  void didUpdateWidget(covariant FamilyTreeScreen old) {
    super.didUpdateWidget(old);
    if (widget.focusId != null && widget.focusId != old.focusId) {
      setState(() {
        _focusId = widget.focusId;
        _selectedId = widget.focusId;
        _pendingCenterId = widget.focusId;
      });
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    _tc.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- layout

  TreeLayout _computeLayout(FamilyGraph g, String focus, String? treeId) {
    if (treeId != _layoutTreeId) {
      // Another family tree: start fresh and frame it.
      if (_layoutTreeId != null) {
        _collapsed.clear();
        _needsInitialCamera = true;
      }
      _layoutTreeId = treeId;
    }
    final opts = TreeLayoutOptions(
      mode: _mode,
      focusId: focus,
      generationsUp: _gens,
      generationsDown: _gens,
      collapsed: Set.of(_collapsed),
    );
    if (_layout != null &&
        identical(_layoutGraph, g) &&
        _layoutOpts != null &&
        _sameOpts(_layoutOpts!, opts)) {
      return _layout!;
    }
    final previous = _layout;
    _layoutGraph = g;
    _layoutOpts = opts;
    final next = _layout = TreeLayoutEngine(g).compute(opts);
    if (previous != null && !_needsInitialCamera && _pendingCenterId == null) _keepInPlace(previous, next, focus);
    return next;
  }

  /// After an edit the layout is recalculated; keep the selected (or focus)
  /// person where they were on screen so the tree does not jump. If they
  /// are gone and nothing is left in view, frame the tree again.
  void _keepInPlace(TreeLayout before, TreeLayout after, String focus) {
    final anchor = [_selectedId, focus].firstWhere(
        (id) => id != null && before.nodes.containsKey(id) && after.nodes.containsKey(id),
        orElse: () => null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _layout != after) return;
      if (anchor == null) {
        final view = _tc.toScene(Offset.zero) & (_viewport / _scale);
        final o = after.options;
        if (!after.nodes.values.any((n) => view.overlaps(n.rect(o)))) _fit(animate: false);
        return;
      }
      final d = after.nodes[anchor]!.center(after.options) - before.nodes[anchor]!.center(before.options);
      if (d.distance < 0.5) return;
      final s = _scale;
      final m = _tc.value.clone();
      m.setEntry(0, 3, m.entry(0, 3) - d.dx * s);
      m.setEntry(1, 3, m.entry(1, 3) - d.dy * s);
      _anim.stop();
      _tc.value = m;
    });
  }

  bool _sameOpts(TreeLayoutOptions a, TreeLayoutOptions b) =>
      a.mode == b.mode &&
      a.focusId == b.focusId &&
      a.generationsUp == b.generationsUp &&
      a.generationsDown == b.generationsDown &&
      a.collapsed.length == b.collapsed.length &&
      a.collapsed.containsAll(b.collapsed);

  // ------------------------------------------------------------- camera

  /// Current zoom (the x scale; the matrix never scales z, so
  /// getMaxScaleOnAxis would report 1 whenever the tree is zoomed out).
  double get _scale => _tc.value.entry(0, 0);

  Matrix4 _matrix(double s, double tx, double ty) => Matrix4.identity()
    ..setEntry(0, 0, s)
    ..setEntry(1, 1, s)
    ..setEntry(0, 3, tx)
    ..setEntry(1, 3, ty);

  void _animateTo(Matrix4 target) {
    if (context.reduceMotion) {
      _tc.value = target;
      return;
    }
    _matrixAnim = Matrix4Tween(begin: _tc.value, end: target)
        .animate(CurvedAnimation(parent: _anim, curve: Motion.emphasized));
    _anim.forward(from: 0);
  }

  /// Visible area of the canvas not covered by the header, toolbars or panel.
  Rect get _usable {
    final top = MediaQuery.paddingOf(context).top + 72;
    final bottom = AppShell.navClearance(context) + (_selectedId != null ? 170 : 80);
    // The zoom toolbar floats on the right: keep the framed tree clear of it.
    final right = _viewport.width - (context.pagePadding - 6 + 48 + 8);
    return Rect.fromLTRB(0, top, math.max(100, right), math.max(top + 100, _viewport.height - bottom));
  }

  /// Everything drawn, with room for the expand badges around the cards.
  static Rect _framed(TreeLayout l) => l.contentBounds.inflate(TreeNodeCard.badgeSpace + 8);

  /// Scale at which the whole tree fits the usable area.
  double _fitScale(TreeLayout l) {
    final u = _usable, b = _framed(l);
    return math.min(u.width / b.width, u.height / b.height);
  }

  /// Smallest zoom: the usual limit, or less when that is what it takes to
  /// see a very large tree at once.
  double get _minScale {
    final l = _layout;
    if (l == null || l.isEmpty || _viewport == Size.zero) return _baseMinScale;
    return math.min(_baseMinScale, math.max(0.02, _fitScale(l) * 0.9));
  }

  static const _baseMinScale = 0.12;
  static const _maxScale = 2.6;

  void _fit({bool animate = true}) {
    final l = _layout;
    if (l == null || l.isEmpty || _viewport == Size.zero) return;
    final u = _usable, b = _framed(l);
    final s = _fitScale(l).clamp(_minScale, 1.1);
    final tx = u.center.dx - b.center.dx * s;
    final ty = u.center.dy - b.center.dy * s;
    final m = _matrix(s, tx, ty);
    animate ? _animateTo(m) : _tc.value = m;
  }

  void _centerOn(String id, {double? scale, bool animate = true}) {
    final l = _layout;
    if (l == null || !l.nodes.containsKey(id) || _viewport == Size.zero) return;
    final c = l.nodes[id]!.center(l.options);
    final s = scale ?? _scale.clamp(0.7, 1.4);
    final u = _usable;
    final m = _matrix(s, u.center.dx - c.dx * s, u.center.dy - c.dy * s);
    animate ? _animateTo(m) : _tc.value = m;
  }

  void _zoomBy(double f) {
    final s = (_scale * f).clamp(_minScale, _maxScale);
    final center = _usable.center;
    final scenePoint = _tc.toScene(center);
    _animateTo(_matrix(s, center.dx - scenePoint.dx * s, center.dy - scenePoint.dy * s));
  }

  void _resetCamera(String focus, {bool animate = true}) {
    final l = _layout;
    if (l == null || l.isEmpty || _viewport == Size.zero) return;
    if (_fitScale(l) >= 0.42) {
      _fit(animate: animate);
    } else {
      _centerOn(focus, scale: 0.6, animate: animate);
    }
  }

  void _onPointerDown(PointerDownEvent e) {
    _downPos = e.localPosition;
    _downTime = DateTime.now();
  }

  void _onPointerUp(PointerUpEvent e) {
    final down = _downPos, t0 = _downTime;
    if (down == null || t0 == null) return;
    final isTap = (e.localPosition - down).distance < 14 &&
        DateTime.now().difference(t0).inMilliseconds < 260;
    if (!isTap) return;
    final now = DateTime.now();
    if (_lastTapUp != null &&
        now.difference(_lastTapUp!).inMilliseconds < 300 &&
        (e.localPosition - (_lastTapPos ?? e.localPosition)).distance < 40) {
      _lastTapUp = null;
      _doubleTapZoom(e.localPosition);
    } else {
      _lastTapUp = now;
      _lastTapPos = e.localPosition;
    }
  }

  void _doubleTapZoom(Offset p) {
    final s = _scale;
    final target = s < 1.0 ? 1.25 : (s < 1.8 ? 2.0 : 0.8);
    final scene = _tc.toScene(p);
    HapticFeedback.lightImpact();
    _animateTo(_matrix(target, p.dx - scene.dx * target, p.dy - scene.dy * target));
  }

  // -------------------------------------------------------------- actions

  void _select(String id) {
    if (_selectedId == id) {
      context.push(Routes.person(id));
      return;
    }
    setState(() => _selectedId = id);
  }

  void _setFocus(String id) {
    setState(() {
      _focusId = id;
      _selectedId = id;
      _pendingCenterId = id;
    });
  }

  Future<void> _setMode(TreeViewMode m) async {
    setState(() {
      _mode = m;
      _needsInitialCamera = true;
    });
    await ref.read(settingsProvider.notifier).update((p) => p.copyWith(treeMode: m));
  }

  Future<void> _setGens(int g) async {
    setState(() {
      _gens = g;
      _needsInitialCamera = true;
    });
    await ref.read(settingsProvider.notifier).update((p) => p.copyWith(treeGenerations: g));
  }

  void _toggleCollapse(String id) {
    setState(() {
      if (!_collapsed.remove(id)) _collapsed.add(id);
    });
  }

  Future<void> _navigate(FamilyGraph g, List<String> ids, String what) async {
    if (ids.isEmpty) {
      showFTToast(context, 'No $what recorded yet');
      return;
    }
    String? target = ids.first;
    if (ids.length > 1) {
      target = await showFTOptions<String>(
        context,
        title: 'Go to $what',
        options: [
          for (final id in ids)
            if (g[id] != null) FTOption(id, g[id]!.displayName, subtitle: g[id]!.lifespanLabel),
        ],
      );
    }
    if (target == null || !mounted) return;
    final l = _layout;
    if (l != null && l.nodes.containsKey(target)) {
      setState(() => _selectedId = target);
      _centerOn(target);
    } else {
      _setFocus(target);
    }
  }

  Future<void> _search(FamilyGraph g) async {
    final id = await pickPerson(context, title: 'Find in tree');
    if (id == null || !mounted) return;
    final l = _layout;
    if (l != null && l.nodes.containsKey(id)) {
      setState(() => _selectedId = id);
      _centerOn(id, scale: 1);
    } else {
      _setFocus(id);
    }
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final graphAsync = ref.watch(familyGraphProvider);
    final home = ref.watch(homePersonIdProvider);
    final tree = ref.watch(activeTreeProvider);
    final c = context.ft;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.overlayStyle(c.isDark),
      child: Scaffold(
        backgroundColor: c.bg0,
        body: Stack(
          children: [
            const Positioned.fill(child: FTBackground()),
            Positioned.fill(
              child: graphAsync.when(
                loading: () => const LoadingView(),
                error: (e, _) => ErrorView(error: e),
                data: (g) {
                  if (g.size == 0) {
                    return EmptyState(
                      icon: AppIcons.tree,
                      title: 'Start your family tree',
                      message: 'Add yourself or an ancestor, then connect parents, partners and children.',
                      actionLabel: 'Add a person',
                      onAction: () => context.push(Routes.newPerson()),
                    );
                  }
                  var focus = _focusId;
                  if (focus == null || !g.contains(focus)) focus = home ?? g.people.keys.first;
                  if (_selectedId != null && !g.contains(_selectedId!)) _selectedId = null;
                  // The tree the loaded data belongs to (the active-tree setting changes
                  // a moment before the new tree's data arrives).
                  final layout = _computeLayout(g, focus, g.people.values.first.treeId);
                  return _canvas(g, layout, focus);
                },
              ),
            ),
            // Scrim so the header stays readable over the canvas.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: MediaQuery.paddingOf(context).top + 96,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [c.bg0, c.bg0.withValues(alpha: 0.85), c.bg0.withValues(alpha: 0)],
                      stops: const [0, 0.55, 1],
                    ),
                  ),
                ),
              ),
            ),
            // Header
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(context.pagePadding - 4, 8, context.pagePadding - 4, 0),
                  child: Row(
                    children: [
                      Flexible(
                        child: TreeSwitcherPill(
                          name: tree?.name ?? 'Family tree',
                          modeLabel: _mode.label,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FTIconButton(
                        icon: AppIcons.search,
                        tooltip: 'Find a person',
                        onTap: () {
                          final g = graphAsync.value;
                          if (g != null) _search(g);
                        },
                      ),
                      FTIconButton(
                        icon: AppIcons.layout,
                        tooltip: 'Change layout',
                        onTap: _openLayout,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _canvas(FamilyGraph g, TreeLayout layout, String focus) {
    final c = context.ft;
    final selected = _selectedId;
    final highlight = <String>{};
    if (selected != null && g.contains(selected)) {
      highlight
        ..add(selected)
        ..addAll(g.ancestors(selected))
        ..addAll(g.descendants(selected));
    }
    final lineColor = Color.alphaBlend(c.text.withValues(alpha: c.isDark ? 0.24 : 0.28), c.bg0);
    final mediaById = ref.watch(mediaByIdProvider);
    final showGender = ref.watch(settingsProvider.select((s) => s.showGender));
    // Built once per frame of data, not on every pan/zoom frame.
    final painter = TreeConnectorPainter(
      layout: layout,
      line: lineColor,
      accent: c.accent,
      background: c.bg0,
      highlight: highlight,
      personColors: showGender
          ? {
              for (final id in layout.nodes.keys)
                if (g[id] != null)
                  if (GenderStyle.of(g[id]!.gender, dark: c.isDark) case final gs?) id: gs.color,
            }
          : const {},
    );

    return LayoutBuilder(builder: (context, cons) {
      _viewport = cons.biggest;
      if (_needsInitialCamera || _pendingCenterId != null) {
        final pending = _pendingCenterId;
        _needsInitialCamera = false;
        _pendingCenterId = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (pending != null && layout.nodes.containsKey(pending)) {
            _centerOn(pending, scale: 1);
          } else {
            // Instantly: the tab may still be hidden (e.g. behind the import
            // screen), where animations do not run.
            _resetCamera(focus, animate: false);
          }
        });
      }
      final size = layout.size;
      final depth = generationDepth(g, focus);
      final gens = g.generations();
      final shown = {for (final id in layout.nodes.keys) gens[id]}.length;
      return Stack(
        children: [
          Positioned.fill(
            child: Listener(
              onPointerDown: _onPointerDown,
              onPointerUp: _onPointerUp,
              child: InteractiveViewer.builder(
                transformationController: _tc,
                boundaryMargin: EdgeInsets.all(math.max(cons.maxWidth, cons.maxHeight)),
                minScale: _minScale,
                maxScale: _maxScale,
                onInteractionStart: (_) => _anim.stop(),
                builder: (context, viewport) {
                  // Virtualise: only build nodes intersecting the viewport.
                  final vr = _quadBounds(viewport).inflate(220);
                  final opts = layout.options;
                  return SizedBox(
                    width: size.width,
                    height: size.height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: RepaintBoundary(child: CustomPaint(painter: painter)),
                        ),
                        for (final n in layout.nodes.values)
                          if (vr.overlaps(n.rect(opts)) && g[n.id] != null)
                            Positioned(
                              left: n.x,
                              top: n.y - TreeNodeCard.badgeSpace,
                              child: TreeNodeCard(
                                key: ValueKey(n.id),
                                person: g[n.id]!,
                                node: n,
                                options: opts,
                                imagePath: _avatarPath(mediaById, g[n.id]!),
                                selected: n.id == selected,
                                dimmed: selected != null && !highlight.contains(n.id),
                                collapsed: _collapsed.contains(n.id),
                                onTap: () => _select(n.id),
                                onExpandChildren: () {
                                  if (_collapsed.contains(n.id)) {
                                    _toggleCollapse(n.id);
                                  } else {
                                    _setFocus(n.id);
                                  }
                                },
                                onRevealParents: () => _setFocus(n.id),
                                showGender: showGender,
                              ),
                            ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          // Right-hand floating toolbar.
          Positioned(
            right: context.pagePadding - 6,
            top: MediaQuery.paddingOf(context).top + 84,
            child: TreeToolbar(
              onZoomIn: () => _zoomBy(1.3),
              onZoomOut: () => _zoomBy(1 / 1.3),
              onFit: _fit,
              onReset: () => _resetCamera(focus),
              onGenerations: () => showGenerationSheet(
                context,
                value: _gens,
                depth: depth,
                total: depth.total,
                shown: shown,
                focusName: g[focus]?.shortName ?? 'the focus person',
                onChanged: _setGens,
              ),
              generations: shown,
            ),
          ),
          // Bottom: selection panel or hint + add button.
          Positioned(
            left: context.pagePadding,
            right: context.pagePadding,
            bottom: AppShell.navClearance(context),
            child: AnimatedSwitcher(
              duration: context.reduceMotion ? Duration.zero : Motion.medium,
              switchInCurve: Motion.emphasized,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(a),
                  child: child,
                ),
              ),
              child: selected != null && g[selected] != null
                  ? SelectedPersonPanel(
                      key: ValueKey(selected),
                      person: g[selected]!,
                      graph: g,
                      isFocus: selected == focus,
                      collapsed: _collapsed.contains(selected),
                      hasChildren: g.childIds(selected).isNotEmpty,
                      hasParents: g.parentIds(selected).isNotEmpty,
                      hasPartners: g.partnerIds(selected).isNotEmpty,
                      onClose: () => setState(() => _selectedId = null),
                      onProfile: () => context.push(Routes.person(selected)),
                      onFocus: () => _setFocus(selected),
                      onParents: () => _navigate(g, g.parentIds(selected), 'parents'),
                      onChildren: () => _navigate(g, g.childIds(selected), 'children'),
                      onPartners: () => _navigate(g, g.partnerIds(selected), 'partners'),
                      onToggleCollapse: () => _toggleCollapse(selected),
                      onAddRelative: () => showAddRelativeSheet(context, selected, g[selected]!.shortName),
                    )
                  : Row(
                      key: const ValueKey('hint'),
                      children: [
                        Expanded(
                          child: FTPill(
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                            child: Text(
                              'Tap a person to select · tap again for profile · double-tap to zoom',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: context.tx.caption,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        FTIconButton(
                          icon: AppIcons.personAdd,
                          tooltip: 'Add family member',
                          accent: true,
                          size: 56,
                          onTap: () => context.push(Routes.newPerson()),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      );
    });
  }

  void _openLayout() => showTreeLayoutSheet(context, mode: _mode, onMode: _setMode);

  String? _avatarPath(Map<String, MediaAsset> media, Person p) {
    final id = p.profileMediaId;
    if (id == null) return null;
    final m = media[id];
    if (m == null) return null;
    return AppPaths.I.resolve(m.thumbPath ?? m.filePath);
  }

  static Rect _quadBounds(dynamic quad) {
    final pts = [quad.point0, quad.point1, quad.point2, quad.point3];
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (final p in pts) {
      minX = math.min(minX, p.x);
      minY = math.min(minY, p.y);
      maxX = math.max(maxX, p.x);
      maxY = math.max(maxY, p.y);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}
