# Lachit Scanner — Phase 1

Free, offline, no-watermark document scanner. Phase 1 scope (per the design
doc, §8): camera preview → static edge detection + manual corner adjust →
perspective warp → Color/Grayscale/B&W → save as a local document →
single- or multi-page PDF/JPEG export. No Book Mode yet (that's Phase 4).

## Getting this running on your machine

This code was written in a sandbox with **no network access to pub.dev**,
so nothing here has been `pub get`'d, compiled, or run. Before you start:

```bash
flutter create --org com.yourname lachit_scanner
# then copy lib/ and pubspec.yaml from this project into it, replacing
# the generated ones, OR just `flutter create .` in this folder to
# generate the android/ and ios/ platform folders around the existing lib/.
flutter pub get
```

### Things most likely to need a small fix on first `pub get` / `flutter run`

1. **`opencv_dart` API surface** (`lib/core/cv/edge_detector.dart`,
   `lib/core/cv/warp.dart`). This package's method names/signatures shift
   between versions faster than most Flutter packages. The *algorithm* is
   correct and matches the design doc exactly — if a call doesn't compile,
   check `opencv_dart`'s example app (in your pub cache after `pub get`,
   or on its GitHub) for the current exact syntax for `findContours`,
   `approxPolyDP`, `getPerspectiveTransform`, and `CLAHE` in the version
   that resolves. These are typically 1:1 renames, not logic changes.
2. **Hive adapters are hand-written**, not `build_runner`-generated
   (`lib/models/page.g.dart`, `lib/models/document.g.dart`), since
   build_runner needs pub.dev too. They're correct for the current model
   shape. If you add/remove a `@HiveField`, either run
   `dart run build_runner build --delete-conflicting-outputs` yourself, or
   hand-edit the `.g.dart` file the same way — it's a small, boring format.
3. **Retake is a known Phase 1 gap.** `DocumentEditorScreen._retake()`
   expects `ScannerScreen` to pop with a captured file path, but
   `ScannerScreen` currently always pushes forward into `CornerAdjustScreen`
   and creates/appends a new page. Wire this up by giving `ScannerScreen`
   an optional `replacePageId` param that, on confirm, calls
   `StorageService.replacePageImage()` instead of `addPage()`. Left as a
   follow-up rather than guessed at, since it's a UX decision (should
   retake re-run corner adjust too? almost certainly yes) worth you
   confirming.

## Required platform permissions

**Android** — add to `android/app/src/main/AndroidManifest.xml`, inside `<manifest>`:
```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-feature android:name="android.hardware.camera" android:required="true" />
```
No `INTERNET` permission — deliberately never requested (design doc §5).

**iOS** — add to `ios/Runner/Info.plist`:
```xml
<key>NSCameraUsageDescription</key>
<string>Lachit Scanner needs the camera to scan documents.</string>
```

## What's deliberately NOT in Phase 1

- Live frame-stream auto-capture (Phase 2) — capture is currently manual
  tap-to-shoot, then single-shot detection on the still.
- Book Mode / gutter detection (Phase 4).
- Reorder/rotate/retake polish beyond the basics wired here (Phase 3 hardens
  these; the plumbing already exists in `StorageService`).
- OCR (Phase 6, stretch, offline-only if added at all per the design doc).

## Project layout

Matches the design doc's §7 structure exactly:

```
lib/
 ├─ core/{cv,storage,export}/
 ├─ features/{scanner,corner_adjust,document_editor,export,home}/
 ├─ models/
 └─ main.dart
```
