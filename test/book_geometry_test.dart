import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:lachit_scanner/core/cv/book_geometry.dart';

void main() {
  group('GutterPath', () {
    test('interpolates a curved path at arbitrary rows', () {
      final path = GutterPath([
        const Point(100, 0),
        const Point(140, 50),
        const Point(120, 100),
      ]);

      expect(path.xAt(25), 120);
      expect(path.xAt(75), 130);
      expect(path.xAt(-1), 100);
      expect(path.xAt(101), 120);
    });

    test('centred path has evenly spaced vertical controls', () {
      final path = GutterPath.centered(width: 200, height: 120);

      expect(path.points, hasLength(7));
      expect(path.points.every((point) => point.x == 100), isTrue);
      expect(path.points.first.y, 0);
      expect(path.points.last.y, 120);
    });
  });
}
