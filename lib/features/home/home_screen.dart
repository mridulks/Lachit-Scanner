import 'dart:io';

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
import '../export/export_screen.dart';
import '../scanner/scanner_screen.dart';

enum _MenuAction {
  toggleTheme,
  tips,
  versionInfo,
  developerInfo,
}

enum _DocAction { rename, export, delete }

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final Set<String> _selectedDocumentIds = {};
  bool _selectionMode = false;
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    _selectionMode = false;
    _selectedDocumentIds.clear();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _packageInfo = info);
    } catch (_) {
      // Leave _packageInfo null — the menu row falls back to the
      // pubspec-pinned version below rather than showing nothing.
    }
  }

  Future<void> _newScan(ScanKind kind, {BookScanMode? bookScanMode}) async {
    ref.read(activeDocumentProvider.notifier).state = null;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScannerScreen(
          scanKind: kind,
          bookScanMode: bookScanMode ?? BookScanMode.twoPage,
        ),
      ),
    );
    if (mounted) setState(() {});
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
              leading: Icon(Icons.menu_book_rounded),
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

  Future<void> _renameDocument(ScanDocument doc) async {
    final storage = ref.read(storageProvider);
    // Rename is triggered from a PopupMenuButton's onSelected, which fires
    // as soon as Navigator.pop() is called for the menu route — not after
    // its close animation/element teardown actually finishes. Opening a
    // new dialog route in that same frame is a known trigger for the
    // '_dependents.isEmpty' assertion, so give the menu route a beat to
    // finish unmounting first.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    // _RenameDialog owns its own TextEditingController and disposes it in
    // its own State.dispose() — i.e. exactly when its Element unmounts.
    // The previous version created the controller here and disposed it
    // right after showDialog() returned, but that Future resolves the
    // instant Navigator.pop() runs, before the dialog's own Focus-node
    // teardown is actually complete — disposing the controller in that
    // window raced it. Letting the dialog manage its own lifecycle avoids
    // the race entirely instead of trying to time around it.
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(initialName: doc.name),
    );
    if (newName != null && newName.trim().isNotEmpty && mounted) {
      await storage.renameDocument(doc, newName.trim());
      // documentVersionProvider is already watched at the top of build(),
      // so bumping it here refreshes the list instead of relying on a
      // manual setState after the async gap above.
      ref.read(documentVersionProvider.notifier).state++;
    }
  }

  Future<void> _exportDocument(ScanDocument doc) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ExportScreen(document: doc)),
    );
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
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Document deleted')),
        );
      }
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
      if (mounted) {
        setState(() {
          _selectedDocumentIds.clear();
          _selectionMode = false;
        });
      }
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
    final isDarkMode = ref.watch(darkModeProvider);
    final storage = ref.read(storageProvider);
    final docs = storage.listDocuments();
    final scheme = Theme.of(context).colorScheme;

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
                    ? Icons.deselect_rounded
                    : Icons.select_all_rounded,
              ),
              tooltip: _selectedDocumentIds.length == docs.length
                  ? 'Clear selection'
                  : 'Select all',
            ),
            IconButton(
              onPressed: _selectedDocumentIds.isEmpty
                  ? null
                  : () => _exportSelected(docs),
              icon: const Icon(Icons.ios_share_rounded),
              tooltip: 'Export selected',
            ),
            IconButton(
              onPressed: _selectedDocumentIds.isEmpty
                  ? null
                  : () => _deleteSelected(docs),
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: 'Delete selected',
            ),
            IconButton(
              onPressed: () => setState(() {
                _selectedDocumentIds.clear();
                _selectionMode = false;
              }),
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Exit selection',
            ),
          ] else ...[
            if (docs.isNotEmpty)
              IconButton(
                onPressed: () => setState(() => _selectionMode = true),
                icon: const Icon(Icons.checklist_rounded),
                tooltip: 'Select documents',
              ),
          ],
          // Permanent Popup Menu
          PopupMenuButton<_MenuAction>(
            icon: const Icon(Icons.more_vert_rounded),
            tooltip: 'More options',
            onSelected: (action) {
              switch (action) {
                case _MenuAction.toggleTheme:
                  ref.read(darkModeProvider.notifier).state = !isDarkMode;
                  break;
                case _MenuAction.tips:
                  _showTipsDialog();
                  break;
                case _MenuAction.versionInfo:
                  // No-op: this row is enabled: false below (informational
                  // only), so it's never actually selectable — kept here
                  // only so the switch stays exhaustive.
                  break;
                case _MenuAction.developerInfo:
                  _showDeveloperDialog();
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _MenuAction.toggleTheme,
                child: Row(
                  children: [
                    Icon(
                      isDarkMode
                          ? Icons.dark_mode_rounded
                          : Icons.light_mode_rounded,
                    ),
                    const SizedBox(width: 12),
                    Text(isDarkMode ? 'Dark Mode (On)' : 'Dark Mode (Off)'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: _MenuAction.tips,
                child: Row(
                  children: [
                    Icon(Icons.tips_and_updates_rounded),
                    SizedBox(width: 12),
                    Text('Tips for better scanning'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: _MenuAction.versionInfo,
                enabled: false,
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded),
                    const SizedBox(width: 12),
                    Text(
                      // No hardcoded fallback number — package_info_plus
                      // already reads the version straight from what
                      // Flutter's build baked in from pubspec.yaml's
                      // `version:` line, so bumping it there is the only
                      // place this ever needs to change.
                      _packageInfo == null
                          ? 'Version …'
                          : 'Version ${_packageInfo!.version}'
                              '${_packageInfo!.buildNumber.isNotEmpty ? ' (${_packageInfo!.buildNumber})' : ''}',
                    ),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: _MenuAction.developerInfo,
                child: Row(
                  children: [
                    Icon(Icons.code_rounded),
                    SizedBox(width: 12),
                    Text('Developer Info'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: docs.isEmpty
          ? Stack(
              children: [
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.document_scanner_outlined,
                          size: 56,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No scans yet.\nTap Document or Book below to scan your first one.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  bottom: 160,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        'Tips: Please use a contrasting background for best result.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant
                                  .withValues(alpha: 0.8),
                              fontStyle: FontStyle.italic,
                            ),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : ListView.builder(
              padding: EdgeInsets.fromLTRB(
                12,
                12,
                12,
                88 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              itemCount: docs.length,
              itemBuilder: (context, index) {
                final doc = docs[index];
                final pages = storage.pagesFor(doc);
                final pageCount = pages.length;
                final isBookDoc = pages.isNotEmpty &&
                    pages.first.sourceMode != PageSourceMode.document;
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  elevation: 0,
                  color: scheme.surfaceContainerLow,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
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
                        : _DocumentThumbnail(
                            page: pages.isNotEmpty ? pages.first : null,
                            isBookDoc: isBookDoc,
                            scheme: scheme,
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
                            if (mounted) setState(() {});
                          },
                    trailing: _selectionMode
                        ? null
                        : PopupMenuButton<_DocAction>(
                            icon: const Icon(Icons.more_vert_rounded),
                            tooltip: 'Document options',
                            onSelected: (action) {
                              switch (action) {
                                case _DocAction.rename:
                                  _renameDocument(doc);
                                  break;
                                case _DocAction.export:
                                  _exportDocument(doc);
                                  break;
                                case _DocAction.delete:
                                  _deleteDocument(doc);
                                  break;
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: _DocAction.rename,
                                child: Row(
                                  children: [
                                    Icon(Icons.edit_outlined, size: 20),
                                    SizedBox(width: 12),
                                    Text('Rename'),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: _DocAction.export,
                                child: Row(
                                  children: [
                                    Icon(Icons.ios_share_rounded, size: 20),
                                    SizedBox(width: 12),
                                    Text('Export'),
                                  ],
                                ),
                              ),
                              PopupMenuDivider(),
                              PopupMenuItem(
                                value: _DocAction.delete,
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.delete_outline_rounded,
                                      size: 20,
                                      color: Colors.red,
                                    ),
                                    SizedBox(width: 12),
                                    Text(
                                      'Delete',
                                      style: TextStyle(color: Colors.red),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                  ),
                );
              },
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            heroTag: 'scan_book',
            onPressed: _newBookScan,
            icon: const Icon(Icons.menu_book_rounded),
            label: const Text('Book'),
          ),
          const SizedBox(width: 16),
          FloatingActionButton.extended(
            heroTag: 'scan_document',
            onPressed: () => _newScan(ScanKind.document),
            icon: const Icon(Icons.add_a_photo_rounded),
            label: const Text('Document'),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _showTipsDialog() async {
    const tips = <(IconData, String, String)>[
      (
        Icons.lightbulb_outline_rounded,
        'Lighting',
        'Use even, diffuse light. Avoid direct glare on the page.',
      ),
      (
        Icons.crop_square_rounded,
        'Hold steady',
        'Frame the page fully and hold the device parallel to it.',
      ),
      (
        Icons.contrast_rounded,
        'High contrast',
        'Black ink on white paper gives the cleanest scans and best B&W.',
      ),
      (
        Icons.palette_rounded,
        'Pick the right mode',
        'Use Color for photos/colour pages, B&W for text, Grayscale for both.',
      ),
      (
        Icons.cleaning_services_rounded,
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
                    Icon(icon,
                        size: 20, color: Theme.of(context).colorScheme.primary),
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
              'Free, Offline Document & Book Scanner. No Accounts, '
              'No Cloud, No Watermarks, No Third-party tracking.',
            ),
            SizedBox(height: 8),
            Text('Concept, Design and Development:, '
                'Mridul Kumar Sharmah.'),
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

/// Small rounded thumbnail for a document's list row — shows the first
/// page's image (with its stored rotation applied) when one exists, and a
/// tinted document/book icon otherwise. A small circular badge in the
/// corner distinguishes Book scans from single Document scans at a glance.
class _DocumentThumbnail extends StatelessWidget {
  final ScanPage? page;
  final bool isBookDoc;
  final ColorScheme scheme;

  const _DocumentThumbnail({
    required this.page,
    required this.isBookDoc,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final typeIcon =
        isBookDoc ? Icons.menu_book_rounded : Icons.description_rounded;
    final badgeColor =
        isBookDoc ? scheme.tertiaryContainer : scheme.primaryContainer;
    final onBadgeColor =
        isBookDoc ? scheme.onTertiaryContainer : scheme.onPrimaryContainer;

    return SizedBox(
      width: 48,
      height: 60,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: page != null
                ? RotatedBox(
                    quarterTurns: page!.rotation ~/ 90,
                    child: Image.file(
                      File(page!.imagePath),
                      width: 48,
                      height: 60,
                      fit: BoxFit.cover,
                    ),
                  )
                : Container(
                    width: 48,
                    height: 60,
                    color: badgeColor,
                    alignment: Alignment.center,
                    child: Icon(typeIcon, color: onBadgeColor, size: 22),
                  ),
          ),
          if (page != null)
            Positioned(
              right: -4,
              bottom: -4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: badgeColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 2),
                ),
                child: Icon(typeIcon, size: 11, color: onBadgeColor),
              ),
            ),
        ],
      ),
    );
  }
}

/// Rename dialog with its own, self-owned [TextEditingController].
///
/// Creating and disposing the controller from inside this widget's own
/// State lifecycle (initState/dispose) — rather than from the caller,
/// after awaiting showDialog() — is what actually fixes the
/// '_dependents.isEmpty' crash: Flutter guarantees a State's dispose()
/// runs in the correct order relative to its own Element's teardown
/// (including the TextField's Focus node), so there's no window where
/// the controller can be disposed while something still depends on it.
class _RenameDialog extends StatefulWidget {
  final String initialName;

  const _RenameDialog({required this.initialName});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename document'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Document name'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
