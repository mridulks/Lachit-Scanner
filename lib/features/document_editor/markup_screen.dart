import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../models/page.dart';

enum _MarkupTool {
  pen,
  highlighter,
  redaction,
  text,
  signature,
  stamp,
  shape,
  eraser,
}

enum _ShapeKind { rectangle, oval, line, arrow }

const _penColors = [
  Colors.red,
  Colors.blue,
  Colors.green,
  Colors.black,
  Colors.orange,
  Colors.purple,
];

String _colorName(Color color) {
  if (color == Colors.red) return 'Red';
  if (color == Colors.blue) return 'Blue';
  if (color == Colors.green) return 'Green';
  if (color == Colors.black) return 'Black';
  if (color == Colors.orange) return 'Orange';
  return 'Purple';
}

class MarkupScreen extends StatefulWidget {
  final ScanPage page;

  const MarkupScreen({super.key, required this.page});

  @override
  State<MarkupScreen> createState() => _MarkupScreenState();
}

class _MarkupLabel {
  final String text;
  final Offset position;

  const _MarkupLabel(this.text, this.position);
}

class _MarkupSignature {
  final List<Offset> points;
  Offset position;

  _MarkupSignature(this.points, this.position);
}

class _MarkupStamp {
  final String text;
  Offset position;

  _MarkupStamp(this.text, this.position);
}

class _MarkupStroke {
  final List<Offset> points;
  final Color color;
  final double width;
  final bool translucent;

  const _MarkupStroke({
    required this.points,
    required this.color,
    required this.width,
    required this.translucent,
  });
}

class _MarkupShape {
  final _ShapeKind kind;
  final Offset start;
  final Offset end;
  final bool filled;

  const _MarkupShape(this.kind, this.start, this.end, this.filled);
}

class _MarkupScreenState extends State<MarkupScreen> {
  static final List<List<Offset>> _savedSignatures = [];
  final GlobalKey _canvasKey = GlobalKey();
  final List<_MarkupStroke> _strokes = [];
  final List<Rect> _redactions = [];
  final List<_MarkupLabel> _labels = [];
  final List<_MarkupSignature> _signatures = [];
  final List<_MarkupStamp> _stamps = [];
  final List<_MarkupShape> _shapes = [];
  Uint8List? _bytes;
  _MarkupTool _tool = _MarkupTool.pen;
  Color _penColor = Colors.red;
  List<Offset> _activeStroke = [];
  Offset? _dragStart;
  Rect? _activeRedaction;
  Offset? _activeShapeStart;
  Offset? _activeShapeEnd;
  _ShapeKind _shapeKind = _ShapeKind.rectangle;
  bool _shapeFilled = false;
  bool _saving = false;
  int _draggingSignature = -1;
  int _draggingStamp = -1;
  Offset? _lastAnnotationPoint;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await File(widget.page.imagePath).readAsBytes();
    if (mounted) setState(() => _bytes = bytes);
  }

  void _startGesture(Offset point) {
    if (_tool == _MarkupTool.eraser) {
      _eraseAt(point);
      return;
    }
    if (_tool == _MarkupTool.shape) {
      _activeShapeStart = point;
      _activeShapeEnd = point;
      return;
    }
    _draggingSignature = _signatureAt(point);
    _draggingStamp = _draggingSignature == -1 ? _stampAt(point) : -1;
    if (_draggingSignature >= 0 || _draggingStamp >= 0) {
      _lastAnnotationPoint = point;
      return;
    }
    if (_tool == _MarkupTool.text) {
      _addText(point);
    } else if (_tool == _MarkupTool.signature) {
      _addSignature(point);
    } else if (_tool == _MarkupTool.stamp) {
      _addStamp(point);
    } else if (_tool == _MarkupTool.redaction) {
      _dragStart = point;
      setState(() => _activeRedaction = Rect.fromPoints(point, point));
    } else {
      setState(() => _activeStroke = [point]);
    }
  }

  void _updateGesture(Offset point) {
    if (_tool == _MarkupTool.eraser) {
      _eraseAt(point);
      return;
    }
    if (_tool == _MarkupTool.shape && _activeShapeStart != null) {
      setState(() => _activeShapeEnd = point);
      return;
    }
    if (_lastAnnotationPoint != null) {
      final delta = point - _lastAnnotationPoint!;
      setState(() {
        if (_draggingSignature >= 0) {
          _signatures[_draggingSignature].position += delta;
        } else if (_draggingStamp >= 0) {
          _stamps[_draggingStamp].position += delta;
        }
      });
      _lastAnnotationPoint = point;
      return;
    }
    if (_tool == _MarkupTool.redaction && _dragStart != null) {
      setState(() => _activeRedaction = Rect.fromPoints(_dragStart!, point));
    } else if (_tool != _MarkupTool.text &&
        _tool != _MarkupTool.signature &&
        _tool != _MarkupTool.stamp &&
        _tool != _MarkupTool.eraser) {
      setState(() => _activeStroke = [..._activeStroke, point]);
    }
  }

  void _eraseAt(Offset point) {
    for (var index = _signatures.length - 1; index >= 0; index--) {
      final bounds =
          _bounds(_signatures[index].points).shift(_signatures[index].position);
      if (bounds.inflate(16).contains(point)) {
        setState(() => _signatures.removeAt(index));
        return;
      }
    }
    for (var index = _stamps.length - 1; index >= 0; index--) {
      if ((_stamps[index].position & const Size(220, 42))
          .inflate(12)
          .contains(point)) {
        setState(() => _stamps.removeAt(index));
        return;
      }
    }
    for (var index = _labels.length - 1; index >= 0; index--) {
      if ((_labels[index].position & const Size(220, 54))
          .inflate(12)
          .contains(point)) {
        setState(() => _labels.removeAt(index));
        return;
      }
    }
    for (var index = _redactions.length - 1; index >= 0; index--) {
      if (_redactions[index].inflate(12).contains(point)) {
        setState(() => _redactions.removeAt(index));
        return;
      }
    }
    for (var index = _strokes.length - 1; index >= 0; index--) {
      if (_strokes[index].points.any(
            (strokePoint) =>
                (strokePoint - point).distance <= _strokes[index].width + 14,
          )) {
        setState(() => _strokes.removeAt(index));
        return;
      }
    }
  }

  void _endGesture() {
    if (_tool == _MarkupTool.shape) {
      final start = _activeShapeStart;
      final end = _activeShapeEnd;
      if (start != null && end != null && (end - start).distance > 6) {
        setState(() {
          _shapes.add(_MarkupShape(_shapeKind, start, end, _shapeFilled));
          _activeShapeStart = null;
          _activeShapeEnd = null;
        });
      } else {
        _activeShapeStart = null;
        _activeShapeEnd = null;
      }
      return;
    }
    if (_lastAnnotationPoint != null) {
      _draggingSignature = -1;
      _draggingStamp = -1;
      _lastAnnotationPoint = null;
      return;
    }
    if (_tool == _MarkupTool.redaction) {
      final redaction = _activeRedaction;
      if (redaction != null && redaction.width > 4 && redaction.height > 4) {
        _redactions.add(redaction);
      }
      setState(() {
        _activeRedaction = null;
        _dragStart = null;
      });
    } else if (_tool != _MarkupTool.text &&
        _tool != _MarkupTool.signature &&
        _tool != _MarkupTool.stamp &&
        _tool != _MarkupTool.eraser &&
        _activeStroke.length > 1) {
      final color =
          _tool == _MarkupTool.highlighter ? Colors.yellow : _penColor;
      setState(() {
        _strokes.add(
          _MarkupStroke(
            points: List.of(_activeStroke),
            color: color,
            width: _tool == _MarkupTool.highlighter ? 18 : 4,
            translucent: _tool == _MarkupTool.highlighter,
          ),
        );
        _activeStroke = [];
      });
    }
  }

  Future<void> _addText(Offset position) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add text'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'Type your note'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (text != null && text.isNotEmpty && mounted) {
      setState(() => _labels.add(_MarkupLabel(text, position)));
    }
    controller.dispose();
  }

  Future<void> _addSignature(Offset position) async {
    List<Offset>? points;
    if (_savedSignatures.isNotEmpty) {
      final selected = await showDialog<int>(
        context: context,
        builder: (context) => _SignatureChoiceDialog(
          signatures: _savedSignatures,
        ),
      );
      if (selected == null) return;
      points = selected >= 0
          ? List.of(_savedSignatures[selected])
          : await _captureSignature();
    } else {
      points = await _captureSignature();
    }
    final selectedPoints = points;
    if (selectedPoints != null && selectedPoints.length > 1 && mounted) {
      setState(
        () => _signatures.add(_MarkupSignature(selectedPoints, position)),
      );
    }
  }

  Future<List<Offset>?> _captureSignature() async {
    final points = await showDialog<List<Offset>>(
      context: context,
      builder: (context) => const _SignatureDialog(),
    );
    if (points != null && points.length > 1) {
      _savedSignatures.add(List.of(points));
    }
    return points;
  }

  int _signatureAt(Offset point) {
    for (var index = _signatures.length - 1; index >= 0; index--) {
      final points = _signatures[index].points;
      final bounds = _bounds(points).shift(_signatures[index].position);
      if (bounds.inflate(12).contains(point)) return index;
    }
    return -1;
  }

  int _stampAt(Offset point) {
    for (var index = _stamps.length - 1; index >= 0; index--) {
      if ((_stamps[index].position & const Size(220, 42))
          .inflate(8)
          .contains(point)) {
        return index;
      }
    }
    return -1;
  }

  Rect _bounds(List<Offset> points) {
    var left = points.first.dx;
    var top = points.first.dy;
    var right = left;
    var bottom = top;
    for (final point in points.skip(1)) {
      left = left < point.dx ? left : point.dx;
      top = top < point.dy ? top : point.dy;
      right = right > point.dx ? right : point.dx;
      bottom = bottom > point.dy ? bottom : point.dy;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Future<void> _addStamp(Offset position) async {
    final stamp = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            for (final value in [
              'APPROVED',
              'CONFIDENTIAL',
              'RECEIVED'
              'DATE ${_dateStamp()}',
            ])
              ListTile(
                leading: const Icon(Icons.verified_outlined),
                title: Text(value),
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    );
    if (stamp != null && mounted) {
      setState(() => _stamps.add(_MarkupStamp(stamp, position)));
    }
  }

  Future<void> _chooseShape() async {
    final selection = await showModalBottomSheet<(_ShapeKind, bool)>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            for (final kind in _ShapeKind.values)
              ListTile(
                leading: Icon(_shapeIcon(kind)),
                title: Text(_shapeName(kind)),
                trailing: Switch(
                  value: _shapeFilled,
                  onChanged: (value) {
                    Navigator.pop(context, (kind, value));
                  },
                ),
                onTap: () => Navigator.pop(context, (kind, _shapeFilled)),
              ),
          ],
        ),
      ),
    );
    if (selection != null && mounted) {
      setState(() {
        _shapeKind = selection.$1;
        _shapeFilled = selection.$2;
      });
    }
  }

  IconData _shapeIcon(_ShapeKind kind) => switch (kind) {
        _ShapeKind.rectangle => Icons.rectangle_outlined,
        _ShapeKind.oval => Icons.circle_outlined,
        _ShapeKind.line => Icons.remove,
        _ShapeKind.arrow => Icons.arrow_forward,
      };

  String _shapeName(_ShapeKind kind) => switch (kind) {
        _ShapeKind.rectangle => 'Rectangle',
        _ShapeKind.oval => 'Oval / circle',
        _ShapeKind.line => 'Line',
        _ShapeKind.arrow => 'Arrow',
      };

  String _dateStamp() {
    final date = DateTime.now();
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  void _undo() {
    setState(() {
      if (_labels.isNotEmpty && _tool == _MarkupTool.text) {
        _labels.removeLast();
      } else if (_signatures.isNotEmpty && _tool == _MarkupTool.signature) {
        _signatures.removeLast();
      } else if (_stamps.isNotEmpty && _tool == _MarkupTool.stamp) {
        _stamps.removeLast();
      } else if (_shapes.isNotEmpty && _tool == _MarkupTool.shape) {
        _shapes.removeLast();
      } else if (_redactions.isNotEmpty && _tool == _MarkupTool.redaction) {
        _redactions.removeLast();
      } else if (_strokes.isNotEmpty) {
        _strokes.removeLast();
      }
    });
  }

  Future<void> _save() async {
    if (_bytes == null || _saving) return;
    setState(() => _saving = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      final canvasBox =
          _canvasKey.currentContext?.findRenderObject() as RenderBox?;
      final canvasSize = canvasBox?.size;
      if (canvasSize == null || canvasSize.isEmpty) {
        throw StateError('Markup canvas is not ready.');
      }
      final codec = await ui.instantiateImageCodec(_bytes!);
      final frame = await codec.getNextFrame();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final scaleX = frame.image.width / canvasSize.width;
      final scaleY = frame.image.height / canvasSize.height;
      canvas.drawImage(frame.image, Offset.zero, Paint());
      canvas.scale(scaleX, scaleY);
      _MarkupPainter(
        strokes: _strokes,
        activeStroke: _activeStroke,
        activeStrokeColor: _penColor,
        redactions: _redactions,
        labels: _labels,
        signatures: _signatures,
        stamps: _stamps,
        shapes: _shapes,
        activeShape: _activeShapeStart == null || _activeShapeEnd == null
            ? null
            : _MarkupShape(
                _shapeKind,
                _activeShapeStart!,
                _activeShapeEnd!,
                _shapeFilled,
              ),
      ).paint(canvas, canvasSize);
      final picture = recorder.endRecording();
      final image =
          await picture.toImage(frame.image.width, frame.image.height);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('Could not render markup.');
      final rendered = img.decodeImage(data.buffer.asUint8List());
      if (rendered == null) throw StateError('Could not encode markup.');
      final oldFile = File(widget.page.imagePath);
      final outputPath =
          '${oldFile.parent.path}/marked_${DateTime.now().microsecondsSinceEpoch}.jpg';
      await File(outputPath).writeAsBytes(img.encodeJpg(rendered, quality: 95));
      widget.page.imagePath = outputPath;
      await widget.page.save();
      if (await oldFile.exists() && oldFile.path != outputPath) {
        await oldFile.delete();
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Markup save failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final decoded = bytes == null ? null : img.decodeImage(bytes);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Markup'),
        actions: [
          IconButton(
            onPressed: _strokes.isEmpty &&
                    _redactions.isEmpty &&
                    _labels.isEmpty &&
                    _signatures.isEmpty &&
                    _stamps.isEmpty &&
                    _shapes.isEmpty
                ? null
                : _undo,
            icon: const Icon(Icons.undo),
            tooltip: 'Undo',
          ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: bytes == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: RepaintBoundary(
                key: _canvasKey,
                child: AspectRatio(
                  aspectRatio:
                      decoded == null ? 0.72 : decoded.width / decoded.height,
                  child: GestureDetector(
                    onPanStart: (details) =>
                        _startGesture(details.localPosition),
                    onPanUpdate: (details) =>
                        _updateGesture(details.localPosition),
                    onPanEnd: (_) => _endGesture(),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(bytes, fit: BoxFit.contain),
                        CustomPaint(
                          painter: _MarkupPainter(
                            strokes: _strokes,
                            activeStroke: _activeStroke,
                            activeStrokeColor: _penColor,
                            redactions: [
                              ..._redactions,
                              if (_activeRedaction != null) _activeRedaction!,
                            ],
                            labels: _labels,
                            signatures: _signatures,
                            stamps: _stamps,
                            shapes: _shapes,
                            activeShape: _activeShapeStart == null ||
                                    _activeShapeEnd == null
                                ? null
                                : _MarkupShape(
                                    _shapeKind,
                                    _activeShapeStart!,
                                    _activeShapeEnd!,
                                    _shapeFilled,
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 2,
            runSpacing: 2,
            children: [
              for (final entry in [
                (_MarkupTool.pen, Icons.edit, 'Pen'),
                (_MarkupTool.highlighter, Icons.highlight, 'Highlight'),
                (_MarkupTool.redaction, Icons.block, 'Redact'),
                (_MarkupTool.text, Icons.text_fields, 'Text'),
                (_MarkupTool.signature, Icons.draw, 'Signature'),
                (_MarkupTool.stamp, Icons.verified_outlined, 'Stamp'),
                (_MarkupTool.shape, Icons.category_outlined, 'Shape'),
                (_MarkupTool.eraser, Icons.auto_fix_high, 'Eraser'),
              ])
                IconButton(
                  onPressed: () async {
                    setState(() => _tool = entry.$1);
                    if (entry.$1 == _MarkupTool.shape) await _chooseShape();
                  },
                  tooltip: entry.$3,
                  icon: Icon(
                    entry.$2,
                    color: _tool == entry.$1
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                ),
              PopupMenuButton<Color>(
                tooltip: 'Pen color',
                enabled: _tool == _MarkupTool.pen,
                onSelected: (color) => setState(() => _penColor = color),
                icon: Icon(Icons.palette, color: _penColor),
                itemBuilder: (context) => [
                  for (final color in _penColors)
                    PopupMenuItem<Color>(
                      value: color,
                      child: Row(
                        children: [
                          Icon(Icons.circle, color: color),
                          const SizedBox(width: 12),
                          Text(_colorName(color)),
                          const Spacer(),
                          if (_penColor == color) const Icon(Icons.check),
                        ],
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

class _MarkupPainter extends CustomPainter {
  final List<_MarkupStroke> strokes;
  final List<Offset> activeStroke;
  final Color activeStrokeColor;
  final List<Rect> redactions;
  final List<_MarkupLabel> labels;
  final List<_MarkupSignature> signatures;
  final List<_MarkupStamp> stamps;
  final List<_MarkupShape> shapes;
  final _MarkupShape? activeShape;

  const _MarkupPainter({
    required this.strokes,
    required this.activeStroke,
    required this.activeStrokeColor,
    required this.redactions,
    required this.labels,
    required this.signatures,
    required this.stamps,
    required this.shapes,
    this.activeShape,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      _drawStroke(canvas, stroke.points, stroke);
    }
    for (final shape in [...shapes, if (activeShape != null) activeShape!]) {
      _drawShape(canvas, shape);
    }
    if (activeStroke.length > 1) {
      _drawStroke(
        canvas,
        activeStroke,
        _MarkupStroke(
          points: activeStroke,
          color: activeStrokeColor,
          width: 4,
          translucent: false,
        ),
      );
    }
    for (final rect in redactions) {
      canvas.drawRect(rect, Paint()..color = Colors.black);
    }
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(
          text: label.text,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 18,
            backgroundColor: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width * 0.75);
      painter.paint(canvas, label.position);
    }
    for (final signature in signatures) {
      final translated =
          signature.points.map((point) => point + signature.position).toList();
      _drawStroke(
        canvas,
        translated,
        const _MarkupStroke(
          points: [],
          color: Colors.black,
          width: 3,
          translucent: false,
        ),
      );
    }
    for (final stamp in stamps) {
      final painter = TextPainter(
        text: TextSpan(
          text: stamp.text,
          style: const TextStyle(
            color: Colors.red,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final rect =
          stamp.position & Size(painter.width + 16, painter.height + 10);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()
          ..color = Colors.red.withValues(alpha: 0.08)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()
          ..color = Colors.red
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      painter.paint(canvas, stamp.position + const Offset(8, 5));
    }
  }

  void _drawStroke(Canvas canvas, List<Offset> points, _MarkupStroke stroke) {
    final path = Path();
    var hasPoint = false;
    for (final point in points) {
      if (!point.isFinite) {
        hasPoint = false;
      } else if (!hasPoint) {
        path.moveTo(point.dx, point.dy);
        hasPoint = true;
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = stroke.color.withValues(alpha: stroke.translucent ? 0.45 : 1)
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  void _drawShape(Canvas canvas, _MarkupShape shape) {
    final paint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 3
      ..style = shape.filled ? PaintingStyle.fill : PaintingStyle.stroke;
    final rect = Rect.fromPoints(shape.start, shape.end);
    switch (shape.kind) {
      case _ShapeKind.rectangle:
        canvas.drawRect(rect, paint);
      case _ShapeKind.oval:
        canvas.drawOval(rect, paint);
      case _ShapeKind.line:
        paint.style = PaintingStyle.stroke;
        canvas.drawLine(shape.start, shape.end, paint);
      case _ShapeKind.arrow:
        paint.style = PaintingStyle.stroke;
        canvas.drawLine(shape.start, shape.end, paint);
        final direction = shape.start - shape.end;
        final unit = direction / direction.distance;
        final side = Offset(-unit.dy, unit.dx);
        final wing = shape.end + unit * 18;
        canvas.drawLine(shape.end, wing + side * 8, paint);
        canvas.drawLine(shape.end, wing - side * 8, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MarkupPainter oldDelegate) => true;
}

class _SignatureDialog extends StatefulWidget {
  const _SignatureDialog();

  @override
  State<_SignatureDialog> createState() => _SignatureDialogState();
}

class _SignatureChoiceDialog extends StatelessWidget {
  final List<List<Offset>> signatures;

  const _SignatureChoiceDialog({required this.signatures});

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: const Text('Choose signature'),
      children: [
        for (var index = 0; index < signatures.length; index++)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, index),
            child: SizedBox(
              height: 54,
              child: CustomPaint(
                painter: _SignaturePainter(signatures[index]),
              ),
            ),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, -1),
          child: const ListTile(
            leading: Icon(Icons.add),
            title: Text('Create new signature'),
          ),
        ),
      ],
    );
  }
}

class _SignatureDialogState extends State<_SignatureDialog> {
  final List<Offset> _points = [];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Draw signature'),
      content: SizedBox(
        width: 300,
        height: 150,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.black26),
          ),
          child: GestureDetector(
            onPanStart: (details) =>
                setState(() => _points.add(details.localPosition)),
            onPanUpdate: (details) =>
                setState(() => _points.add(details.localPosition)),
            onPanEnd: (_) => setState(() => _points.add(Offset.infinite)),
            child: CustomPaint(
              painter: _SignaturePainter(_points),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(_points.clear),
          child: const Text('Clear'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _points.isEmpty
              ? null
              : () => Navigator.pop(
                    context,
                    _points.where((point) => point != Offset.infinite).toList(),
                  ),
          child: const Text('Use signature'),
        ),
      ],
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<Offset> points;

  const _SignaturePainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (var index = 1; index < points.length; index++) {
      final start = points[index - 1];
      final end = points[index];
      if (start.isFinite && end.isFinite) canvas.drawLine(start, end, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) => true;
}
