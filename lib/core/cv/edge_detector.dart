// Document-boundary detection.
//
// Pipeline (see design doc §3):
//   downscale -> grayscale -> gaussian blur -> canny -> dilate ->
//   findContours -> approxPolyDP -> largest 4-point convex quad
//
// NOTE: opencv_dart's exact API surface shifts a bit between versions.
// The calls below match opencv_dart ^1.3.x. If `flutter pub get` resolves
// a different minor version and something doesn't compile, check the
// package's example app under its pub cache for the current method names —
// the *algorithm* here won't need to change, just call-site syntax.

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

class EdgeDetector {
  /// Width we downscale to before running Canny — full res is only used
  /// once we actually warp.
  static const int detectionWidth = 500;

  /// Minimum contour area, as a fraction of frame area, to be considered
  /// a candidate document boundary.
  static const double minAreaFraction = 0.20;

  /// Runs detection on a full-resolution image (bytes) and returns the
  /// best 4-point quad, scaled back to full-resolution coordinates, or
  /// null if nothing confident was found. [minAreaFraction] can be
  /// lowered for Book Mode, where a book on a desk may reasonably occupy
  /// less of the frame than a single document held/placed close-up.
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
    cv.Mat edges = cv.Mat.empty();
    cv.Mat dilated = cv.Mat.empty();

    try {
      gray = cv.cvtColor(small, cv.COLOR_BGR2GRAY);
      blurred = cv.gaussianBlur(gray, (5, 5), 0);
      edges = cv.canny(blurred, 50, 150);
      final kernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
      dilated = cv.dilate(edges, kernel);

      final contours = cv.findContours(
        dilated,
        cv.RETR_LIST,
        cv.CHAIN_APPROX_SIMPLE,
      );

      final frameArea = small.cols * small.rows;
      List<Point<double>>? bestQuad;
      double bestArea = 0;

      // contours.$1 is the VecVecPoint of contours in opencv_dart's
      // (contours, hierarchy) tuple return; .toList() gives List<VecPoint>,
      // i.e. each contour is already a VecPoint — no re-wrapping needed
      // (dartcv4 1.1.8: VecPoint.fromList() builds FROM a List<Point>, it
      // doesn't accept an existing VecPoint).
      final contourList = contours.$1.toList()
        ..sort((a, b) => cv.contourArea(b).compareTo(cv.contourArea(a)));

      for (final c in contourList.take(5)) {
        final pts = c;
        final area = cv.contourArea(pts);
        if (area < frameArea * minAreaFraction) continue;

        final peri = cv.arcLength(pts, true);
        final approx = cv.approxPolyDP(pts, 0.02 * peri, true);
        final approxPts = approx.toList();

        if (approxPts.length == 4 && area > bestArea) {
          bestArea = area;
          bestQuad = approxPts
              .map((p) => Point<double>(p.x / scale, p.y / scale))
              .toList();
        }
      }

      if (bestQuad == null) return null;
      return DetectedQuad(_orderCorners(bestQuad), bestArea / frameArea);
    } finally {
      small.dispose();
      gray.dispose();
      blurred.dispose();
      edges.dispose();
      dilated.dispose();
    }
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
