import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'storage/storage_service.dart';
import '../models/document.dart';

final storageProvider = Provider<StorageService>((ref) {
  return StorageService.instance;
});

/// The document currently being built/edited in the active session.
final activeDocumentProvider = StateProvider<ScanDocument?>((ref) => null);

/// Bumped whenever pages change, so widgets watching a document's page
/// list know to re-read from Hive (Hive objects are mutable, not
/// immutable state, so we pair them with a simple version counter).
final documentVersionProvider = StateProvider<int>((ref) => 0);

/// State for whether the app is in dark mode.
/// Persisted across sessions via Hive when StorageService initialises,
/// but we keep it simple here with a Provider that defaults to false (light).
final darkModeProvider = StateProvider<bool>((ref) => false);
