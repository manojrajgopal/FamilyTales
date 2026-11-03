import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme/app_theme.dart';
import '../../core/database/app_database.dart';
import '../../core/widgets/widgets.dart';
import 'media_tools.dart';

/// Aspect presets offered by the crop editor.
enum CropAspect {
  free('Free', null),
  square('1:1', 1),
  landscape('4:3', 4 / 3),
  portrait('3:4', 3 / 4);

  const CropAspect(this.label, this.ratio);
  final String label;
  final double? ratio;
}

/// Pure geometry for the crop frame, kept out of the widget so it is easy to
/// reason about. All rects here are in display (logical pixel) space.
abstract final class CropGeometry {
  static const minSide = 48.0;

  /// Largest rect with [ratio] (width / height) centred in [bounds].
  static Rect largestWithRatio(Rect bounds, double ratio) {
    var w = bounds.width;
    var h = w / ratio;
    if (h > bounds.height) {
      h = bounds.height;
      w = h * ratio;
    }
    return Rect.fromCenter(center: bounds.center, width: w, height: h);
  }

  /// Moves [r] by [delta] while keeping it inside [bounds].
  static Rect move(Rect r, Offset delta, Rect bounds) {
    var dx = delta.dx, dy = delta.dy;
    if (r.left + dx < bounds.left) dx = bounds.left - r.left;
    if (r.right + dx > bounds.right) dx = bounds.right - r.right;
    if (r.top + dy < bounds.top) dy = bounds.top - r.top;
    if (r.bottom + dy > bounds.bottom) dy = bounds.bottom - r.bottom;
    return r.shift(Offset(dx, dy));
  }

  /// Drags corner [corner] (0 = top-left, 1 = top-right, 2 = bottom-right,
  /// 3 = bottom-left) of [r] to [pos], anchored at the opposite corner,
  /// optionally locking the aspect [ratio].
  static Rect dragCorner(Rect r, int corner, Offset pos, Rect bounds, double? ratio) {
    final anchor = switch (corner) {
      0 => r.bottomRight,
      1 => r.bottomLeft,
      2 => r.topLeft,
      _ => r.topRight,
    };
    final right = corner == 1 || corner == 2;
    final down = corner == 2 || corner == 3;
    final maxW = right ? bounds.right - anchor.dx : anchor.dx - bounds.left;
    final maxH = down ? bounds.bottom - anchor.dy : anchor.dy - bounds.top;
    final minW = math.min(minSide, maxW);
    final minH = math.min(minSide, maxH);
    var w = (right ? pos.dx - anchor.dx : anchor.dx - pos.dx).clamp(minW, maxW).toDouble();
    var h = (down ? pos.dy - anchor.dy : anchor.dy - pos.dy).clamp(minH, maxH).toDouble();
    if (ratio != null) {
      if (w / h > ratio) {
        h = w / ratio;
      } else {
        w = h * ratio;
      }
      if (w > maxW) {
        w = maxW;
        h = w / ratio;
      }
      if (h > maxH) {
        h = maxH;
        w = h * ratio;
      }
    }
    return Rect.fromPoints(anchor, anchor + Offset(right ? w : -w, down ? h : -h));
  }
}

/// Opens the crop editor and returns the crop rectangle in source pixel
/// coordinates, or null when cancelled / unchanged.
Future<Rect?> showCropEditor(BuildContext context, MediaAsset media) {
  return Navigator.of(context).push<Rect>(PageRouteBuilder<Rect>(
    pageBuilder: (_, _, _) => CropScreen(media: media),
    transitionDuration: context.reduceMotion ? Duration.zero : Motion.medium,
    reverseTransitionDuration: context.reduceMotion ? Duration.zero : Motion.fast,
    transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
  ));
}

/// Full-screen crop UI: the photo fitted in a frame with draggable corner
/// handles, a movable selection and Free / 1:1 / 4:3 / 3:4 presets.
class CropScreen extends ConsumerStatefulWidget {
  const CropScreen({super.key, required this.media});
  final MediaAsset media;

  @override
  ConsumerState<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends ConsumerState<CropScreen> {
  static const _maxDecode = 2048;

  late final ImageProvider _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _imageSize;
  bool _failed = false;

  /// Selection, normalised to the image (0…1).
  Rect _crop = const Rect.fromLTRB(0, 0, 1, 1);
  CropAspect _aspect = CropAspect.free;
  Rect _imgRect = Rect.zero;
  int? _corner;
  bool _moving = false;
  Offset _grab = Offset.zero;

  @override
  void initState() {
    super.initState();
    final m = widget.media;
    final file = FileImage(File(m.absolutePath));
    final w = m.width, h = m.height;
    if (w != null && h != null && math.max(w, h) > _maxDecode) {
      _provider = w >= h
          ? ResizeImage(file, width: _maxDecode)
          : ResizeImage(file, height: _maxDecode);
    } else {
      _provider = file;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  void _resolve() {
    if (!mounted) return;
    final stream = _provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener(
      (info, _) {
        final size = Size(info.image.width.toDouble(), info.image.height.toDouble());
        info.dispose();
        if (mounted) setState(() => _imageSize = size);
      },
      onError: (_, _) {
        if (mounted) setState(() => _failed = true);
      },
    );
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  @override
  void dispose() {
    final l = _listener;
    if (l != null) _stream?.removeListener(l);
    super.dispose();
  }

  Rect _toDisplay(Rect n) => Rect.fromLTRB(
        _imgRect.left + n.left * _imgRect.width,
        _imgRect.top + n.top * _imgRect.height,
        _imgRect.left + n.right * _imgRect.width,
        _imgRect.top + n.bottom * _imgRect.height,
      );

  Rect _toNorm(Rect d) => Rect.fromLTRB(
        ((d.left - _imgRect.left) / _imgRect.width).clamp(0.0, 1.0),
        ((d.top - _imgRect.top) / _imgRect.height).clamp(0.0, 1.0),
        ((d.right - _imgRect.left) / _imgRect.width).clamp(0.0, 1.0),
        ((d.bottom - _imgRect.top) / _imgRect.height).clamp(0.0, 1.0),
      );

  void _setAspect(CropAspect a) {
    HapticFeedback.selectionClick();
    setState(() {
      _aspect = a;
      final ratio = a.ratio;
      if (ratio == null || _imgRect.isEmpty) return;
      _crop = _toNorm(CropGeometry.largestWithRatio(_imgRect, ratio));
    });
  }

  void _reset() {
    setState(() {
      _aspect = CropAspect.free;
      _crop = const Rect.fromLTRB(0, 0, 1, 1);
    });
  }

  void _panStart(DragStartDetails d) {
    if (_imgRect.isEmpty) return;
    final r = _toDisplay(_crop);
    final corners = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
    int? best;
    var bestDist = 40.0;
    for (var i = 0; i < corners.length; i++) {
      final dist = (corners[i] - d.localPosition).distance;
      if (dist < bestDist) {
        best = i;
        bestDist = dist;
      }
    }
    if (best != null) {
      _corner = best;
      _moving = false;
      _grab = corners[best] - d.localPosition;
    } else {
      _corner = null;
      _moving = r.contains(d.localPosition);
    }
  }

  void _panUpdate(DragUpdateDetails d) {
    if (_imgRect.isEmpty) return;
    final r = _toDisplay(_crop);
    if (_moving) {
      setState(() => _crop = _toNorm(CropGeometry.move(r, d.delta, _imgRect)));
    } else if (_corner != null) {
      final next = CropGeometry.dragCorner(r, _corner!, d.localPosition + _grab, _imgRect, _aspect.ratio);
      setState(() => _crop = _toNorm(next));
    }
  }

  void _panEnd(DragEndDetails _) {
    _corner = null;
    _moving = false;
  }

  void _apply() {
    final m = widget.media;
    final full = _imageSize;
    final srcW = (m.width ?? full?.width.round() ?? 0).toDouble();
    final srcH = (m.height ?? full?.height.round() ?? 0).toDouble();
    if (srcW <= 0 || srcH <= 0) {
      Navigator.of(context).pop();
      return;
    }
    const eps = 0.004;
    if (_crop.left < eps && _crop.top < eps && _crop.right > 1 - eps && _crop.bottom > 1 - eps) {
      Navigator.of(context).pop();
      return;
    }
    final x = (_crop.left * srcW).roundToDouble();
    final y = (_crop.top * srcH).roundToDouble();
    final w = math.max(1.0, (_crop.width * srcW).roundToDouble());
    final h = math.max(1.0, (_crop.height * srcH).roundToDouble());
    Navigator.of(context).pop(Rect.fromLTWH(x, y, w, h));
  }

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(settingsProvider.select((s) => s.accent));
    return Theme(
      data: AppTheme.build(dark: true, accent: accent),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.overlayStyle(true),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Builder(builder: _body),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final c = context.ft;
    final pad = context.pagePadding;
    final pxLabel = () {
      final w = widget.media.width ?? _imageSize?.width.round();
      final h = widget.media.height ?? _imageSize?.height.round();
      if (w == null || h == null) return '';
      return '${(_crop.width * w).round()} × ${(_crop.height * h).round()} px';
    }();
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(pad - 4, Gap.xs, pad - 4, Gap.xs),
            child: Row(
              children: [
                FTIconButton(icon: AppIcons.close, tooltip: 'Cancel', onTap: () => Navigator.of(context).pop()),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Crop', style: context.tx.title, maxLines: 1),
                      if (pxLabel.isNotEmpty)
                        Text(pxLabel, style: context.tx.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                FTIconButton(
                  icon: AppIcons.check,
                  tooltip: 'Apply crop',
                  accent: true,
                  onTap: _imageSize == null ? null : _apply,
                ),
              ],
            ),
          ),
          Expanded(
            child: _failed
                ? const EmptyState(
                    icon: AppIcons.warning,
                    title: 'This image can’t be edited',
                    message: 'The file format is not supported for cropping.',
                  )
                : (_imageSize == null
                    ? const LoadingView()
                    : LayoutBuilder(builder: (context, cons) {
                        const inset = 28.0;
                        final avail = Rect.fromLTWH(
                            inset, inset, math.max(1, cons.maxWidth - inset * 2), math.max(1, cons.maxHeight - inset * 2));
                        final fitted = applyBoxFit(BoxFit.contain, _imageSize!, avail.size).destination;
                        _imgRect = Alignment.center.inscribe(fitted, avail);
                        final sel = _toDisplay(_crop);
                        return Semantics(
                          label: 'Crop area. Drag the corners to resize, drag inside to move.',
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: _panStart,
                            onPanUpdate: _panUpdate,
                            onPanEnd: _panEnd,
                            child: Stack(
                              children: [
                                Positioned.fromRect(
                                  rect: _imgRect,
                                  child: Image(image: _provider, fit: BoxFit.fill, gaplessPlayback: true),
                                ),
                                Positioned.fill(
                                  child: RepaintBoundary(
                                    child: CustomPaint(painter: _CropPainter(sel, _imgRect, c.accent)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      })),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(pad, Gap.sm, pad, Gap.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: Gap.xs,
                  runSpacing: Gap.xs,
                  children: [
                    for (final a in CropAspect.values)
                      FTChip(label: a.label, selected: _aspect == a, onTap: () => _setAspect(a)),
                  ],
                ),
                const SizedBox(height: Gap.xs),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text('Drag the corners or move the frame',
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.tx.caption),
                    ),
                    const SizedBox(width: Gap.xs),
                    FTTextAction('Reset', accent: true, onTap: _reset),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.sel, this.image, this.accent);
  final Rect sel;
  final Rect image;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    // Dim everything outside the selection (within the image).
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(image)
      ..addRect(sel);
    canvas.drawPath(shade, Paint()..color = Colors.black.withValues(alpha: 0.6));

    // Rule-of-thirds grid.
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = sel.left + sel.width * i / 3;
      final y = sel.top + sel.height * i / 3;
      canvas.drawLine(Offset(x, sel.top), Offset(x, sel.bottom), grid);
      canvas.drawLine(Offset(sel.left, y), Offset(sel.right, y), grid);
    }

    canvas.drawRect(
      sel,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.85),
    );

    // Corner handles.
    final h = Paint()
      ..color = accent
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final len = math.min(22.0, math.min(sel.width, sel.height) / 3);
    void corner(Offset p, double sx, double sy) {
      canvas.drawLine(p, p + Offset(sx * len, 0), h);
      canvas.drawLine(p, p + Offset(0, sy * len), h);
    }

    corner(sel.topLeft, 1, 1);
    corner(sel.topRight, -1, 1);
    corner(sel.bottomRight, -1, -1);
    corner(sel.bottomLeft, 1, -1);
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.sel != sel || old.image != image || old.accent != accent;
}
