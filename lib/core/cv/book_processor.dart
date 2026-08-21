// Book Mode processing pipeline (design doc §4, step 3 — split + re-warp).
//
// Step 2 (gutter marking) is handled entirely by the UI now
// (GutterAdjustScreen) — the user marks it directly on the already-
// flattened spread this module produces, so this file has no detection
// logic of its own to get wrong.
//
// Step 4 (curvature/mesh dewarping near the spine) is explicitly deferred
// per the design doc — out of scope for v1.

import 'dart:math';
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../models/page.dart';
import 'book_geometry.dart';
import 'warp.dart';

/// A straight line marking where to split the flattened spread —
/// [topX]/[bottomX] are x-coordinates at y=0 and y=[height] respectively,
/// in the FLATTENED spread's own coordinate space (not the raw photo's).
@Deprecated('Use GutterPath. Kept for source compatibility with V1 callers.')
class GutterLine {
  final double topX;
  final double bottomX;
  const GutterLine(this.topX, this.bottomX);
}

class BookSplitResult {
  final WarpResult left;
  final WarpResult right;
  BookSplitResult(this.left, this.right);
}

class BookProcessor {
  /// Stage 1 (design doc §4 step 1): flatten the whole open-spread quad
  /// the user adjusted on the corner-adjust screen. Raw color, no
  /// enhancement — enhancement happens per-half, after the split.
  static WarpResult flattenSpread({
    required Uint8List imageBytes,
    required List<Point<double>> outerCorners,
  }) {
    return ImageWarper.warpOnly(imageBytes: imageBytes, corners: outerCorners);
  }

  /// Stage 3 + 4 (design doc §4 step 3): split the already-flattened
  /// [spread] at [gutter], independently re-warp each half (this is what
  /// corrects any tilt the gutter line captured — a plain crop wouldn't),
  /// then apply [colorMode] and encode both halves.
  ///
  /// Because stage 1 already flattened the outer boundary, the top/
  /// bottom/outer edges of each half are already known straight lines at
  /// (0,0)-(W,0)-(W,H)-(0,H) — only the gutter (4th edge) needed
  /// marking, which the user did directly on the corner-adjust screen.
  static BookSplitResult splitAndWarp({
    required WarpResult spread,
    required GutterLine gutter,
    required ColorMode colorMode,
  }) => splitAndWarpPath(
    spread: spread,
    gutter: GutterPath.fromLine(
      topX: gutter.topX,
      bottomX: gutter.bottomX,
      height: spread.height.toDouble(),
    ),
    colorMode: colorMode,
  );

  /// V2 entry point. The current perspective-only fallback reduces the
  /// path to its end points because a homography only accepts four corners.
  /// The full path is preserved in the model/UI for future mesh dewarping.
  static BookSplitResult splitAndWarpPath({
    required WarpResult spread,
    required GutterPath gutter,
    required ColorMode colorMode,
  }) {
    final spreadMat = cv.imdecode(spread.jpegBytes, cv.IMREAD_COLOR);
    cv.Mat leftWarped = cv.Mat.empty();
    cv.Mat rightWarped = cv.Mat.empty();
    cv.Mat leftEnhanced = cv.Mat.empty();
    cv.Mat rightEnhanced = cv.Mat.empty();
    try {
      final w = spread.width.toDouble();
      final h = spread.height.toDouble();

      final leftQuad = [
        Point(0.0, 0.0),
        Point(gutter.xAt(0), 0.0),
        Point(gutter.xAt(h), h),
        Point(0.0, h),
      ];
      final rightQuad = [
        Point(gutter.xAt(0), 0.0),
        Point(w, 0.0),
        Point(w, h),
        Point(gutter.xAt(h), h),
      ];

      leftWarped = ImageWarper.warpMatToQuadFlat(spreadMat, leftQuad);
      rightWarped = ImageWarper.warpMatToQuadFlat(spreadMat, rightQuad);

      leftEnhanced = ImageWarper.applyColorMode(leftWarped, colorMode);
      rightEnhanced = ImageWarper.applyColorMode(rightWarped, colorMode);

      final leftResult = ImageWarper.encodeJpeg(leftEnhanced);
      final rightResult = ImageWarper.encodeJpeg(rightEnhanced);

      return BookSplitResult(leftResult, rightResult);
    } finally {
      spreadMat.dispose();
      leftWarped.dispose();
      rightWarped.dispose();
      leftEnhanced.dispose();
      rightEnhanced.dispose();
    }
  }
}
