// Manual corner adjustment (design doc §3, step "manual corner adjustment
// screen"). Auto-detect pre-populates the outer quad; the user can drag
// any of the 4 CORNER handles to move that corner alone, or any of the 4
// EDGE (midpoint) handles to translate that whole side up/down/left/right
// — 8 handles total. This is the essential fallback for dark book covers,
// low-contrast pages on white desks, etc.
//
// Book Mode also exposes a gutter guide here. It is stored in flattened
// spread coordinates and projected onto the raw photo for editing.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cv/book_processor.dart';
import '../../core/cv/book_detector.dart';
import '../../core/cv/book_geometry.dart';
import '../../core/cv/edge_detector.dart';
import '../../core/cv/warp.dart';
import '../../core/providers.dart';
import '../../core/scan_kind.dart';
import '../../models/page.dart' as model;
import '../document_editor/document_editor_screen.dart';

class CornerAdjustScreen extends ConsumerStatefulWidget {
  final String capturedImagePath;
  final ScanKind scanKind;
  final BookScanMode bookScanMode;
  const CornerAdjustScreen({
    super.key,
    required this.capturedImagePath,
    this.scanKind = ScanKind.document,
    this.bookScanMode = BookScanMode.twoPage,
  });

  @override
  ConsumerState<CornerAdjustScreen> createState() => _CornerAdjustScreenState();
}

// Which two corner indices bound each edge, in the same TL,TR,BR,BL
// winding order as _corners. Edge handle i sits at the midpoint of
// corners[_edgeCornerPairs[i][0]] <-> corners[_edgeCornerPairs[i][1]].
const _edgeCornerPairs = [
  [0, 1], // top
  [1, 2], // right
  [2, 3], // bottom
  [3, 0], // left
];

class _CornerAdjustScreenState extends ConsumerState<CornerAdjustScreen> {
  Uint8List? _bytes;
  ui.Image? _decoded;
  List<Point<double>>? _corners; // in IMAGE pixel space
  GutterPath? _gutter; // in flattened spread pixel space
  bool _detecting = true;
  bool _saving = false;

  // -1 = not dragging. 0-3 = dragging a corner handle directly.
  // 4-7 = dragging edge handle (index - 4), which translates both of
  // that edge's corners together.
  int _draggingIndex = -1;
  Point<double>? _lastDragImagePoint; // for delta-based edge translation
  int _draggingGutterIndex = -1;

  model.ColorMode _colorMode = model.ColorMode.grayscale;

  // Screen<->image coordinate mapping, computed on layout.
  double _scale = 1;
  Offset _origin = Offset.zero;

  @override
  void initState() {
    super.initState();
    if (widget.scanKind == ScanKind.book) {
      // Printed book pages retain far more detail in grayscale. B&W remains
      // available when a deliberately high-contrast scan is wanted.
      _colorMode = model.ColorMode.grayscale;
    }
    _load();
  }

  Future<void> _load() async {
    final bytes = await File(widget.capturedImagePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();

    DetectedQuad? quad;
    try {
      // Books are detected by their dedicated detector. It currently uses
      // the established contour scorer internally, but returns book-specific
      // geometry so its implementation can evolve independently.
      if (widget.scanKind == ScanKind.book) {
        final book = BookDetector.detect(bytes);
        quad = book == null
            ? null
            : DetectedQuad(book.outerBoundary, book.confidence);
      } else {
        quad = EdgeDetector.detect(bytes);
      }
    } catch (_) {
      quad = null; // fall through to manual fallback quad below
    }

    setState(() {
      _bytes = bytes;
      _decoded = frame.image;
      _corners = quad?.corners ??
          EdgeDetector.fallbackQuad(
            frame.image.width.toDouble(),
            frame.image.height.toDouble(),
          );
      final (rawWidth, rawHeight) = ImageWarper.outputSizeForQuad(_corners!);
      final spreadWidth = rawHeight > rawWidth ? rawHeight : rawWidth;
      final spreadHeight = rawHeight > rawWidth ? rawWidth : rawHeight;
      _gutter = GutterPath.centered(
        width: spreadWidth.toDouble(),
        height: spreadHeight.toDouble(),
      );
      _detecting = false;
    });
  }

  void _updateTransform(Size viewSize) {
    if (_decoded == null) return;
    final imgW = _decoded!.width.toDouble();
    final imgH = _decoded!.height.toDouble();
    final scale = min(viewSize.width / imgW, viewSize.height / imgH);
    final dispW = imgW * scale;
    final dispH = imgH * scale;
    _scale = scale;
    _origin = Offset(
      (viewSize.width - dispW) / 2,
      (viewSize.height - dispH) / 2,
    );
  }

  Offset _imageToScreen(Point<double> p) =>
      Offset(p.x * _scale, p.y * _scale) + _origin;

  Point<double> _screenToImage(Offset o) {
    final local = o - _origin;
    return Point(local.dx / _scale, local.dy / _scale);
  }

  List<Point<double>> _edgeMidpoints() {
    final c = _corners!;
    return [
      for (final pair in _edgeCornerPairs)
        Point(
          (c[pair[0]].x + c[pair[1]].x) / 2,
          (c[pair[0]].y + c[pair[1]].y) / 2,
        ),
    ];
  }

  Point<double> _lerpPoint(
    Point<double> a,
    Point<double> b,
    double amount,
  ) =>
      Point(
        a.x + (b.x - a.x) * amount,
        a.y + (b.y - a.y) * amount,
      );

  (double, double) _gutterSize() {
    final c = _corners!;
    final (width, height) = ImageWarper.outputSizeForQuad(c);
    return height > width
        ? (height.toDouble(), width.toDouble())
        : (width.toDouble(), height.toDouble());
  }

  Point<double> _gutterPointInImage(Point<double> point) {
    final c = _corners!;
    final (rawWidth, rawHeight) = ImageWarper.outputSizeForQuad(c);
    final rotated = rawHeight > rawWidth;
    final u = point.x / _gutterSize().$1;
    final v = point.y / _gutterSize().$2;
    final sourceU = rotated ? 1 - v : u;
    final sourceV = rotated ? u : v;
    return _lerpPoint(
      _lerpPoint(c[0], c[1], sourceU),
      _lerpPoint(c[3], c[2], sourceU),
      sourceV,
    );
  }

  List<Point<double>> _gutterImagePoints() =>
      _gutter?.points.map(_gutterPointInImage).toList() ?? const [];

  int? _hitTestGutter(Offset screenPos) {
    const hitRadius = 28.0;
    final points = _gutterImagePoints();
    for (var i = 0; i < points.length; i++) {
      if ((_imageToScreen(points[i]) - screenPos).distance <= hitRadius) {
        return i;
      }
    }
    return null;
  }

  void _updateGutter(Offset screenPosition) {
    if (_gutter == null || _corners == null) return;
    final imagePoint = _screenToImage(screenPosition);
    final control = _gutter!.points[_draggingGutterIndex];
    final (width, height) = _gutterSize();
    final c = _corners!;
    final (rawWidth, rawHeight) = ImageWarper.outputSizeForQuad(c);
    final rotated = rawHeight > rawWidth;
    final fixed = rotated ? 1 - control.y / height : control.y / height;
    final first =
        rotated ? _lerpPoint(c[0], c[1], fixed) : _lerpPoint(c[0], c[3], fixed);
    final second =
        rotated ? _lerpPoint(c[3], c[2], fixed) : _lerpPoint(c[1], c[2], fixed);
    final dx = second.x - first.x;
    final dy = second.y - first.y;
    final denominator = dx * dx + dy * dy;
    if (denominator == 0) return;
    final along =
        ((imagePoint.x - first.x) * dx + (imagePoint.y - first.y) * dy) /
            denominator;
    final x = (along.clamp(0.0, 1.0) * width).toDouble();
    setState(() {
      _gutter = _gutter!.withPoint(
        _draggingGutterIndex,
        Point(x, control.y),
      );
    });
  }

  int? _hitTestHandle(Offset screenPos) {
    if (_corners == null) return null;
    const hitRadius = 28.0;

    // Corner handles take priority (indices 0-3).
    for (var i = 0; i < 4; i++) {
      final p = _imageToScreen(_corners![i]);
      if ((p - screenPos).distance <= hitRadius) return i;
    }
    // Edge/midpoint handles (indices 4-7).
    final mids = _edgeMidpoints();
    for (var i = 0; i < mids.length; i++) {
      final p = _imageToScreen(mids[i]);
      if ((p - screenPos).distance <= hitRadius) return 4 + i;
    }
    return null;
  }

  Future<void> _confirm({bool useCenteredGutter = false}) async {
    if (_bytes == null || _corners == null || _saving) return;
    setState(() => _saving = true);
    try {
      final storage = ref.read(storageProvider);
      var doc = ref.read(activeDocumentProvider);
      doc ??= await storage.createDocument();
      ref.read(activeDocumentProvider.notifier).state = doc;

      if (widget.scanKind == ScanKind.book) {
        if (widget.bookScanMode == BookScanMode.singlePage) {
          final result = ImageWarper.warpAndEnhance(
            imageBytes: _bytes!,
            corners: _corners!,
            colorMode: _colorMode,
          );
          final docDir = await storage.documentDir(doc.id);
          final pageId = storage.newId();
          final outPath = '${docDir.path}/$pageId.jpg';
          await File(outPath).writeAsBytes(result.jpegBytes);
          await storage.addPage(
            doc,
            imagePath: outPath,
            sourceMode: model.PageSourceMode.bookLeft,
            colorMode: _colorMode,
          );
          ref.read(documentVersionProvider.notifier).state++;
          if (!mounted) return;
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => DocumentEditorScreen(documentId: doc!.id),
            ),
            (route) => route.isFirst,
          );
          return;
        }
        final spread = BookProcessor.flattenSpread(
          imageBytes: _bytes!,
          outerCorners: _corners!,
        );
        if (useCenteredGutter) {
          final split = BookProcessor.splitAndWarpPath(
            spread: spread,
            gutter: _gutter ??
                GutterPath.centered(
                  width: spread.width.toDouble(),
                  height: spread.height.toDouble(),
                ),
            colorMode: _colorMode,
          );
          final docDir = await storage.documentDir(doc.id);

          Future<void> saveBookPage(
            Uint8List bytes,
            model.PageSourceMode sourceMode,
          ) async {
            final pageId = storage.newId();
            final path = '${docDir.path}/$pageId.jpg';
            await File(path).writeAsBytes(bytes);
            await storage.addPage(
              doc!,
              imagePath: path,
              sourceMode: sourceMode,
              colorMode: _colorMode,
            );
          }

          await saveBookPage(
              split.left.jpegBytes, model.PageSourceMode.bookLeft);
          await saveBookPage(
              split.right.jpegBytes, model.PageSourceMode.bookRight);
          ref.read(documentVersionProvider.notifier).state++;
          if (!mounted) return;
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => DocumentEditorScreen(documentId: doc!.id),
            ),
            (route) => route.isFirst,
          );
          return;
        }
        return;
      }

      final docDir = await storage.documentDir(doc.id);
      final result = ImageWarper.warpAndEnhance(
        imageBytes: _bytes!,
        corners: _corners!,
        colorMode: _colorMode,
      );
      final pageId = storage.newId();
      final outPath = '${docDir.path}/$pageId.jpg';
      await File(outPath).writeAsBytes(result.jpegBytes);
      await storage.addPage(doc, imagePath: outPath, colorMode: _colorMode);

      ref.read(documentVersionProvider.notifier).state++;

      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => DocumentEditorScreen(documentId: doc!.id),
        ),
        (route) => route.isFirst,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Processing failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.scanKind == ScanKind.book
              ? 'Adjust book spread corners'
              : 'Adjust corners',
        ),
      ),
      body: _detecting || _decoded == null
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : LayoutBuilder(
              builder: (context, constraints) {
                _updateTransform(
                  Size(constraints.maxWidth, constraints.maxHeight),
                );
                return GestureDetector(
                  onPanStart: (d) {
                    final gutterIndex = widget.scanKind == ScanKind.book &&
                            widget.bookScanMode == BookScanMode.twoPage
                        ? _hitTestGutter(d.localPosition)
                        : null;
                    if (gutterIndex != null) {
                      _draggingGutterIndex = gutterIndex;
                      _draggingIndex = -1;
                      return;
                    }
                    final idx = _hitTestHandle(d.localPosition) ?? -1;
                    _draggingIndex = idx;
                    _lastDragImagePoint =
                        idx == -1 ? null : _screenToImage(d.localPosition);
                  },
                  onPanUpdate: (d) {
                    if (_draggingGutterIndex >= 0) {
                      _updateGutter(d.localPosition);
                      return;
                    }
                    if (_draggingIndex == -1) return;
                    final newPoint = _screenToImage(d.localPosition);
                    setState(() {
                      if (_draggingIndex < 4) {
                        // Corner drag: move that corner directly.
                        _corners![_draggingIndex] = newPoint;
                      } else {
                        // Edge drag: translate both of that edge's
                        // corners by the same delta, so the whole side
                        // moves as a rigid unit up/down/left/right.
                        final dx = newPoint.x - _lastDragImagePoint!.x;
                        final dy = newPoint.y - _lastDragImagePoint!.y;
                        for (final cornerIdx
                            in _edgeCornerPairs[_draggingIndex - 4]) {
                          final c = _corners![cornerIdx];
                          _corners![cornerIdx] = Point(c.x + dx, c.y + dy);
                        }
                      }
                    });
                    _lastDragImagePoint = newPoint;
                  },
                  onPanEnd: (_) {
                    _draggingIndex = -1;
                    _draggingGutterIndex = -1;
                    _lastDragImagePoint = null;
                  },
                  child: CustomPaint(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: _QuadPainter(
                      image: _decoded!,
                      corners: _corners!.map(_imageToScreen).toList(),
                      edgeMidpoints:
                          _edgeMidpoints().map(_imageToScreen).toList(),
                      gutter: widget.scanKind == ScanKind.book &&
                              widget.bookScanMode == BookScanMode.twoPage
                          ? _gutterImagePoints().map(_imageToScreen).toList()
                          : null,
                    ),
                  ),
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<model.ColorMode>(
                style: ButtonStyle(
                  side: WidgetStateProperty.resolveWith((states) {
                    return const BorderSide(color: Colors.white);
                  }),
                  foregroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.selected)) {
                      return Colors.black;
                    }
                    return Colors.white;
                  }),
                  iconColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.selected)) {
                      return Colors.black;
                    }
                    return Colors.white;
                  }),
                  textStyle: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.selected)) {
                      return const TextStyle(fontWeight: FontWeight.w600);
                    }
                    return const TextStyle(fontWeight: FontWeight.w400);
                  }),
                ),
                segments: const [
                  ButtonSegment(
                    value: model.ColorMode.color,
                    label: Text('Color'),
                    icon: Icon(Icons.palette_outlined),
                  ),
                  ButtonSegment(
                    value: model.ColorMode.grayscale,
                    label: Text('Grayscale'),
                    icon: Icon(Icons.gradient_outlined),
                  ),
                  ButtonSegment(
                    value: model.ColorMode.bw,
                    label: Text('B&W'),
                    icon: Icon(Icons.contrast),
                  ),
                ],
                selected: {_colorMode},
                onSelectionChanged: (selected) {
                  setState(() => _colorMode = selected.first);
                },
              ),
              const SizedBox(height: 12),
              if (widget.scanKind == ScanKind.book &&
                  widget.bookScanMode == BookScanMode.twoPage)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Drag the gutter points if needed, then split the spread.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Retake'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _saving
                          ? null
                          : () => _confirm(
                                useCenteredGutter: widget.scanKind ==
                                        ScanKind.book &&
                                    widget.bookScanMode == BookScanMode.twoPage,
                              ),
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              widget.scanKind == ScanKind.book
                                  ? widget.bookScanMode ==
                                          BookScanMode.singlePage
                                      ? 'Save'
                                      : 'Split at centre'
                                  : 'Use this',
                            ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuadPainter extends CustomPainter {
  final ui.Image image;
  final List<Offset> corners; // screen space, TL,TR,BR,BL
  final List<Offset> edgeMidpoints; // screen space, top/right/bottom/left
  final List<Offset>? gutter;

  _QuadPainter({
    required this.image,
    required this.corners,
    required this.edgeMidpoints,
    this.gutter,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw the captured photo, letterboxed.
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();
    final scale = min(size.width / imgW, size.height / imgH);
    final dispW = imgW * scale;
    final dispH = imgH * scale;
    final dst = Rect.fromLTWH(
      (size.width - dispW) / 2,
      (size.height - dispH) / 2,
      dispW,
      dispH,
    );
    canvas.drawImageRect(image, src, dst, Paint());

    if (corners.length != 4) return;

    final quadPaint = Paint()
      ..color = const Color(0xFF34D058)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final fillPaint = Paint()
      ..color = const Color(0x3334D058)
      ..style = PaintingStyle.fill;

    final path = Path()..addPolygon(corners, true);
    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, quadPaint);

    if (gutter != null && gutter!.length >= 2) {
      final guidePaint = Paint()
        ..color = const Color(0xFFFFB020)
        ..strokeWidth = 4
        ..style = PaintingStyle.stroke;
      final guide = Path()..moveTo(gutter!.first.dx, gutter!.first.dy);
      for (final point in gutter!.skip(1)) {
        guide.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(guide, guidePaint);
      final gutterHandlePaint = Paint()..color = Colors.white;
      final gutterHandleBorder = Paint()
        ..color = const Color(0xFFFFB020)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      for (final point in gutter!) {
        canvas.drawCircle(
          point,
          8,
          gutterHandlePaint,
        );
        canvas.drawCircle(point, 8, gutterHandleBorder);
      }
    }

    // Corner handles — larger, filled white with green ring.
    final handlePaint = Paint()..color = Colors.white;
    final handleBorder = Paint()
      ..color = const Color(0xFF34D058)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (final c in corners) {
      canvas.drawCircle(c, 12, handlePaint);
      canvas.drawCircle(c, 12, handleBorder);
    }

    // Edge (midpoint) handles — smaller, hollow, so they read as
    // secondary controls without competing visually with the corners.
    final edgeHandlePaint = Paint()..color = const Color(0xCCFFFFFF);
    final edgeHandleBorder = Paint()
      ..color = const Color(0xFF34D058)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    for (final m in edgeMidpoints) {
      canvas.drawCircle(m, 8, edgeHandlePaint);
      canvas.drawCircle(m, 8, edgeHandleBorder);
    }
  }

  @override
  bool shouldRepaint(covariant _QuadPainter oldDelegate) => true;
}
