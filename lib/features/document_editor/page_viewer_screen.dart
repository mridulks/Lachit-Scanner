// Full-screen page viewer — tapping a page in the document editor now
// opens this instead of doing nothing. Pinch/double-tap to zoom via
// InteractiveViewer; rotation metadata is applied the same way the
// editor's thumbnail and export both already do.

import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/page.dart';

class PageViewerScreen extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('Page ${index + 1} of $total'),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          child: RotatedBox(
            quarterTurns: page.rotation ~/ 90,
            child: Image.file(File(page.imagePath)),
          ),
        ),
      ),
    );
  }
}
