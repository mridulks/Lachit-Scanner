// Builds a multi-page PDF from already-processed page images.
// Design doc §6: "iterate pages in order, add each as a full-page image
// respecting original aspect ratio, set page size to match image (or
// standard A4/Letter with fit — offer as a toggle)."

import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:image/image.dart' as img;

import '../../models/page.dart';

enum PdfPageSizing { matchImage, a4Fit, letterFit }

class PdfBuilder {
  /// Builds a PDF from [pages] (already in display order) and writes it to
  /// [outputPath]. Rotation stored on each ScanPage is applied here, at
  /// export time, rather than destructively baked into the source file
  /// (design doc §5 — keeps retake/undo cheap).
  static Future<File> build({
    required List<ScanPage> pages,
    required String outputPath,
    PdfPageSizing sizing = PdfPageSizing.matchImage,
  }) async {
    final doc = pw.Document();

    for (final page in pages) {
      final bytes = await File(page.imagePath).readAsBytes();
      final rotated = _applyRotation(bytes, page.rotation);
      final image = pw.MemoryImage(rotated.bytes);

      final pageFormat = switch (sizing) {
        PdfPageSizing.matchImage => PdfPageFormat(
          rotated.width.toDouble(),
          rotated.height.toDouble(),
          marginAll: 0,
        ),
        PdfPageSizing.a4Fit => PdfPageFormat.a4,
        PdfPageSizing.letterFit => PdfPageFormat.letter,
      };

      doc.addPage(
        pw.Page(
          pageFormat: pageFormat,
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.Center(
            child: sizing == PdfPageSizing.matchImage
                ? pw.Image(image, fit: pw.BoxFit.fill)
                : pw.Image(image, fit: pw.BoxFit.contain),
          ),
        ),
      );
    }

    final file = File(outputPath);
    await file.writeAsBytes(await doc.save());
    return file;
  }

  static _RotatedImage _applyRotation(Uint8List bytes, int rotationDegrees) {
    if (rotationDegrees == 0) {
      final decoded = img.decodeImage(bytes)!;
      return _RotatedImage(bytes, decoded.width, decoded.height);
    }
    final decoded = img.decodeImage(bytes)!;
    final rotated = img.copyRotate(decoded, angle: rotationDegrees);
    final encoded = Uint8List.fromList(img.encodeJpg(rotated, quality: 92));
    return _RotatedImage(encoded, rotated.width, rotated.height);
  }
}

class _RotatedImage {
  final Uint8List bytes;
  final int width;
  final int height;
  _RotatedImage(this.bytes, this.width, this.height);
}
