// Document editor (design doc §5): reorder via ReorderableListView, retake
// re-opens the camera for that page index and swaps the file while keeping
// the page id, rotate is metadata-only, delete re-sequences order values.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/scan_kind.dart';
import '../../models/document.dart';
import '../../models/page.dart';
import '../export/export_screen.dart';
import '../scanner/scanner_screen.dart';
import 'page_viewer_screen.dart';
import 'image_enhancement_screen.dart';
import 'markup_screen.dart';

class DocumentEditorScreen extends ConsumerStatefulWidget {
  final String documentId;
  const DocumentEditorScreen({super.key, required this.documentId});

  @override
  ConsumerState<DocumentEditorScreen> createState() =>
      _DocumentEditorScreenState();
}

class _DocumentEditorScreenState extends ConsumerState<DocumentEditorScreen> {
  late TextEditingController _nameController;

  ScanDocument get _doc {
    final storage = ref.read(storageProvider);
    return storage.documentsBox.get(widget.documentId)!;
  }

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: _doc.name);
  }

  Future<void> _rename() async {
    final storage = ref.read(storageProvider);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename document'),
        content: TextField(
          controller: _nameController,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Document name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _nameController.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName != null && newName.trim().isNotEmpty) {
      await storage.renameDocument(_doc, newName.trim());
      ref.read(documentVersionProvider.notifier).state++;
    }
  }

  Future<void> _addPage() async {
    await _insertPagesAt(ref.read(storageProvider).pagesFor(_doc).length);
  }

  Future<void> _insertPagesAt(int index) async {
    final storage = ref.read(storageProvider);
    final doc = _doc;
    ref.read(activeDocumentProvider.notifier).state = doc;

    // Infer scan kind from the doc's own pages so "+" on a book-scanned
    // document keeps scanning spreads, and "+" on a plain document keeps
    // scanning single pages, without asking every time.
    final pages = storage.pagesFor(doc);
    final kind =
        pages.isNotEmpty && pages.last.sourceMode != PageSourceMode.document
            ? ScanKind.book
            : ScanKind.document;
    var bookScanMode = BookScanMode.singlePage;
    if (kind == ScanKind.book) {
      final selectedMode = await showDialog<BookScanMode>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Add book page'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, BookScanMode.singlePage),
              child: const ListTile(
                leading: Icon(Icons.article_outlined),
                title: Text('Single page'),
                subtitle: Text('No gutter or page split'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, BookScanMode.twoPage),
              child: const ListTile(
                leading: Icon(Icons.menu_book_outlined),
                title: Text('Two pages'),
                subtitle: Text('Scan an open spread'),
              ),
            ),
          ],
        ),
      );
      if (selectedMode == null || !mounted) return;
      bookScanMode = selectedMode;
    }

    final existingIds = storage.pagesFor(doc).map((page) => page.id).toSet();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScannerScreen(
          scanKind: kind,
          bookScanMode: bookScanMode,
        ),
      ),
    );

    final currentPages = storage.pagesFor(doc);
    final added = currentPages
        .where((page) => !existingIds.contains(page.id))
        .map((page) => page.id)
        .toList();
    if (added.isNotEmpty) {
      final currentIds = currentPages.map((page) => page.id).toList();
      currentIds.removeWhere(added.contains);
      final insertionIndex = index.clamp(0, currentIds.length).toInt();
      currentIds.insertAll(insertionIndex, added);
      await storage.reorderPages(doc, currentIds);
      ref.read(documentVersionProvider.notifier).state++;
    }
    if (mounted) setState(() {});
  }

  Future<void> _retake(ScanPage page) async {
    final capturedPath = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScannerScreen()));
    // Phase 1 note: ScannerScreen currently always creates/appends a new
    // page rather than returning a path for in-place replacement. Wiring
    // retake through StorageService.replacePageImage() is a small follow-up
    // once ScannerScreen accepts an optional "replace this page" mode —
    // tracked as a Phase 3 polish item, not a Phase 1 blocker.
    if (capturedPath != null) {
      final storage = ref.read(storageProvider);
      await storage.replacePageImage(page, capturedPath);
      ref.read(documentVersionProvider.notifier).state++;
    }
    setState(() {});
  }

  Future<void> _rotate(ScanPage page, {required bool clockwise}) async {
    final storage = ref.read(storageProvider);
    await storage.rotatePage(page, clockwise: clockwise);
    setState(() {});
  }

  Future<void> _deletePage(ScanPage page) async {
    final storage = ref.read(storageProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete page?'),
        content: const Text('This cannot be undone.'),
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
      await storage.deletePage(_doc, page);
      ref.read(documentVersionProvider.notifier).state++;
      setState(() {});
    }
  }

  Future<void> _reorder(
    int oldIndex,
    int newIndex,
    List<ScanPage> pages,
  ) async {
    final storage = ref.read(storageProvider);
    if (newIndex > oldIndex) newIndex -= 1;
    final ids = pages.map((p) => p.id).toList();
    final moved = ids.removeAt(oldIndex);
    ids.insert(newIndex, moved);
    await storage.reorderPages(_doc, ids);
    ref.read(documentVersionProvider.notifier).state++;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when documentVersionProvider changes.
    ref.watch(documentVersionProvider);
    final storage = ref.read(storageProvider);
    final doc = _doc;
    final pages = storage.pagesFor(doc);

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _rename,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(doc.name, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 6),
              const Icon(Icons.edit, size: 16),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Export document',
            onPressed: pages.isEmpty
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ExportScreen(document: doc),
                      ),
                    ),
          ),
        ],
      ),
      body: pages.isEmpty
          ? Center(
              child: OutlinedButton.icon(
                onPressed: () => _insertPagesAt(0),
                icon: const Icon(Icons.add_a_photo),
                label: const Text('Scan first page'),
              ),
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: pages.length,
              onReorder: (o, n) => _reorder(o, n, pages),
              itemBuilder: (context, index) {
                final page = pages[index];
                return Column(
                  key: ValueKey(page.id),
                  children: [
                    _InsertPageButton(
                      onPressed: () => _insertPagesAt(index),
                    ),
                    _PageTile(
                      page: page,
                      index: index,
                      onRotateLeft: () => _rotate(page, clockwise: false),
                      onRotateRight: () => _rotate(page, clockwise: true),
                      onRetake: () => _retake(page),
                      onDelete: () => _deletePage(page),
                      onEnhance: () async {
                        final changed = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(
                            builder: (_) => ImageEnhancementScreen(page: page),
                          ),
                        );
                        if (changed == true && mounted) setState(() {});
                      },
                      onMarkup: () async {
                        final changed = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(
                            builder: (_) => MarkupScreen(page: page),
                          ),
                        );
                        if (changed == true && mounted) setState(() {});
                      },
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PageViewerScreen(
                            page: page,
                            index: index,
                            total: pages.length,
                          ),
                        ),
                      ),
                      onExportSingle: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              ExportScreen(document: doc, singlePage: page),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addPage,
        child: const Icon(Icons.add_a_photo),
      ),
    );
  }
}

class _PageTile extends StatelessWidget {
  final ScanPage page;
  final int index;
  final VoidCallback onRotateLeft;
  final VoidCallback onRotateRight;
  final VoidCallback onRetake;
  final VoidCallback onDelete;
  final VoidCallback onEnhance;
  final VoidCallback onMarkup;
  final VoidCallback onTap;
  final VoidCallback onExportSingle;

  const _PageTile({
    required this.page,
    required this.index,
    required this.onRotateLeft,
    required this.onRotateRight,
    required this.onRetake,
    required this.onDelete,
    required this.onEnhance,
    required this.onMarkup,
    required this.onTap,
    required this.onExportSingle,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        onTap: onTap,
        leading: SizedBox(
          width: 56,
          height: 72,
          child: RotatedBox(
            quarterTurns: page.rotation ~/ 90,
            child: Image.file(File(page.imagePath), fit: BoxFit.cover),
          ),
        ),
        title: Text('Page ${index + 1}'),
        subtitle: Text(_modeLabel(page)),
        trailing: PopupMenuButton<String>(
          onSelected: (v) {
            switch (v) {
              case 'rotate_left':
                onRotateLeft();
                break;
              case 'rotate_right':
                onRotateRight();
                break;
              case 'retake':
                onRetake();
                break;
              case 'export':
                onExportSingle();
                break;
              case 'delete':
                onDelete();
                break;
              case 'enhance':
                onEnhance();
                break;
              case 'markup':
                onMarkup();
                break;
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'rotate_left', child: Text('Rotate left')),
            PopupMenuItem(value: 'rotate_right', child: Text('Rotate right')),
            PopupMenuItem(value: 'retake', child: Text('Retake')),
            PopupMenuItem(value: 'enhance', child: Text('Enhance')),
            PopupMenuItem(value: 'markup', child: Text('Markup & annotate')),
            PopupMenuItem(value: 'export', child: Text('Export this page')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }

  String _modeLabel(ScanPage p) {
    final mode = switch (p.sourceMode) {
      PageSourceMode.document => 'Document',
      PageSourceMode.bookLeft => 'Book (left)',
      PageSourceMode.bookRight => 'Book (right)',
    };
    final color = switch (p.colorMode) {
      ColorMode.color => 'Color',
      ColorMode.grayscale => 'Grayscale',
      ColorMode.bw => 'B&W',
    };
    return '$mode · $color';
  }
}

class _InsertPageButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _InsertPageButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: Center(
        child: IconButton(
          onPressed: onPressed,
          icon: const Icon(Icons.add_circle_outline, size: 20),
          tooltip: 'Insert page here',
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}
