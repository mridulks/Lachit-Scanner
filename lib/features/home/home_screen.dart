import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../core/export/image_export.dart';
import '../../core/providers.dart';
import '../../core/scan_kind.dart';
import '../../models/document.dart';
import '../../models/page.dart';
import '../document_editor/document_editor_screen.dart';
import '../scanner/scanner_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final Set<String> _selectedDocumentIds = {};
  bool _selectionMode = false;

  Future<void> _newScan(ScanKind kind, {BookScanMode? bookScanMode}) async {
    // A fresh scan session starts with no active document; the first
    // captured page (or page pair, for Book Mode) creates one — see
    // CornerAdjustScreen._confirm().
    ref.read(activeDocumentProvider.notifier).state = null;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScannerScreen(
          scanKind: kind,
          bookScanMode: bookScanMode ?? BookScanMode.twoPage,
        ),
      ),
    );
    setState(() {});
  }

  Future<void> _newBookScan() async {
    final mode = await showDialog<BookScanMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Book scan mode'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, BookScanMode.singlePage),
            child: const ListTile(
              leading: Icon(Icons.article_outlined),
              title: Text('Single page'),
              subtitle: Text('Scan one page at a time'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, BookScanMode.twoPage),
            child: const ListTile(
              leading: Icon(Icons.menu_book_outlined),
              title: Text('Two pages'),
              subtitle: Text('Split an open spread into two pages'),
            ),
          ),
        ],
      ),
    );
    if (mode != null && mounted) {
      await _newScan(ScanKind.book, bookScanMode: mode);
    }
  }

  Future<void> _deleteDocument(ScanDocument doc) async {
    final storage = ref.read(storageProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete document?'),
        content: Text('"${doc.name}" and all its pages will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await storage.deleteDocument(doc);
      setState(() {});
    }
  }

  Future<void> _deleteSelected(List<ScanDocument> docs) async {
    if (_selectedDocumentIds.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete selected documents?'),
        content:
            Text('${_selectedDocumentIds.length} document(s) will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final storage = ref.read(storageProvider);
      for (final doc in docs.where(
        (doc) => _selectedDocumentIds.contains(doc.id),
      )) {
        await storage.deleteDocument(doc);
      }
      setState(() {
        _selectedDocumentIds.clear();
        _selectionMode = false;
      });
    }
  }

  Future<void> _exportSelected(List<ScanDocument> docs) async {
    final selected =
        docs.where((doc) => _selectedDocumentIds.contains(doc.id)).toList();
    if (selected.isEmpty) return;
    try {
      final tempDir = await getTemporaryDirectory();
      final files = <XFile>[];
      var fileNumber = 1;
      final storage = ref.read(storageProvider);
      for (final doc in selected) {
        for (final page in storage.pagesFor(doc)) {
          final path = '${tempDir.path}/batch_${fileNumber++}.jpg';
          await ImageExporter.exportPage(
            page,
            outputPath: path,
            quality: ExportQuality.best,
          );
          files.add(XFile(path, mimeType: 'image/jpeg'));
        }
      }
      if (files.isNotEmpty && mounted) {
        await Share.shareXFiles(files, text: 'Selected scans');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Batch export failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(documentVersionProvider);
    final storage = ref.read(storageProvider);
    final docs = storage.listDocuments();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selectionMode
              ? '${_selectedDocumentIds.length} selected'
              : 'Lachit Scanner',
        ),
        actions: [
          if (_selectionMode) ...[
            IconButton(
              onPressed: docs.isEmpty
                  ? null
                  : () => setState(() {
                        if (_selectedDocumentIds.length == docs.length) {
                          _selectedDocumentIds.clear();
                        } else {
                          _selectedDocumentIds
                            ..clear()
                            ..addAll(docs.map((doc) => doc.id));
                        }
                      }),
              icon: Icon(
                _selectedDocumentIds.length == docs.length
                    ? Icons.deselect
                    : Icons.select_all,
              ),
              tooltip: _selectedDocumentIds.length == docs.length
                  ? 'Clear selection'
                  : 'Select all',
            ),
            IconButton(
              onPressed: _selectedDocumentIds.isEmpty
                  ? null
                  : () => _exportSelected(docs),
              icon: const Icon(Icons.ios_share),
              tooltip: 'Export selected',
            ),
            IconButton(
              onPressed: _selectedDocumentIds.isEmpty
                  ? null
                  : () => _deleteSelected(docs),
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete selected',
            ),
            IconButton(
              onPressed: () => setState(() {
                _selectedDocumentIds.clear();
                _selectionMode = false;
              }),
              icon: const Icon(Icons.close),
              tooltip: 'Exit selection',
            ),
          ] else ...[
            IconButton(
              onPressed: _showSettingsSheet,
              icon: const Icon(Icons.more_vert),
              tooltip: 'More options',
            ),
            IconButton(
              onPressed: () => setState(() => _selectionMode = true),
              icon: const Icon(Icons.checklist),
              tooltip: 'Select documents',
            ),
          ],
        ],
      ),
      body: docs.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No scans yet.\nTap Document or Book below to scan your first one.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: docs.length,
              itemBuilder: (context, index) {
                final doc = docs[index];
                final pages = storage.pagesFor(doc);
                final pageCount = pages.length;
                final isBookDoc = pages.isNotEmpty &&
                    pages.first.sourceMode != PageSourceMode.document;
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: ListTile(
                    onLongPress: () => setState(() {
                      _selectionMode = true;
                      if (!_selectedDocumentIds.add(doc.id)) {
                        _selectedDocumentIds.remove(doc.id);
                      }
                    }),
                    leading: _selectionMode
                        ? Checkbox(
                            value: _selectedDocumentIds.contains(doc.id),
                            onChanged: (_) => setState(() {
                              if (!_selectedDocumentIds.add(doc.id)) {
                                _selectedDocumentIds.remove(doc.id);
                              }
                            }),
                          )
                        : Icon(
                            isBookDoc
                                ? Icons.menu_book_outlined
                                : Icons.description_outlined,
                            size: 36,
                          ),
                    title: Text(doc.name),
                    subtitle: Text(
                      '$pageCount page${pageCount == 1 ? '' : 's'} · '
                      'Updated ${_formatDate(doc.updatedAt)}',
                    ),
                    onTap: _selectionMode
                        ? () => setState(() {
                              if (!_selectedDocumentIds.add(doc.id)) {
                                _selectedDocumentIds.remove(doc.id);
                              }
                            })
                        : () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    DocumentEditorScreen(documentId: doc.id),
                              ),
                            );
                            setState(() {});
                          },
                    trailing: _selectionMode
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _deleteDocument(doc),
                          ),
                  ),
                );
              },
            ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'scan_book',
            onPressed: _newBookScan,
            icon: const Icon(Icons.menu_book_outlined),
            label: const Text('Book'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'scan_document',
            onPressed: () => _newScan(ScanKind.document),
            icon: const Icon(Icons.add_a_photo),
            label: const Text('Document'),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ---- Settings menu (3-dots) ----

  void _showSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  ref.watch(darkModeProvider)
                      ? Icons.dark_mode
                      : Icons.light_mode,
                ),
                title: const Text('Dark Mode'),
                trailing: Switch(
                  value: ref.watch(darkModeProvider),
                  onChanged: (value) {
                    ref.read(darkModeProvider.notifier).state = value;
                  },
                ),
                onTap: () {
                  ref.read(darkModeProvider.notifier).state =
                      !ref.read(darkModeProvider);
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.tips_and_updates_outlined),
                title: const Text('Tips for better scanning'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showTipsDialog();
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Version Info'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showVersionDialog();
                },
              ),
              ListTile(
                leading: const Icon(Icons.code),
                title: const Text('Developer Info'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showDeveloperDialog();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showTipsDialog() async {
    const tips = <(IconData, String, String)>[
      (
        Icons.lightbulb_outline,
        'Lighting',
        'Use even, diffuse light. Avoid direct glare on the page.',
      ),
      (
        Icons.crop_square,
        'Hold steady',
        'Frame the page fully and hold the device parallel to it.',
      ),
      (
        Icons.contrast,
        'High contrast',
        'Black ink on white paper gives the cleanest scans and best B&W.',
      ),
      (
        Icons.palette,
        'Pick the right mode',
        'Use Color for photos/colour pages, B&W for text, Grayscale for both.',
      ),
      (
        Icons.cleaning_services_outlined,
        'Lens check',
        'Wipe the camera lens before scanning for sharp, clear images.',
      ),
    ];

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tips for better scanning'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (icon, title, body) in tips) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            body,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Future<void> _showVersionDialog() async {
    PackageInfo? info;
    try {
      info = await PackageInfo.fromPlatform();
    } catch (_) {
      // Falls back to the values below if platform channel info isn't
      // available (e.g. certain test/desktop setups).
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Version Info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('App: ${info?.appName ?? 'Lachit Scanner'}'),
            const SizedBox(height: 4),
            Text(
              'Version: ${info?.version ?? '0.1.0'}'
              '${info?.buildNumber.isNotEmpty == true ? ' (${info!.buildNumber})' : ''}',
            ),
            const SizedBox(height: 4),
            Text('Package: ${info?.packageName ?? 'com.lachit.scanner'}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showDeveloperDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Developer Info'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Lachit Scanner'),
            SizedBox(height: 8),
            Text(
              'Free, offline document & book scanner. No accounts, '
              'no cloud, no watermarks, no third-party tracking.',
            ),
            SizedBox(height: 8),
            Text('Built with Flutter, Riverpod, and OpenCV (opencv_dart).'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}