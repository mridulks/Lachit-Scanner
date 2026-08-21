import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cv/book_geometry.dart';
import '../../core/cv/book_processor.dart';
import '../../core/cv/gutter_detector.dart';
import '../../core/cv/warp.dart';
import '../../core/providers.dart';
import '../../models/page.dart' as model;
import '../document_editor/document_editor_screen.dart';

/// Reviews the automatic curved-gutter estimate and remains the manual
/// fallback when the image has no dependable spine evidence.
class GutterAdjustScreen extends ConsumerStatefulWidget {
  final WarpResult spread;
  final model.ColorMode colorMode;

  const GutterAdjustScreen({
    super.key,
    required this.spread,
    required this.colorMode,
  });

  @override
  ConsumerState<GutterAdjustScreen> createState() => _GutterAdjustScreenState();
}

class _GutterAdjustScreenState extends ConsumerState<GutterAdjustScreen> {
  ui.Image? _decoded;
  GutterPath? _gutter;
  GutterDetection? _detection;
  bool _saving = false;
  int _draggingPoint = -1;
  double _scale = 1;
  Offset _origin = Offset.zero;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final codec = await ui.instantiateImageCodec(widget.spread.jpegBytes);
    final frame = await codec.getNextFrame();
    GutterDetection? detection;
    try {
      detection = GutterDetector.detect(widget.spread.jpegBytes);
    } catch (_) {
      // A manual centred path is always available if OpenCV cannot analyse a
      // particular device/image format.
    }
    if (!mounted) return;
    setState(() {
      _decoded = frame.image;
      _detection = detection;
      _gutter = detection?.path ??
          GutterPath.centered(
            width: frame.image.width.toDouble(),
            height: frame.image.height.toDouble(),
          );
    });
  }

  void _updateTransform(Size size) {
    if (_decoded == null) return;
    final imageSize = Size(
      _decoded!.width.toDouble(),
      _decoded!.height.toDouble(),
    );
    _scale = min(size.width / imageSize.width, size.height / imageSize.height);
    _origin = Offset(
      (size.width - imageSize.width * _scale) / 2,
      (size.height - imageSize.height * _scale) / 2,
    );
  }

  Offset _imageToScreen(Point<double> point) =>
      Offset(point.x * _scale, point.y * _scale) + _origin;

  int _nearestControlPoint(Offset screenPoint) {
    final points = _gutter!.points;
    var nearest = 0;
    var distance = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final candidate = (_imageToScreen(points[i]) - screenPoint).distance;
      if (candidate < distance) {
        nearest = i;
        distance = candidate;
      }
    }
    // Tapping anywhere on the image chooses the closest row. This makes
    // editing usable even where a handle sits near the display edge.
    return nearest;
  }

  void _updateGutter(Offset localPosition, {required bool start}) {
    if (_decoded == null || _gutter == null) return;
    if (start) {
      _draggingPoint = _nearestControlPoint(localPosition);
    }
    if (_draggingPoint < 0) return;
    final x = ((localPosition.dx - _origin.dx) / _scale).clamp(
      0.0,
      _decoded!.width.toDouble(),
    );
    final old = _gutter!.points[_draggingPoint];
    setState(
      () => _gutter = _gutter!.withPoint(_draggingPoint, Point(x, old.y)),
    );
  }

  void _resetToCenter() {
    if (_decoded == null) return;
    setState(
      () => _gutter = GutterPath.centered(
        width: _decoded!.width.toDouble(),
        height: _decoded!.height.toDouble(),
      ),
    );
  }

  Future<void> _confirm() async {
    if (_gutter == null || _saving) return;
    setState(() => _saving = true);
    try {
      final split = BookProcessor.splitAndWarpPath(
        spread: widget.spread,
        gutter: _gutter!,
        colorMode: widget.colorMode,
      );
      final storage = ref.read(storageProvider);
      var doc = ref.read(activeDocumentProvider);
      doc ??= await storage.createDocument();
      ref.read(activeDocumentProvider.notifier).state = doc;
      final docDir = await storage.documentDir(doc.id);

      Future<void> savePage(
        Uint8List bytes,
        model.PageSourceMode sourceMode,
      ) async {
        final id = storage.newId();
        final path = '${docDir.path}/$id.jpg';
        await File(path).writeAsBytes(bytes);
        await storage.addPage(
          doc!,
          imagePath: path,
          sourceMode: sourceMode,
          colorMode: widget.colorMode,
        );
      }

      await savePage(split.left.jpegBytes, model.PageSourceMode.bookLeft);
      await savePage(split.right.jpegBytes, model.PageSourceMode.bookRight);
      ref.read(documentVersionProvider.notifier).state++;
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => DocumentEditorScreen(documentId: doc!.id),
        ),
        (route) => route.isFirst,
      );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Processing failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final automatic = _detection?.isReliable ?? false;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Review book gutter'),
      ),
      body: _decoded == null || _gutter == null
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : LayoutBuilder(
              builder: (context, constraints) {
                _updateTransform(
                  Size(constraints.maxWidth, constraints.maxHeight),
                );
                return GestureDetector(
                  onPanStart: (details) =>
                      _updateGutter(details.localPosition, start: true),
                  onPanUpdate: (details) =>
                      _updateGutter(details.localPosition, start: false),
                  onPanEnd: (_) => _draggingPoint = -1,
                  child: CustomPaint(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: _GutterPainter(
                      image: _decoded!,
                      points: _gutter!.points.map(_imageToScreen).toList(),
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
              Text(
                automatic
                    ? 'Automatic gutter detected. Drag any point to fine-tune it.'
                    : 'Could not confidently detect the gutter. Drag the points onto the spine.',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              TextButton(
                onPressed: _resetToCenter,
                child: const Text('Reset to center'),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Back'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _saving ? null : _confirm,
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Split pages'),
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

class _GutterPainter extends CustomPainter {
  final ui.Image image;
  final List<Offset> points;
  const _GutterPainter({required this.image, required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final scale = min(
      size.width / imageSize.width,
      size.height / imageSize.height,
    );
    final destination = Rect.fromLTWH(
      (size.width - imageSize.width * scale) / 2,
      (size.height - imageSize.height * scale) / 2,
      imageSize.width * scale,
      imageSize.height * scale,
    );
    canvas.drawImageRect(image, Offset.zero & imageSize, destination, Paint());
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFFF6B6B)
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke,
    );
    final fill = Paint()..color = Colors.white;
    final border = Paint()
      ..color = const Color(0xFFFF6B6B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (final point in points) {
      canvas.drawCircle(point, 10, fill);
      canvas.drawCircle(point, 10, border);
    }
  }

  @override
  bool shouldRepaint(covariant _GutterPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.points != points;
}
