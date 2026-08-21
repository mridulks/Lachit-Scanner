// Perspective correction + post-warp enhancement (design doc §3).
//
// Refactored (Book Mode addition, design doc §4) so the underlying
// "warp a quad to a flat rectangle" and "apply a color mode" primitives
// are reusable by BookProcessor, which needs to warp the whole spread
// once and then warp each half independently against an already-decoded
// Mat, rather than always going bytes-in/bytes-out.

import 'dart:math';
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../models/page.dart';

class WarpResult {
  final Uint8List jpegBytes;
  final int width;
  final int height;
  WarpResult(this.jpegBytes, this.width, this.height);
}

class ImageWarper {
  /// Warps [imageBytes] using the 4 [corners] (in the SAME pixel space as
  /// the image, ordered TL, TR, BR, BL) into a flat rectangle, then applies
  /// the requested [colorMode]. This is the Document Mode entry point.
  static WarpResult warpAndEnhance({
    required Uint8List imageBytes,
    required List<Point<double>> corners,
    required ColorMode colorMode,
  }) {
    final src = cv.imdecode(imageBytes, cv.IMREAD_COLOR);
    cv.Mat warped = cv.Mat.empty();
    cv.Mat enhanced = cv.Mat.empty();
    try {
      warped = warpMatToQuadFlat(src, corners);
      enhanced = applyColorMode(warped, colorMode);
      return encodeJpeg(enhanced);
    } finally {
      src.dispose();
      warped.dispose();
      enhanced.dispose();
    }
  }

  /// Warps [imageBytes] using [corners] into a flat rectangle and returns
  /// the raw perspective-corrected COLOR image (no enhancement applied).
  /// This is Book Mode's stage 1 (design doc §4 step 1): flatten the
  /// whole spread first, so gutter detection runs on an already-rectified
  /// image, and so each half can be independently re-warped in stage 3.
  ///
  /// Encoded as PNG (lossless), not JPEG, despite the field being named
  /// `jpegBytes` — this is an INTERMEDIATE result that Book Mode decodes
  /// and re-encodes AGAIN after the per-half re-warp (see
  /// BookProcessor), and stacking two lossy JPEG round-trips was a real
  /// source of extra pixelation/noise in Book Mode output vs. Document
  /// Mode's single round-trip. Both opencv's imdecode() and the `image`
  /// package's decodeImage() sniff format from the bytes themselves, not
  /// a filename, so nothing downstream needs to know or care.
  static WarpResult warpOnly({
    required Uint8List imageBytes,
    required List<Point<double>> corners,
  }) {
    final src = cv.imdecode(imageBytes, cv.IMREAD_COLOR);
    cv.Mat warped = cv.Mat.empty();
    try {
      warped = warpMatToQuadFlat(src, corners);
      return encodePng(warped);
    } finally {
      src.dispose();
      warped.dispose();
    }
  }

  /// Core primitive: warps the quad [corners] within already-decoded [src]
  /// to a flat rectangle sized from the corners' own side lengths. Caller
  /// owns and must dispose the returned Mat (and [src]).
  static cv.Mat warpMatToQuadFlat(cv.Mat src, List<Point<double>> corners) {
    final tl = corners[0], tr = corners[1], br = corners[2], bl = corners[3];
    final (outW, outH) = outputSizeForQuad(corners);

    final srcPts = cv.VecPoint2f.fromList([
      cv.Point2f(tl.x, tl.y),
      cv.Point2f(tr.x, tr.y),
      cv.Point2f(br.x, br.y),
      cv.Point2f(bl.x, bl.y),
    ]);
    final dstPts = cv.VecPoint2f.fromList([
      cv.Point2f(0, 0),
      cv.Point2f(outW.toDouble(), 0),
      cv.Point2f(outW.toDouble(), outH.toDouble()),
      cv.Point2f(0, outH.toDouble()),
    ]);

    // dartcv4 splits getPerspectiveTransform into an int-point overload
    // (getPerspectiveTransform, takes VecPoint) and a float-point one
    // (getPerspectiveTransform2f, takes VecPoint2f) — we need the 2f
    // version since corners are sub-pixel Point2f.
    final m = cv.getPerspectiveTransform2f(srcPts, dstPts);
    try {
      return cv.warpPerspective(src, m, (outW, outH));
    } finally {
      m.dispose();
    }
  }

  /// Output rectangle size for warping [corners] (TL,TR,BR,BL) flat — the
  /// max of the two width/height estimates, so we don't upsample past the
  /// source resolution unnecessarily.
  static (int, int) outputSizeForQuad(List<Point<double>> corners) {
    final tl = corners[0], tr = corners[1], br = corners[2], bl = corners[3];
    final widthTop = _dist(tl, tr);
    final widthBottom = _dist(bl, br);
    final heightLeft = _dist(tl, bl);
    final heightRight = _dist(tr, br);
    final outW = max(widthTop, widthBottom).round();
    final outH = max(heightLeft, heightRight).round();
    return (outW, outH);
  }

  /// Encodes [mat] to JPEG and wraps it with its dimensions. Does NOT
  /// dispose [mat] — caller still owns it.
  static WarpResult encodeJpeg(cv.Mat mat, {int quality = 92}) {
    final (success, encoded) = cv.imencode('.jpg', mat,
        params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, quality]));
    if (!success) {
      throw StateError('JPEG encode failed after warp.');
    }
    return WarpResult(Uint8List.fromList(encoded), mat.cols, mat.rows);
  }

  /// Encodes [mat] to PNG (lossless) and wraps it with its dimensions.
  /// Used for intermediate Book Mode results that get decoded again
  /// downstream — see warpOnly()'s doc comment. Does NOT dispose [mat].
  static WarpResult encodePng(cv.Mat mat) {
    final (success, encoded) = cv.imencode('.png', mat);
    if (!success) {
      throw StateError('PNG encode failed after warp.');
    }
    return WarpResult(Uint8List.fromList(encoded), mat.cols, mat.rows);
  }

  static double _dist(Point<double> a, Point<double> b) =>
      sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));

  /// Applies the requested enhancement. Public (was private) so
  /// BookProcessor can apply it per-half after the second-stage warp.
  static cv.Mat applyColorMode(cv.Mat input, ColorMode mode) {
    switch (mode) {
      case ColorMode.color:
        // Mild contrast/white-balance normalization only.
        return cv.convertScaleAbs(input, alpha: 1.08, beta: 6);

      case ColorMode.grayscale:
        final gray = cv.cvtColor(input, cv.COLOR_BGR2GRAY);
        try {
          // CLAHE's constructor takes positional args in dartcv4 1.1.8,
          // not named params: CLAHE([clipLimit = 40, tileGridSize = (8,8)])
          final clahe = cv.CLAHE(2.0, (8, 8));
          return clahe.apply(gray);
        } finally {
          gray.dispose();
        }

      case ColorMode.bw:
        final gray = cv.cvtColor(input, cv.COLOR_BGR2GRAY);
        cv.Mat denoised = cv.Mat.empty();
        try {
          // Median blur before thresholding — knocks out the salt-and-
          // pepper speckle that adaptiveThreshold otherwise amplifies
          // from paper texture and JPEG noise. Small odd kernel (3) so
          // it doesn't visibly soften actual text edges.
          denoised = cv.medianBlur(gray, 3);
          return cv.adaptiveThreshold(
            denoised,
            255,
            cv.ADAPTIVE_THRESH_GAUSSIAN_C,
            cv.THRESH_BINARY,
            25, // block size — odd, tuned for typical phone-camera DPI
            10, // C — subtracted constant; higher = more aggressive
          );
        } finally {
          gray.dispose();
          denoised.dispose();
        }
    }
  }
}
