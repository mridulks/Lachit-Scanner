import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../core/cv/warp.dart';
import '../../models/page.dart';

class ImageEnhancementScreen extends StatefulWidget {
  final ScanPage page;

  const ImageEnhancementScreen({super.key, required this.page});

  @override
  State<ImageEnhancementScreen> createState() => _ImageEnhancementScreenState();
}

class _ImageEnhancementScreenState extends State<ImageEnhancementScreen> {
  Uint8List? _bytes;
  ColorMode _colorMode = ColorMode.grayscale;
  double _brightness = 0;
  double _contrast = 1;
  double _shadowRemoval = 0;
  double _sharpness = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await File(widget.page.imagePath).readAsBytes();
    if (mounted) setState(() => _bytes = bytes);
  }

  void _preset(String name) {
    setState(() {
      switch (name) {
        case 'Original':
          _colorMode = ColorMode.color;
          _brightness = 0;
          _contrast = 1;
          _shadowRemoval = 0;
          _sharpness = 0;
        case 'Clean':
          _colorMode = ColorMode.grayscale;
          _brightness = 4;
          _contrast = 1.08;
          _shadowRemoval = 0.35;
          _sharpness = 0.2;
        // case 'Text':
        //   _colorMode = ColorMode.bw;
        //   _brightness = 0;
        //   _contrast = 1.12;
        //   _shadowRemoval = 0;
        //   _sharpness = 0.25;
        case 'Text':
          _colorMode = ColorMode.bw;
          _brightness = 35;
          _contrast = 1.3;
          _shadowRemoval = 0;
          _sharpness = 0.5;
      }
    });
  }

  Future<void> _save() async {
    final bytes = _bytes;
    if (bytes == null || _saving) return;
    setState(() => _saving = true);
    cv.Mat? source;
    cv.Mat? adjusted;
    try {
      source = cv.imdecode(bytes, cv.IMREAD_COLOR);
      adjusted = ImageWarper.adjustPage(
        source,
        colorMode: _colorMode,
        brightness: _brightness,
        contrast: _contrast,
        shadowRemoval: _shadowRemoval,
        sharpness: _sharpness,
      );
      final result = ImageWarper.encodeJpeg(adjusted);
      await File(widget.page.imagePath).writeAsBytes(result.jpegBytes);
      widget.page.colorMode = _colorMode;
      await widget.page.save();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Enhancement failed: $e')),
        );
      }
    } finally {
      source?.dispose();
      adjusted?.dispose();
      if (mounted) setState(() => _saving = false);
    }
  }

  ColorFilter _previewFilter() {
    final value = (_contrast - 1) * 128;
    final brightness = _brightness;
    return ColorFilter.matrix([
      _contrast,
      0,
      0,
      0,
      value + brightness,
      0,
      _contrast,
      0,
      0,
      value + brightness,
      0,
      0,
      _contrast,
      0,
      value + brightness,
      0,
      0,
      0,
      1,
      0,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Enhance page'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: bytes == null
          ? const Center(child: CircularProgressIndicator())
          : Scrollbar(
              thumbVisibility: true,
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  16,
                  16,
                  32 + MediaQuery.viewPaddingOf(context).bottom,
                ),
                children: [
                  AspectRatio(
                    aspectRatio: 0.72,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: ColorFiltered(
                          colorFilter: _previewFilter(),
                          child: Image.memory(bytes, fit: BoxFit.contain),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text('Presets',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final preset in ['Original', 'Clean', 'Text'])
                        OutlinedButton(
                          onPressed: () => _preset(preset),
                          child: Text(preset),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SegmentedButton<ColorMode>(
                    style: ButtonStyle(
                      side: WidgetStateProperty.resolveWith((states) {
                        return BorderSide(
                          color: Theme.of(context).colorScheme.outline,
                        );
                      }),
                      foregroundColor:
                          WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) {
                          return Theme.of(context)
                              .colorScheme
                              .onSecondaryContainer;
                        }
                        return Theme.of(context).colorScheme.onSurface;
                      }),
                      iconColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) {
                          return Theme.of(context)
                              .colorScheme
                              .onSecondaryContainer;
                        }
                        return Theme.of(context).colorScheme.onSurface;
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
                          value: ColorMode.color, label: Text('Color')),
                      ButtonSegment(
                        value: ColorMode.grayscale,
                        label: Text('Grayscale'),
                      ),
                      ButtonSegment(value: ColorMode.bw, label: Text('B&W')),
                    ],
                    selected: {_colorMode},
                    onSelectionChanged: (value) =>
                        setState(() => _colorMode = value.first),
                  ),
                  const SizedBox(height: 14),
                  _slider(
                    'Brightness',
                    _brightness,
                    -40,
                    40,
                    (value) => setState(() => _brightness = value),
                  ),
                  _slider(
                    'Contrast',
                    _contrast,
                    0.7,
                    1.5,
                    (value) => setState(() => _contrast = value),
                  ),
                  _slider(
                    'Shadow removal',
                    _shadowRemoval,
                    0,
                    1,
                    (value) => setState(() => _shadowRemoval = value),
                  ),
                  _slider(
                    'Sharpness',
                    _sharpness,
                    0,
                    1,
                    (value) => setState(() => _sharpness = value),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(value.toStringAsFixed(2)),
          ],
        ),
        Slider(value: value, min: min, max: max, onChanged: onChanged),
      ],
    );
  }
}
