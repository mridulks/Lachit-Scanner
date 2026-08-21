import 'dart:math';
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'book_geometry.dart';

class GutterDetection {
  final GutterPath path;
  final double confidence;

  const GutterDetection(this.path, this.confidence);

  /// A conservative gate: callers should always offer manual adjustment.
  bool get isReliable => confidence >= 0.45;
}

/// Offline, image-only initial gutter detector for an already rectified spread.
///
/// It builds a central-band evidence image from shadow and horizontal-gradient
/// cues, then finds a smooth minimum-cost top-to-bottom path with dynamic
/// programming. It is deliberately an initial estimate, not a page dewarper.
class GutterDetector {
  static const int _maxAnalysisWidth = 480;
  static const int _controlPointCount = 3;

  static GutterDetection? detect(Uint8List imageBytes) {
    final source = cv.imdecode(imageBytes, cv.IMREAD_COLOR);
    cv.Mat gray = cv.Mat.empty();
    cv.Mat blurred = cv.Mat.empty();
    cv.Mat small = cv.Mat.empty();
    try {
      if (source.isEmpty) return null;
      gray = cv.cvtColor(source, cv.COLOR_BGR2GRAY);
      blurred = cv.gaussianBlur(gray, (5, 5), 0);
      final scale = min(1.0, _maxAnalysisWidth / blurred.cols);
      final width = max(32, (blurred.cols * scale).round());
      final height = max(32, (blurred.rows * scale).round());
      small = cv.resize(blurred, (width, height));

      final path = _findPath(small);
      if (path == null) return null;
      final points = List.generate(_controlPointCount, (index) {
        final y = (height - 1) * index / (_controlPointCount - 1);
        final x = _interpolate(path.xByRow, y);
        return Point<double>(x / scale, y / scale);
      });
      return GutterDetection(GutterPath(points), path.confidence);
    } finally {
      source.dispose();
      gray.dispose();
      blurred.dispose();
      small.dispose();
    }
  }

  static _PathResult? _findPath(cv.Mat gray) {
    final width = gray.cols;
    final height = gray.rows;
    final left = (width * 0.25).round();
    final right = (width * 0.75).round();
    final bandWidth = right - left + 1;
    if (bandWidth < 12 || height < 12) return null;
    final pixels = gray.data;
    final costs = List.generate(
      height,
      (_) => List<double>.filled(bandWidth, 0),
    );
    var evidenceSum = 0.0;
    for (var y = 0; y < height; y++) {
      for (var i = 0; i < bandWidth; i++) {
        final x = left + i;
        final value = pixels[y * width + x].toDouble();
        final previous = pixels[y * width + max(0, x - 1)].toDouble();
        final next = pixels[y * width + min(width - 1, x + 1)].toDouble();
        final darkness = (255 - value) / 255;
        final edge = (next - previous).abs() / 255;
        final centreDistance = (x - width / 2).abs() / (width / 2);
        final evidence = darkness * 0.60 + edge * 0.40;
        evidenceSum += evidence;
        // Lower cost is preferable. Centrality is weak: a real gutter may
        // be off-centre, but desk/background artefacts should not win easily.
        costs[y][i] = 1 - evidence + centreDistance * 0.12;
      }
    }

    final parent = List.generate(
      height,
      (_) => List<int>.filled(bandWidth, -1),
    );
    var previous = [...costs.first];
    const maxStep = 4;
    const smoothness = 0.045;
    for (var y = 1; y < height; y++) {
      final current = List<double>.filled(bandWidth, double.infinity);
      for (var i = 0; i < bandWidth; i++) {
        final from = max(0, i - maxStep);
        final to = min(bandWidth - 1, i + maxStep);
        for (var prior = from; prior <= to; prior++) {
          final candidate = previous[prior] + smoothness * (i - prior).abs();
          if (candidate < current[i]) {
            current[i] = candidate;
            parent[y][i] = prior;
          }
        }
        current[i] += costs[y][i];
      }
      previous = current;
    }

    var end = 0;
    for (var i = 1; i < bandWidth; i++) {
      if (previous[i] < previous[end]) end = i;
    }
    final xByRow = List<double>.filled(height, 0);
    for (var y = height - 1; y >= 0; y--) {
      xByRow[y] = (left + end).toDouble();
      if (y > 0) end = parent[y][end];
    }
    final meanEvidence = evidenceSum / (height * bandWidth);
    final pathCost = previous.reduce(min) / height;
    final confidence = ((meanEvidence + (1 - pathCost)) / 2).clamp(0.0, 1.0);
    return _PathResult(xByRow, confidence);
  }

  static double _interpolate(List<double> samples, double y) {
    final low = y.floor().clamp(0, samples.length - 1);
    final high = y.ceil().clamp(0, samples.length - 1);
    if (low == high) return samples[low];
    final t = y - low;
    return samples[low] + (samples[high] - samples[low]) * t;
  }
}

class _PathResult {
  final List<double> xByRow;
  final double confidence;
  const _PathResult(this.xByRow, this.confidence);
}
