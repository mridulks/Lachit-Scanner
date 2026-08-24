import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../models/page.dart';

class CropScreen extends StatefulWidget {
  final ScanPage page;

  const CropScreen({super.key, required this.page});

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  Uint8List? _bytes;
  img.Image? _decoded;
  Rect? _cropRect;
  bool _saving = false;
  Offset? _dragStart;
  Rect? _startRect;
  _CropHandle? _activeHandle;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await File(widget.page.imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (mounted) {
      setState(() {
        _bytes = bytes;
        _decoded = decoded;
        _cropRect = const Rect.fromLTWH(0.05, 0.05, 0.9, 0.9);
      });
    }
  }

  void _startDrag(Offset point, Size size) {
    _dragStart = point;
    _startRect = _cropRect;
    _activeHandle = _hitTestHandle(point, size);
  }

  void _updateDrag(Offset point, Size size) {
    final start = _dragStart;
    final original = _startRect;
    if (start == null || original == null) return;
    final dx = (point.dx - start.dx) / size.width;
    final dy = (point.dy - start.dy) / size.height;
    final handle = _activeHandle;
    if (handle != null) {
      const minSize = 0.08;
      var left = original.left;
      var top = original.top;
      var right = original.right;
      var bottom = original.bottom;
      switch (handle) {
        case _CropHandle.topLeft:
          left = (original.left + dx).clamp(0.0, right - minSize);
          top = (original.top + dy).clamp(0.0, bottom - minSize);
        case _CropHandle.topRight:
          right = (original.right + dx).clamp(left + minSize, 1.0);
          top = (original.top + dy).clamp(0.0, bottom - minSize);
        case _CropHandle.bottomRight:
          right = (original.right + dx).clamp(left + minSize, 1.0);
          bottom = (original.bottom + dy).clamp(top + minSize, 1.0);
        case _CropHandle.bottomLeft:
          left = (original.left + dx).clamp(0.0, right - minSize);
          bottom = (original.bottom + dy).clamp(top + minSize, 1.0);
      }
      setState(() => _cropRect = Rect.fromLTRB(left, top, right, bottom));
      return;
    }
    final left = (original.left + dx).clamp(0.0, 1.0 - original.width);
    final top = (original.top + dy).clamp(0.0, 1.0 - original.height);
    setState(() => _cropRect = Rect.fromLTWH(
          left,
          top,
          original.width,
          original.height,
        ));
  }

    _CropHandle? _hitTestHandle(Offset point, Size size) {
      final crop = _cropRect;
      if (crop == null) return null;
      final corners = {
        _CropHandle.topLeft: Offset(crop.left * size.width, crop.top * size.height),
        _CropHandle.topRight:
            Offset(crop.right * size.width, crop.top * size.height),
        _CropHandle.bottomRight:
            Offset(crop.right * size.width, crop.bottom * size.height),
        _CropHandle.bottomLeft:
            Offset(crop.left * size.width, crop.bottom * size.height),
      };
      for (final entry in corners.entries) {
        if ((entry.value - point).distance <= 32) return entry.key;
      }
      return null;
    }

  Future<void> _save() async {
    final decoded = _decoded;
    final crop = _cropRect;
    if (decoded == null || crop == null || _saving) return;
    setState(() => _saving = true);
    try {
      final cropped = img.copyCrop(
        decoded,
        x: (crop.left * decoded.width).round(),
        y: (crop.top * decoded.height).round(),
        width: (crop.width * decoded.width).round(),
        height: (crop.height * decoded.height).round(),
      );
      final oldFile = File(widget.page.imagePath);
      final outputPath =
          '${oldFile.parent.path}/cropped_${DateTime.now().microsecondsSinceEpoch}.jpg';
      await File(outputPath).writeAsBytes(img.encodeJpg(cropped, quality: 95));
      widget.page.imagePath = outputPath;
      widget.page.rotation = 0;
      await widget.page.save();
      if (await oldFile.exists() && oldFile.path != outputPath) {
        await oldFile.delete();
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Crop failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final crop = _cropRect;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crop page'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: bytes == null || crop == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: AspectRatio(
                aspectRatio: (_decoded?.width ?? 1) / (_decoded?.height ?? 1),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = constraints.biggest;
                    return GestureDetector(
                      onPanStart: (details) =>
                          _startDrag(details.localPosition, size),
                      onPanUpdate: (details) =>
                          _updateDrag(details.localPosition, size),
                      onPanEnd: (_) {
                        _dragStart = null;
                        _startRect = null;
                        _activeHandle = null;
                      },
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(bytes, fit: BoxFit.fill),
                          CustomPaint(painter: _CropPainter(crop)),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
      bottomNavigationBar: const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Drag inside to move. Drag a corner handle to resize.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  final Rect crop;

  const _CropPainter(this.crop);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      crop.left * size.width,
      crop.top * size.height,
      crop.width * size.width,
      crop.height * size.height,
    );
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.45);
    canvas.drawRect(
      Rect.fromLTRB(0, 0, size.width, rect.top),
      shade,
    );
    canvas.drawRect(
      Rect.fromLTRB(0, rect.bottom, size.width, size.height),
      shade,
    );
    canvas.drawRect(
      Rect.fromLTRB(0, rect.top, rect.left, rect.bottom),
      shade,
    );
    canvas.drawRect(
      Rect.fromLTRB(rect.right, rect.top, size.width, rect.bottom),
      shade,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    final handlePaint = Paint()..color = Colors.white;
    final handleBorder = Paint()
      ..color = Colors.black87
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final point in [
      rect.topLeft,
      rect.topRight,
      rect.bottomRight,
      rect.bottomLeft,
    ]) {
      canvas.drawCircle(point, 12, handlePaint);
      canvas.drawCircle(point, 12, handleBorder);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) =>
      oldDelegate.crop != crop;
}

enum _CropHandle { topLeft, topRight, bottomRight, bottomLeft }
