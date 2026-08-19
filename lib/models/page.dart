import 'package:hive/hive.dart';

part 'page.g.dart';

enum PageSourceMode { document, bookLeft, bookRight }

enum ColorMode { color, grayscale, bw }

@HiveType(typeId: 1)
class ScanPage extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  int order;

  /// Path to the processed (warped + enhanced) image on disk.
  @HiveField(2)
  String imagePath;

  @HiveField(3)
  int sourceModeIndex; // PageSourceMode

  @HiveField(4)
  int rotation; // 0, 90, 180, 270 — applied at render/export time only

  @HiveField(5)
  int colorModeIndex; // ColorMode

  @HiveField(6)
  DateTime createdAt;

  ScanPage({
    required this.id,
    required this.order,
    required this.imagePath,
    this.sourceModeIndex = 0,
    this.rotation = 0,
    this.colorModeIndex = 2, // default B&W, classic "scanned doc" look
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  PageSourceMode get sourceMode => PageSourceMode.values[sourceModeIndex];
  ColorMode get colorMode => ColorMode.values[colorModeIndex];

  set colorMode(ColorMode mode) => colorModeIndex = mode.index;
}
