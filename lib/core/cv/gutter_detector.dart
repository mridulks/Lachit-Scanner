// Gutter (spine fold) detection — design doc §4 step 2.
//
// Deliberately implemented with the pure-Dart `image` package rather than
// more opencv_dart calls: we already depend on `image` for rotation/
// thumbnails, its pixel-access API (Image.getPixel -> Pixel.r/g/b) is
// stable across versions, and this keeps the one genuinely novel bit of
// CV logic in this feature off of opencv_dart's less-exercised
// submatrix/reduction API surface, where we've already hit two rounds of
// version-drift surprises on the core calls.

import 'dart:typed_data';

import 'package:image/image.dart' as img;

class GutterLine {
  /// x-coordinate of the gutter at the top of the image.
  final double topX;

  /// x-coordinate of the gutter at the bottom of the image — usually
  /// close to [topX] but allowed to differ, since the spine rarely sits
  /// at a perfectly constant x once the photo has any camera tilt at all.
  final double bottomX;

  const GutterLine(this.topX, this.bottomX);
}

class GutterDetector {
  /// Locates the spine fold within [flattenedSpreadJpegBytes] — an image
  /// that has ALREADY been perspective-warped to a flat rectangle by
  /// ImageWarper.warpOnly() (i.e. this only has to find a shadow/line, not
  /// also correct outer perspective).
  ///
  /// Approach: split the image height into [bands] horizontal strips.
  /// The FIRST band searches the middle third of the width for the column
  /// with the lowest average luminance (the fold usually reads as a
  /// shadow). Every subsequent band searches only a narrow window AROUND
  /// the previous band's result — this continuity constraint is what
  /// keeps the search from "jumping" to some unrelated dark region
  /// (background clutter, a shadow from the book's own curvature, table
  /// texture) far from the actual spine — a real failure mode when the
  /// outer quad the user drew includes much of the surrounding scene, not
  /// just the book, so "middle third of the width" no longer lines up
  /// with the true spine position. Collected points are then fit to a
  /// straight line; if that fit still implies an implausibly large skew
  /// end-to-end, it's distrusted in favor of a vertical line through the
  /// points' median (better to be centered-but-straight than confidently
  /// wrong).
  ///
  /// Design doc §4 step 2 also mentions a full quadratic/piecewise fit for
  /// spine curvature — this straight-line fit is the v1 simplification;
  /// it already captures ordinary camera-angle skew (why topX and bottomX
  /// can differ) and is the more impactful of the two effects to model.
  static GutterLine detect(Uint8List flattenedSpreadJpegBytes, {int bands = 12}) {
    final decoded = img.decodeImage(flattenedSpreadJpegBytes);
    if (decoded == null) {
      throw StateError('Could not decode flattened spread for gutter detection.');
    }

    final w = decoded.width;
    final h = decoded.height;

    // First band's search range: the middle third, same starting
    // assumption as before.
    final wideStart = (w * 0.33).round().clamp(0, w - 1);
    final wideEnd = (w * 0.67).round().clamp(wideStart + 1, w);

    // Subsequent bands: how far (in px) the found x is allowed to move
    // from the previous band's x. Keeps the line continuous instead of
    // letting one noisy band yank it toward an unrelated dark patch.
    final maxJump = (w * 0.05).clamp(4.0, 200.0);

    final points = <List<double>>[]; // each entry: [y, x]
    double? prevX;

    for (var b = 0; b < bands; b++) {
      final yStart = (h * b / bands).round();
      final yEnd = (h * (b + 1) / bands).round().clamp(yStart + 1, h);

      int searchStart, searchEnd;
      if (prevX == null) {
        searchStart = wideStart;
        searchEnd = wideEnd;
      } else {
        searchStart = (prevX - maxJump).round().clamp(0, w - 1);
        searchEnd = (prevX + maxJump).round().clamp(searchStart + 1, w);
      }

      double bestLuma = double.infinity;
      var bestX = -1;

      for (var x = searchStart; x < searchEnd; x++) {
        var sum = 0.0;
        var count = 0;
        for (var y = yStart; y < yEnd; y += 2) {
          // sample every other row — plenty for a shadow-band search,
          // and keeps this O(bands * window * height/2) loop fast.
          final p = decoded.getPixel(x, y);
          // Standard luma weights; avoids depending on a specific
          // "luminance" accessor name that may vary across `image`
          // package versions.
          final luma = (p.r * 0.299 + p.g * 0.587 + p.b * 0.114) / 255.0;
          sum += luma;
          count++;
        }
        if (count == 0) continue;
        final avg = sum / count;
        if (avg < bestLuma) {
          bestLuma = avg;
          bestX = x;
        }
      }

      if (bestX != -1) {
        points.add([(yStart + yEnd) / 2.0, bestX.toDouble()]);
        prevX = bestX.toDouble();
      }
      // If a band finds nothing (shouldn't normally happen — there's
      // always a darkest column in any nonempty window), prevX just
      // carries over unchanged, so the next band still searches near
      // the last known-good position rather than resetting wide.
    }

    if (points.length < 2) {
      // Detection failed entirely (e.g. very uniform lighting, no
      // visible shadow anywhere) — fall back to a straight vertical
      // line through image center. Mirrors EdgeDetector.fallbackQuad's
      // philosophy: never block the flow, hand back a sane default the
      // user can still work with, even if it's not perfectly on the spine.
      final centerX = w / 2.0;
      return GutterLine(centerX, centerX);
    }

    // Least-squares line fit: x = a*y + b.
    final n = points.length;
    var sumY = 0.0, sumX = 0.0, sumYY = 0.0, sumXY = 0.0;
    for (final p in points) {
      final y = p[0], x = p[1];
      sumY += y;
      sumX += x;
      sumYY += y * y;
      sumXY += x * y;
    }
    final denom = n * sumYY - sumY * sumY;
    double a, b;
    if (denom.abs() < 1e-6) {
      a = 0;
      b = sumX / n;
    } else {
      a = (n * sumXY - sumY * sumX) / denom;
      b = (sumX - a * sumY) / n;
    }

    var topX = (a * 0 + b).clamp(0.0, w.toDouble());
    var bottomX = (a * h + b).clamp(0.0, w.toDouble());

    // Sanity check: a real camera-angle skew rarely moves the spine more
    // than ~20% of the image width from top to bottom. A bigger swing
    // than that means the continuity constraint still got dragged off
    // course (e.g. by a strong shadow near one edge) — better to hand
    // back a straight, centered-on-the-data line than a confidently
    // wrong diagonal one.
    if ((topX - bottomX).abs() > w * 0.2) {
      final xs = points.map((p) => p[1]).toList()..sort();
      final medianX = xs[xs.length ~/ 2];
      topX = medianX;
      bottomX = medianX;
    }

    return GutterLine(topX, bottomX);
  }
}
