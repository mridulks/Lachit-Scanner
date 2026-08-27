// Export options screen (design doc §6): JPEG images are the default
// format, with "Best — original resolution" as the default quality preset;
// PDF export is also available for a full multi-page document. Single-page
// image/PDF export is additionally available from the document editor's
// per-page menu.


import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/export/image_export.dart';
import '../../core/export/pdf_builder.dart';
import '../../core/providers.dart';
import '../../models/document.dart';
import '../../models/page.dart';

enum ExportFormat { pdf, images }

class ExportScreen extends ConsumerStatefulWidget {
  final ScanDocument document;

  /// If set, only this single page is exported (per-page "Export" menu
  /// item); otherwise all pages in the document are exported.
  final ScanPage? singlePage;

  const ExportScreen({super.key, required this.document, this.singlePage});

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  ExportFormat _format = ExportFormat.images;
  ExportQuality _quality = ExportQuality.best;
  PdfPageSizing _sizing = PdfPageSizing.matchImage;
  bool _working = false;

  List<ScanPage> get _pages {
    final storage = ref.read(storageProvider);
    return widget.singlePage != null
        ? [widget.singlePage!]
        : storage.pagesFor(widget.document);
  }

  Future<void> _export() async {
    setState(() => _working = true);
    try {
      final pages = _pages;
      final tmpDir = await getTemporaryDirectory();
      final baseName = widget.document.name.replaceAll(
        RegExp(r'[^A-Za-z0-9 _-]'),
        '_',
      );

      List<XFile> files = [];

      if (_format == ExportFormat.pdf) {
        final outPath = '${tmpDir.path}/$baseName.pdf';
        await PdfBuilder.build(
          pages: pages,
          outputPath: outPath,
          sizing: _sizing,
        );
        files = [XFile(outPath, mimeType: 'application/pdf')];
      } else {
        files = [];
        for (var i = 0; i < pages.length; i++) {
          final outPath = '${tmpDir.path}/${baseName}_p${i + 1}.jpg';
          await ImageExporter.exportPage(
            pages[i],
            outputPath: outPath,
            quality: _quality,
          );
          files.add(XFile(outPath, mimeType: 'image/jpeg'));
        }
      }

      if (!mounted) return;
      await Share.shareXFiles(files, text: widget.document.name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Export')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            widget.singlePage != null
                ? 'Exporting 1 page'
                : 'Exporting ${_pages.length} page(s)',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          const Text('Format', style: TextStyle(fontWeight: FontWeight.bold)),
          RadioListTile<ExportFormat>(
            title: const Text('PDF'),
            value: ExportFormat.pdf,
            groupValue: _format,
            onChanged: (v) => setState(() => _format = v!),
          ),
          RadioListTile<ExportFormat>(
            title: const Text('JPEG image(s)'),
            value: ExportFormat.images,
            groupValue: _format,
            onChanged: (v) => setState(() => _format = v!),
          ),
          const Divider(height: 32),
          if (_format == ExportFormat.pdf) ...[
            const Text(
              'Page size',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            RadioListTile<PdfPageSizing>(
              title: const Text('Match scanned image'),
              value: PdfPageSizing.matchImage,
              groupValue: _sizing,
              onChanged: (v) => setState(() => _sizing = v!),
            ),
            RadioListTile<PdfPageSizing>(
              title: const Text('A4 (fit)'),
              value: PdfPageSizing.a4Fit,
              groupValue: _sizing,
              onChanged: (v) => setState(() => _sizing = v!),
            ),
            RadioListTile<PdfPageSizing>(
              title: const Text('US Letter (fit)'),
              value: PdfPageSizing.letterFit,
              groupValue: _sizing,
              onChanged: (v) => setState(() => _sizing = v!),
            ),
          ] else ...[
            const Text(
              'Quality',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            RadioListTile<ExportQuality>(
              title: const Text('Small — best for chat/email'),
              value: ExportQuality.small,
              groupValue: _quality,
              onChanged: (v) => setState(() => _quality = v!),
            ),
            RadioListTile<ExportQuality>(
              title: const Text('Balanced'),
              value: ExportQuality.balanced,
              groupValue: _quality,
              onChanged: (v) => setState(() => _quality = v!),
            ),
            RadioListTile<ExportQuality>(
              title: const Text('Best — original resolution'),
              value: ExportQuality.best,
              groupValue: _quality,
              onChanged: (v) => setState(() => _quality = v!),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _working ? null : _export,
            icon: _working
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share),
            label: const Text('Share / Save'),
          ),
        ],
      ),
    );
  }
}
