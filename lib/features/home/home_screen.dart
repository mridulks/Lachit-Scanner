import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  Future<void> _newScan(ScanKind kind) async {
    // A fresh scan session starts with no active document; the first
    // captured page (or page pair, for Book Mode) creates one — see
    // CornerAdjustScreen._confirm().
    ref.read(activeDocumentProvider.notifier).state = null;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ScannerScreen(scanKind: kind)),
    );
    setState(() {});
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

  @override
  Widget build(BuildContext context) {
    ref.watch(documentVersionProvider);
    final storage = ref.read(storageProvider);
    final docs = storage.listDocuments();

    return Scaffold(
      appBar: AppBar(title: const Text('Lachit Scanner')),
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
                    leading: Icon(
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
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              DocumentEditorScreen(documentId: doc.id),
                        ),
                      );
                      setState(() {});
                    },
                    trailing: IconButton(
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
            onPressed: () => _newScan(ScanKind.book),
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
}
