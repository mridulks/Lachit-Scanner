// Document-boundary detection.
//
// Pipeline (see design doc §3):
//   downscale -> grayscale -> gaussian blur -> canny -> dilate ->
//   findContours -> approxPolyDP -> score candidates -> best 4-point quad
//
// Scoring change (accuracy fine-tuning pass): originally the largest
// area-qualifying 4-point contour won outright. On a cluttered/patterned
// background, a big non-rectangular blob can out-area the actual book/
// document. Candidates are now scored on BOTH area fraction AND how close
// their corner angles are to 90° ("rectangularity"), so a smaller but
// genuinely rectangular candidate can beat a larger but skewed one. Canny
// is also now tried at two threshold pairs (not just one fixed pair) and
// candidates from both passes are pooled, since a single fixed threshold
// doesn't hold up across different lighting/contrast conditions.
//
// NOTE: opencv_dart's exact API surface shifts a bit between versions —
// every call below is one that's already been confirmed working (see
// warp.dart's history); the new logic here is calling those same proven
// functions twice (once per threshold pair) plus pure-Dart scoring math,
// so this shouldn't reopen prior API-drift issues.

import 'dart:math';
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

class DetectedQuad {
  /// Corners in image-pixel coordinates, ordered
  /// [topLeft, topRight, bottomRight, bottomLeft].
  final List<Point<double>> corners;

  /// Fraction of the (downscaled) frame area the quad covers — useful for
  /// confidence display / gating auto-capture.
  final double areaFraction;

  DetectedQuad(this.corners, this.areaFraction);
}

class _Candidate {
  final List<Point<double>> corners;
  final double areaFraction;
  final double score;
  _Candidate(this.corners, this.areaFraction, this.score);
}

class EdgeDetector {
  /// Width we downscale to before running Canny — full res is only used
  /// once we actually warp.
  static const int detectionWidth = 500;

  /// Minimum contour area, as a fraction of frame area, to be considered
  /// a candidate document boundary.
  static const double minAreaFraction = 0.20;

  /// (low, high) Canny threshold pairs to try. Pooling candidates across
  /// both — rather than committing to one fixed pair — means a photo that
  /// just doesn't suit one threshold still has a chance via the other.
  static const _cannyThresholdPairs = [
    (50, 150),
    (30, 100),
  ];

  /// Runs detection on a full-resolution image (bytes) and returns the
  /// best-SCORING 4-point quad, scaled back to full-resolution
  /// coordinates, or null if nothing qualified at all. [minAreaFraction]
  /// can be lowered for Book Mode, where a book on a desk may reasonably
  /// occupy less of the frame than a single document held/placed close-up.
  static DetectedQuad? detect(Uint8List imageBytes, {double? minAreaFraction}) {
    final full = cv.imdecode(imageBytes, cv.IMREAD_COLOR);
    try {
      return _detectOnMat(full, minAreaFraction ?? EdgeDetector.minAreaFraction);
    } finally {
      full.dispose();
    }
  }

  static DetectedQuad? _detectOnMat(cv.Mat full, double minAreaFraction) {
    final scale = detectionWidth / full.cols;
    final small = cv.resize(
      full,
      (detectionWidth, (full.rows * scale).round()),
    );

    cv.Mat gray = cv.Mat.empty();
    cv.Mat blurred = cv.Mat.empty();
    _Candidate? best;

    try {
      gray = cv.cvtColor(small, cv.COLOR_BGR2GRAY);
      blurred = cv.gaussianBlur(gray, (5, 5), 0);

      final frameArea = small.cols * small.rows;

      for (final pair in _cannyThresholdPairs) {
        cv.Mat edges = cv.Mat.empty();
        cv.Mat dilated = cv.Mat.empty();
        try {
          edges = cv.canny(blurred, pair.$1.toDouble(), pair.$2.toDouble());
          final kernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
          dilated = cv.dilate(edges, kernel);

          final contours = cv.findContours(
            dilated,
            cv.RETR_LIST,
            cv.CHAIN_APPROX_SIMPLE,
          );

          // contours.$1 is the VecVecPoint of contours in opencv_dart's
          // (contours, hierarchy) tuple return; .toList() gives
          // List<VecPoint>, i.e. each contour is already a VecPoint.
          final contourList = contours.$1.toList()
            ..sort((a, b) => cv.contourArea(b).compareTo(cv.contourArea(a)));

          for (final c in contourList.take(8)) {
            final area = cv.contourArea(c);
            if (area < frameArea * minAreaFraction) continue;

            final peri = cv.arcLength(c, true);
            final approx = cv.approxPolyDP(c, 0.02 * peri, true);
            final approxPts = approx.toList();
            if (approxPts.length != 4) continue;

            final quad = approxPts
                .map((p) => Point<double>(p.x / scale, p.y / scale))
                .toList();
            final ordered = _orderCorners(quad);

            final areaScore = area / frameArea;
            final rectScore = _rectangularityScore(ordered);
            // Weighted combined score. Rectangularity carries more
            // weight than raw area — a large-but-skewed background blob
            // should lose to a smaller genuinely-rectangular candidate.
            final combined = areaScore * 0.4 + rectScore * 0.6;

            if (best == null || combined > best!.score) {
              best = _Candidate(ordered, areaScore, combined);
            }
          }
        } finally {
          edges.dispose();
          dilated.dispose();
        }
      }
    } finally {
      small.dispose();
      gray.dispose();
      blurred.dispose();
    }

    if (best == null) return null;
    return DetectedQuad(best!.corners, best!.areaFraction);
  }

  /// 1.0 for a perfect rectangle (all corner angles == 90°), tapering to
  /// 0.0 as the average angle deviation reaches 45°. Cheap, pure-Dart,
  /// no opencv calls — this is what lets a smaller genuine quad beat a
  /// larger but irregular one.
  static double _rectangularityScore(List<Point<double>> quad) {
    var totalDeviation = 0.0;
    for (var i = 0; i < 4; i++) {
      final prev = quad[(i + 3) % 4];
      final curr = quad[i];
      final next = quad[(i + 1) % 4];
      final v1x = prev.x - curr.x, v1y = prev.y - curr.y;
      final v2x = next.x - curr.x, v2y = next.y - curr.y;
      final mag1 = sqrt(v1x * v1x + v1y * v1y);
      final mag2 = sqrt(v2x * v2x + v2y * v2y);
      if (mag1 < 1e-6 || mag2 < 1e-6) {
        totalDeviation += 90;
        continue;
      }
      final cosAngle = ((v1x * v2x + v1y * v2y) / (mag1 * mag2)).clamp(-1.0, 1.0);
      final angleDeg = acos(cosAngle) * 180 / pi;
      totalDeviation += (angleDeg - 90).abs();
    }
    final avgDeviation = totalDeviation / 4;
    return (1 - (avgDeviation / 45)).clamp(0.0, 1.0);
  }

  /// Standard sum/difference trick:
  ///  - top-left has the smallest (x + y)
  ///  - bottom-right has the largest (x + y)
  ///  - top-right has the smallest (y - x)
  ///  - bottom-left has the largest (y - x)
  static List<Point<double>> _orderCorners(List<Point<double>> pts) {
    final sums = pts.map((p) => p.x + p.y).toList();
    final diffs = pts.map((p) => p.y - p.x).toList();

    final tl = pts[sums.indexOf(sums.reduce(min))];
    final br = pts[sums.indexOf(sums.reduce(max))];
    final tr = pts[diffs.indexOf(diffs.reduce(min))];
    final bl = pts[diffs.indexOf(diffs.reduce(max))];

    return [tl, tr, br, bl];
  }

  /// Default "no detection yet" quad — an inset rectangle covering ~85% of
  /// the frame, used to seed the manual-adjust screen when auto-detect
  /// fails (dark book covers, low-contrast pages, etc.).
  static List<Point<double>> fallbackQuad(double width, double height) {
    final mx = width * 0.075;
    final my = height * 0.075;
    return [
      Point(mx, my),
      Point(width - mx, my),
      Point(width - mx, height - my),
      Point(mx, height - my),
    ];
  }

  /// Euclidean corner displacement between two quads of the same order —
  /// used by the live auto-capture stability check (design doc §3).
  static double maxCornerDisplacement(
    List<Point<double>> a,
    List<Point<double>> b,
  ) {
    double maxD = 0;
    for (var i = 0; i < a.length && i < b.length; i++) {
      final d = (a[i] - b[i]).distanceTo(const Point(0, 0));
      if (d > maxD) maxD = d;
    }
    return maxD;
  }
}

extension on Point<double> {
  Point<double> operator -(Point<double> other) =>
      Point(x - other.x, y - other.y);
}
