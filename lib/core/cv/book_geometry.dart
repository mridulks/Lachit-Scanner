import 'dart:math';

/// Geometry for an approximately rectified open book spread.
///
/// This deliberately separates the book representation from document quads:
/// a book has an outer boundary and a potentially curved centre gutter.
class BookGeometry {
  final List<Point<double>> outerBoundary;
  final GutterPath? gutterPath;
  final double confidence;

  const BookGeometry({
    required this.outerBoundary,
    this.gutterPath,
    this.confidence = 0,
  }) : assert(outerBoundary.length == 4);

  BookGeometry copyWith({GutterPath? gutterPath, double? confidence}) {
    return BookGeometry(
      outerBoundary: outerBoundary,
      gutterPath: gutterPath ?? this.gutterPath,
      confidence: confidence ?? this.confidence,
    );
  }
}

/// A top-to-bottom, piecewise-linear gutter. Points are in image pixels.
///
/// Keeping a path instead of a two-endpoint line lets the current UI edit a
/// curve and leaves a natural input for a future page-surface dewarper.
class GutterPath {
  final List<Point<double>> points;

  GutterPath(List<Point<double>> points)
    : assert(points.length >= 2),
      points = List.unmodifiable(
        [...points]..sort((a, b) => a.y.compareTo(b.y)),
      );

  factory GutterPath.centered({
    required double width,
    required double height,
    int controlPointCount = 7,
  }) {
    final x = width / 2;
    return GutterPath(
      List.generate(
        controlPointCount,
        (index) => Point(x, height * index / (controlPointCount - 1)),
      ),
    );
  }

  /// Straight-line compatibility bridge for the old split-and-warp pipeline.
  factory GutterPath.fromLine({
    required double topX,
    required double bottomX,
    required double height,
  }) => GutterPath([Point(topX, 0), Point(bottomX, height)]);

  GutterPath withPoint(int index, Point<double> point) {
    final next = [...points];
    next[index] = point;
    return GutterPath(next);
  }

  /// Interpolated horizontal position for [y].
  double xAt(double y) {
    if (y <= points.first.y) return points.first.x;
    if (y >= points.last.y) return points.last.x;
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i];
      final b = points[i + 1];
      if (y >= a.y && y <= b.y) {
        final t = (y - a.y) / (b.y - a.y);
        return a.x + (b.x - a.x) * t;
      }
    }
    return points.last.x;
  }
}
