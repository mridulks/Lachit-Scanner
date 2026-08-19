// Gutter (spine fold) preview + adjustment — the missing link in Book
// Mode: without this, an auto-detected gutter that lands in the wrong
// place had no way to be caught before two bad pages got saved. Same
// philosophy as Document Mode's corner-adjust fallback: show the
// detection, let the user drag it, THEN process.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cv/book_processor.dart';
import '../../core/cv/gutter_detector.dart';
import '../../core/cv/warp.dart';
import '../../core/providers.dart';
import '../../models/page.dart' as model;
import '../document_editor/document_editor_screen.dart';

class GutterAdjustScreen extends ConsumerStatefulWidget {
  /// The already-flattened whole-spread image (Book Mode stage 1 output).
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
  GutterLine? _gutter;
  GutterLine? _detectedGutter; // original auto-detected line, kept for "reset to detected"
  bool _detecting = true;
  bool _saving = false;

  // 0 = dragging top handle, 1 = dragging bottom handle, -1 = none.
  int _draggingHandle = -1;

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

    GutterLine gutter;
    try {
      gutter = BookProcessor.detectGutter(widget.spread);
    } catch (_) {
      // Detection genuinely failing (not just landing off) is rare, but
      // fall back to dead-center rather than leaving the user stuck.
      final w = frame.image.width.toDouble();
      gutter = GutterLine(w / 2, w / 2);
    }

    setState(() {
      _decoded = frame.image;
      _gutter = gutter;
      _detectedGutter = gutter;
      _detecting = false;
    });
  }

  void _resetToCenter() {
    if (_decoded == null) return;
    final centerX = _decoded!.width / 2.0;
    setState(() => _gutter = GutterLine(centerX, centerX));
  }

  void _resetToDetected() {
    if (_detectedGutter == null) return;
    setState(() => _gutter = _detectedGutter);
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

  Offset _imageToScreen(double x, double y) =>
      Offset(x * _scale, y * _scale) + _origin;

  double _screenXToImageX(double screenX) => (screenX - _origin.dx) / _scale;

  int? _hitTestHandle(Offset screenPos) {
    if (_gutter == null || _decoded == null) return null;
    const hitRadius = 30.0;
    final topPoint = _imageToScreen(_gutter!.topX, 0);
    final bottomPoint = _imageToScreen(_gutter!.bottomX, _decoded!.height.toDouble());
    if ((topPoint - screenPos).distance <= hitRadius) return 0;
    if ((bottomPoint - screenPos).distance <= hitRadius) return 1;
    return null;
  }

  Future<void> _confirm() async {
    if (_gutter == null || _decoded == null || _saving) return;
    setState(() => _saving = true);
    try {
      final split = BookProcessor.splitAndWarp(
        spread: widget.spread,
        gutter: _gutter!,
        colorMode: widget.colorMode,
      );

      final storage = ref.read(storageProvider);
      var doc = ref.read(activeDocumentProvider);
      doc ??= await storage.createDocument();
      ref.read(activeDocumentProvider.notifier).state = doc;
      final docDir = await storage.documentDir(doc.id);

      final leftId = storage.newId();
      final leftPath = '${docDir.path}/$leftId.jpg';
      await File(leftPath).writeAsBytes(split.left.jpegBytes);
      await storage.addPage(
        doc,
        imagePath: leftPath,
        sourceMode: model.PageSourceMode.bookLeft,
        colorMode: widget.colorMode,
      );

      final rightId = storage.newId();
      final rightPath = '${docDir.path}/$rightId.jpg';
      await File(rightPath).writeAsBytes(split.right.jpegBytes);
      await storage.addPage(
        doc,
        imagePath: rightPath,
        sourceMode: model.PageSourceMode.bookRight,
        colorMode: widget.colorMode,
      );

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
        title: const Text('Adjust the gutter (spine)'),
      ),
      body: _detecting || _decoded == null || _gutter == null
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : LayoutBuilder(
              builder: (context, constraints) {
                _updateTransform(
                    Size(constraints.maxWidth, constraints.maxHeight));
                final imgH = _decoded!.height.toDouble();
                final imgW = _decoded!.width.toDouble();
                return GestureDetector(
                  onPanStart: (d) {
                    _draggingHandle = _hitTestHandle(d.localPosition) ?? -1;
                  },
                  onPanUpdate: (d) {
                    if (_draggingHandle == -1) return;
                    final x = _screenXToImageX(d.localPosition.dx)
                        .clamp(0.0, imgW);
                    setState(() {
                      _gutter = _draggingHandle == 0
                          ? GutterLine(x, _gutter!.bottomX)
                          : GutterLine(_gutter!.topX, x);
                    });
                  },
                  onPanEnd: (_) => _draggingHandle = -1,
                  child: CustomPaint(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: _GutterPainter(
                      image: _decoded!,
                      topPoint: _imageToScreen(_gutter!.topX, 0),
                      bottomPoint: _imageToScreen(_gutter!.bottomX, imgH),
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
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Drag either end of the line so it follows the spine.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: _resetToCenter,
                    child: const Text('Reset to center'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _resetToDetected,
                    child: const Text('Reset to detected'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
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
  final Offset topPoint;
  final Offset bottomPoint;

  _GutterPainter({
    required this.image,
    required this.topPoint,
    required this.bottomPoint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(
        0, 0, image.width.toDouble(), image.height.toDouble());
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

    final linePaint = Paint()
      ..color = const Color(0xFFFF6B6B)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    canvas.drawLine(topPoint, bottomPoint, linePaint);

    final handlePaint = Paint()..color = Colors.white;
    final handleBorder = Paint()
      ..color = const Color(0xFFFF6B6B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (final p in [topPoint, bottomPoint]) {
      canvas.drawCircle(p, 12, handlePaint);
      canvas.drawCircle(p, 12, handleBorder);
    }
  }

  @override
  bool shouldRepaint(covariant _GutterPainter oldDelegate) => true;
}
