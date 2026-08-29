// Export options screen (design doc §6): JPEG images are the default
// format, with "Best — original resolution" as the default quality preset;
// PDF export is also available for a full multi-page document. Single-page
// image/PDF export is additionally available from the document editor's
// per-page menu.
//
// "Save to Gallery" (JPEG only — a PDF isn't a gallery-type asset on
// either platform) is a second, direct path alongside the existing
// Share/Save sheet: it writes straight into the device's Photos/Gallery
// app via the `gal` plugin, under a dedicated "Lachit Scanner" album,
// rather than routing through whatever the OS share sheet happens to
// offer.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
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
  static const _galleryAlbum = 'Lachit Scanner';

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

  String get _baseName => widget.document.name.replaceAll(
        RegExp(r'[^A-Za-z0-9 _-]'),
        '_',
      );

  Future<void> _export() async {
    setState(() => _working = true);
    try {
      final pages = _pages;
      final tmpDir = await getTemporaryDirectory();
      final baseName = _baseName;

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

  /// Saves the JPEG page image(s) directly to the device's Photos/Gallery
  /// app under a dedicated album, bypassing the share sheet entirely.
  /// `toAlbum: true` on the permission calls matters here specifically
  /// because we're targeting a named album rather than the general
  /// camera roll — gal's docs call out that this needs the broader
  /// NSPhotoLibraryUsageDescription permission on iOS, not just the
  /// add-only one a plain (non-album) save would need.
  Future<void> _saveToGallery() async {
    setState(() => _working = true);
    try {
      var hasAccess = await Gal.hasAccess(toAlbum: true);
      if (!hasAccess) {
        hasAccess = await Gal.requestAccess(toAlbum: true);
      }
      if (!hasAccess) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Photo library access is needed to save scans. Enable it '
                'for Lachit Scanner in system Settings and try again.',
              ),
            ),
          );
        }
        return;
      }

      final pages = _pages;
      final tmpDir = await getTemporaryDirectory();
      final baseName = _baseName;
      var saved = 0;

      for (var i = 0; i < pages.length; i++) {
        final outPath = '${tmpDir.path}/${baseName}_gallery_${i + 1}.jpg';
        await ImageExporter.exportPage(
          pages[i],
          outputPath: outPath,
          quality: _quality,
        );
        await Gal.putImage(outPath, album: _galleryAlbum);
        saved++;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              saved == 1
                  ? 'Saved to "$_galleryAlbum" album'
                  : 'Saved $saved photos to "$_galleryAlbum" album',
            ),
          ),
        );
      }
    } on GalException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: ${e.type.message}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
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
          if (_format == ExportFormat.images) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _working ? null : _saveToGallery,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Save to Gallery'),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
              child: Text(
                'Saves straight to your Photos/Gallery app, in an album '
                'named "$_galleryAlbum" — no share sheet needed.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}