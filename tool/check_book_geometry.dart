import 'dart:math';

import 'package:lachit_scanner/core/cv/book_geometry.dart';

void main() {
  final path = GutterPath([
    const Point(100, 0),
    const Point(140, 50),
    const Point(120, 100),
  ]);
  if (path.xAt(25) != 120 || path.xAt(75) != 130) {
    throw StateError('Gutter interpolation failed.');
  }
  final centered = GutterPath.centered(width: 200, height: 120);
  if (centered.points.length != 7 || centered.points.any((point) => point.x != 100)) {
    throw StateError('Centred gutter generation failed.');
  }
  print('Book geometry checks passed.');
}
