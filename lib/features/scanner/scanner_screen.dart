// Scanner screen: live camera preview, tap-to-capture, then run static
// (single-shot) edge detection on the captured frame before handing off
// to the corner-adjust screen. Live-frame-stream auto-capture is Phase 2
// (design doc §3 "stability check") — deliberately not here yet.
//
// Shared by both Document and Book Mode (design doc §1's core decision:
// one custom CV pipeline for both) — [scanKind] only changes the framing
// guide shape/hint text here, and which downstream pipeline
// CornerAdjustScreen runs after confirm.

import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../core/scan_kind.dart';
import '../corner_adjust/corner_adjust_screen.dart';

class ScannerScreen extends StatefulWidget {
  final ScanKind scanKind;
  final BookScanMode bookScanMode;

  /// If provided, the captured page is added to this existing document;
  /// otherwise the caller creates a new document once the first page is
  /// confirmed (kept simple for Phase 1 — one document per scan session).
  const ScannerScreen({
    super.key,
    this.scanKind = ScanKind.document,
    this.bookScanMode = BookScanMode.twoPage,
  });

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  CameraController? _controller;
  Future<void>? _initFuture;
  bool _capturing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      _controller = CameraController(
        back,
        ResolutionPreset.veryHigh, // full-res needed at capture time
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      _initFuture = _controller!.initialize();
      await _initFuture;
      if (mounted) setState(() {});
    } catch (e) {
      setState(() => _error = 'Camera unavailable: $e');
    }
  }

  Future<void> _capture() async {
    if (_controller == null || _capturing) return;
    setState(() => _capturing = true);
    try {
      final file = await _controller!.takePicture();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CornerAdjustScreen(
            capturedImagePath: file.path,
            scanKind: widget.scanKind,
            bookScanMode: widget.bookScanMode,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Capture failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isBook = widget.scanKind == ScanKind.book;

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(isBook ? 'Scan book' : 'Scan')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!, textAlign: TextAlign.center),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snapshot) {
          if (_controller == null ||
              snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              CameraPreview(_controller!),
              // Simple framing guide — real-time quad overlay arrives in
              // Phase 2 alongside the frame-stream detector. Book Mode
              // gets a wider box, matching an open spread's aspect ratio.
              Center(
                child: FractionallySizedBox(
                  widthFactor: isBook ? 0.92 : 0.85,
                  heightFactor: isBook ? 0.55 : 0.7,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.6),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
              if (isBook)
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Text(
                            'For best results, place the open book on a\n'
                            'plain, contrasting surface',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              SafeArea(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 32),
                    child: GestureDetector(
                      onTap: _capturing ? null : _capture,
                      child: Container(
                        width: 74,
                        height: 74,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.4),
                            width: 4,
                          ),
                        ),
                        child: _capturing
                            ? const Padding(
                                padding: EdgeInsets.all(20),
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Utility used by later screens to load the raw bytes of a just-captured
/// frame for CV processing.
Future<List<int>> readCapturedBytes(String path) => File(path).readAsBytes();
