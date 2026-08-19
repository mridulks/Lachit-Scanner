// Book Mode processing pipeline (design doc §4, steps 1–3).
//
// Split into explicit stages (rather than one do-everything call) so the
// UI can show the user the detected gutter line and let them adjust it
// before the final split+warp actually runs — see
// features/gutter_adjust/gutter_adjust_screen.dart. Detecting a spine
// fold from a shadow is inherently less reliable than the user's own
// eyes, so — same philosophy as the manual corner-adjust fallback in
// Document Mode — auto-detect should be a starting point, not the final
// word, whenever there's no live preview to catch it going wrong first.
//
// Step 4 (curvature/mesh dewarping near the spine) is explicitly deferred
// per the design doc — out of scope for v1.

import 'dart:math';
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../models/page.dart';
import 'gutter_detector.dart';
import 'warp.dart';

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

  /// Stage 2 (design doc §4 step 2): detect the gutter (spine fold)
  /// within an already-flattened spread. Exposed separately from
  /// [flattenSpread] so the UI can show this as an adjustable starting
  /// point rather than a black box.
  static GutterLine detectGutter(WarpResult spread) {
    return GutterDetector.detect(spread.jpegBytes);
  }

  /// Stage 3 + 4 (design doc §4 step 3): split the already-flattened
  /// [spread] at [gutter], independently re-warp each half (this is what
  /// corrects any tilt the gutter line captured — a plain crop wouldn't),
  /// then apply [colorMode] and encode both halves.
  ///
  /// Because stage 1 already flattened the outer boundary, the top/
  /// bottom/outer edges of each half are already known straight lines at
  /// (0,0)-(W,0)-(W,H)-(0,H) — only the gutter (4th edge) needed
  /// detecting/adjusting, which stages 2 (and the UI) handled.
  static BookSplitResult splitAndWarp({
    required WarpResult spread,
    required GutterLine gutter,
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
        Point(gutter.topX, 0.0),
        Point(gutter.bottomX, h),
        Point(0.0, h),
      ];
      final rightQuad = [
        Point(gutter.topX, 0.0),
        Point(w, 0.0),
        Point(w, h),
        Point(gutter.bottomX, h),
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
