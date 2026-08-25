// Full-screen page viewer. Doubles as the "confirm my rotation" view:
// rotate controls live in the app bar here too, so tapping rotate from the
// document editor's page list can drop the user straight into a full-size
// check of the result — the same "open a view, see the effect" pattern
// Enhance and Crop already use — instead of leaving them to judge a rotate
// from a thumbnail alone.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../models/page.dart';

class PageViewerScreen extends ConsumerStatefulWidget {
  final ScanPage page;
  final int index;
  final int total;

  const PageViewerScreen({
    super.key,
    required this.page,
    required this.index,
    required this.total,
  });

  @override
  ConsumerState<PageViewerScreen> createState() => _PageViewerScreenState();
}

class _PageViewerScreenState extends ConsumerState<PageViewerScreen> {
  bool _rotating = false;

  Future<void> _rotate({required bool clockwise}) async {
    if (_rotating) return;
    setState(() => _rotating = true);
    try {
      final storage = ref.read(storageProvider);
      await storage.rotatePage(widget.page, clockwise: clockwise);
      // The document editor list watches this provider, so it picks up
      // the new rotation on its thumbnail/state as soon as it's next
      // visible — no need to thread a bool back through Navigator.pop.
      ref.read(documentVersionProvider.notifier).state++;
    } finally {
      if (mounted) setState(() => _rotating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('Page ${widget.index + 1} of ${widget.total}'),
        actions: [
          IconButton(
            onPressed: _rotating ? null : () => _rotate(clockwise: false),
            icon: const Icon(Icons.rotate_left_rounded),
            tooltip: 'Rotate left',
          ),
          IconButton(
            onPressed: _rotating ? null : () => _rotate(clockwise: true),
            icon: const Icon(Icons.rotate_right_rounded),
            tooltip: 'Rotate right',
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          // Keyed on rotation so InteractiveViewer/RotatedBox actually
          // rebuild their layout after an in-place Hive field mutation —
          // ScanPage is a HiveObject, not immutable state, so without a
          // key tied to the value, Flutter can consider this the "same"
          // widget and skip re-laying-out the rotation.
          key: ValueKey(widget.page.rotation),
          child: RotatedBox(
            quarterTurns: widget.page.rotation ~/ 90,
            child: Image.file(File(widget.page.imagePath)),
          ),
        ),
      ),
    );
  }
}