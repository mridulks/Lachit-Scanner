import 'dart:typed_data';

import 'book_geometry.dart';
import 'edge_detector.dart';

/// Detects the outer boundary of an open book.
///
/// Document detection remains owned by [EdgeDetector]. This class currently
/// reuses its proven contour scorer with book-specific thresholds, while its
/// return type is intentionally book-specific so page-surface detection can
/// replace the boundary heuristic later without changing callers.
class BookDetector {
  static const double minAreaFraction = 0.12;

  static BookGeometry? detect(Uint8List imageBytes) {
    final quad = EdgeDetector.detect(
      imageBytes,
      minAreaFraction: minAreaFraction,
    );
    if (quad == null) return null;
    return BookGeometry(
      outerBoundary: quad.corners,
      confidence: quad.areaFraction,
    );
  }
}
