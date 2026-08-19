// JPEG/PNG export with quality presets (design doc §6).
// "Small / Balanced / Best" -> JPEG quality ~50/75/95 plus an optional
// max-dimension downscale, so shared files stay WhatsApp/email-sane.

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../models/page.dart';

enum ExportQuality { small, balanced, best }

class ExportQualitySettings {
  final int jpegQuality;
  final int? maxDimension; // longest side, null = no downscale

  const ExportQualitySettings(this.jpegQuality, this.maxDimension);

  static const map = {
    ExportQuality.small: ExportQualitySettings(50, 1240), // ~A4 @ 150dpi
    ExportQuality.balanced: ExportQualitySettings(75, 1980),
    ExportQuality.best: ExportQualitySettings(95, null),
  };
}

class ImageExporter {
  /// Applies stored rotation + the chosen quality preset, writes a JPEG to
  /// [outputPath], and returns the file.
  static Future<File> exportPage(
    ScanPage page, {
    required String outputPath,
    ExportQuality quality = ExportQuality.balanced,
  }) async {
    final bytes = await File(page.imagePath).readAsBytes();
    var decoded = img.decodeImage(bytes)!;

    if (page.rotation != 0) {
      decoded = img.copyRotate(decoded, angle: page.rotation);
    }

    final settings = ExportQualitySettings.map[quality]!;
    if (settings.maxDimension != null) {
      final longest = decoded.width > decoded.height
          ? decoded.width
          : decoded.height;
      if (longest > settings.maxDimension!) {
        decoded = decoded.width >= decoded.height
            ? img.copyResize(decoded, width: settings.maxDimension!)
            : img.copyResize(decoded, height: settings.maxDimension!);
      }
    }

    final encoded = img.encodeJpg(decoded, quality: settings.jpegQuality);
    final file = File(outputPath);
    await file.writeAsBytes(encoded);
    return file;
  }

  static Uint8List rotateBytes(Uint8List bytes, int rotationDegrees) {
    if (rotationDegrees == 0) return bytes;
    final decoded = img.decodeImage(bytes)!;
    final rotated = img.copyRotate(decoded, angle: rotationDegrees);
    return Uint8List.fromList(img.encodeJpg(rotated, quality: 92));
  }

  /// Cheap thumbnail for the document editor's page grid.
  static Future<Uint8List> thumbnail(ScanPage page, {int maxDim = 240}) async {
    final bytes = await File(page.imagePath).readAsBytes();
    var decoded = img.decodeImage(bytes)!;
    if (page.rotation != 0) {
      decoded = img.copyRotate(decoded, angle: page.rotation);
    }
    final thumb = decoded.width >= decoded.height
        ? img.copyResize(decoded, width: maxDim)
        : img.copyResize(decoded, height: maxDim);
    return Uint8List.fromList(img.encodeJpg(thumb, quality: 80));
  }
}
