import 'dart:io';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../models/document.dart';
import '../../models/page.dart';

/// Everything lives under
/// getApplicationDocumentsDirectory()/lachit_scanner/<doc_id>/<page_id>.jpg
///
/// No network permissions are ever requested by this app.
class StorageService {
  StorageService._();
  static final StorageService instance = StorageService._();

  static const _documentsBoxName = 'documents';
  static const _pagesBoxName = 'pages';

  late Box<ScanDocument> documentsBox;
  late Box<ScanPage> pagesBox;

  Directory? _rootDir;
  final _uuid = const Uuid();

  Future<void> init() async {
    await Hive.initFlutter();
    Hive.registerAdapter(ScanDocumentAdapter());
    Hive.registerAdapter(ScanPageAdapter());

    documentsBox = await Hive.openBox<ScanDocument>(_documentsBoxName);
    pagesBox = await Hive.openBox<ScanPage>(_pagesBoxName);

    final appDir = await getApplicationDocumentsDirectory();
    _rootDir = Directory('${appDir.path}/lachit_scanner');
    if (!await _rootDir!.exists()) {
      await _rootDir!.create(recursive: true);
    }
  }

  Directory get rootDir {
    if (_rootDir == null) {
      throw StateError('StorageService.init() must be called before use.');
    }
    return _rootDir!;
  }

  Future<Directory> documentDir(String documentId) async {
    final dir = Directory('${rootDir.path}/$documentId');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String newId() => _uuid.v4();

  // ---- Document CRUD ----

  Future<ScanDocument> createDocument({String? name}) async {
    final id = newId();
    final doc = ScanDocument(id: id, name: name ?? _defaultDocName());
    await documentsBox.put(id, doc);
    await documentDir(id); // ensure folder exists
    return doc;
  }

  String _defaultDocName() {
    final now = DateTime.now();
    return 'Scan ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
  }

  List<ScanDocument> listDocuments() {
    final docs = documentsBox.values.toList();
    docs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return docs;
  }

  Future<void> renameDocument(ScanDocument doc, String newName) async {
    doc.name = newName;
    doc.updatedAt = DateTime.now();
    await doc.save();
  }

  Future<void> deleteDocument(ScanDocument doc) async {
    for (final pageId in List<String>.from(doc.pageIds)) {
      final page = pagesBox.get(pageId);
      if (page != null) {
        await _deletePageFile(page);
        await page.delete();
      }
    }
    final dir = await documentDir(doc.id);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await doc.delete();
  }

  // ---- Page CRUD ----

  /// Registers a page whose processed image already exists on disk at
  /// [imagePath] (inside this document's folder), appending it to the end.
  Future<ScanPage> addPage(
    ScanDocument doc, {
    required String imagePath,
    PageSourceMode sourceMode = PageSourceMode.document,
    ColorMode colorMode = ColorMode.bw,
  }) async {
    final id = newId();
    final page = ScanPage(
      id: id,
      order: doc.pageIds.length,
      imagePath: imagePath,
      sourceModeIndex: sourceMode.index,
      colorModeIndex: colorMode.index,
    );
    await pagesBox.put(id, page);
    doc.pageIds.add(id);
    doc.updatedAt = DateTime.now();
    await doc.save();
    return page;
  }

  List<ScanPage> pagesFor(ScanDocument doc) {
    final pages = doc.pageIds
        .map((id) => pagesBox.get(id))
        .whereType<ScanPage>()
        .toList();
    pages.sort((a, b) => a.order.compareTo(b.order));
    return pages;
  }

  Future<void> reorderPages(
    ScanDocument doc,
    List<String> newPageIdOrder,
  ) async {
    for (var i = 0; i < newPageIdOrder.length; i++) {
      final page = pagesBox.get(newPageIdOrder[i]);
      if (page != null) {
        page.order = i;
        await page.save();
      }
    }
    doc.pageIds = newPageIdOrder;
    doc.updatedAt = DateTime.now();
    await doc.save();
  }

  Future<void> rotatePage(ScanPage page, {required bool clockwise}) async {
    final delta = clockwise ? 90 : -90;
    page.rotation = (page.rotation + delta + 360) % 360;
    await page.save();
  }

  /// Replaces the image file for an existing page (used by "Retake"),
  /// keeping the same page id / order / rotation metadata.
  Future<void> replacePageImage(ScanPage page, String newImagePath) async {
    await _deletePageFile(page);
    page.imagePath = newImagePath;
    page.rotation = 0;
    await page.save();
  }

  Future<void> deletePage(ScanDocument doc, ScanPage page) async {
    await _deletePageFile(page);
    doc.pageIds.remove(page.id);
    await page.delete();
    // re-sequence order values
    final remaining = pagesFor(doc);
    for (var i = 0; i < remaining.length; i++) {
      remaining[i].order = i;
      await remaining[i].save();
    }
    doc.updatedAt = DateTime.now();
    await doc.save();
  }

  Future<void> _deletePageFile(ScanPage page) async {
    final f = File(page.imagePath);
    if (await f.exists()) {
      await f.delete();
    }
  }
}
