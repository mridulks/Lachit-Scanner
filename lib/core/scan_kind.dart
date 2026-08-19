/// Which pipeline a capture session should run through.
/// Document: single-page detect -> adjust -> warp -> enhance -> save.
/// Book: whole-spread detect -> adjust -> warp -> gutter split ->
///       per-page re-warp -> enhance -> save two pages (design doc §4).
enum ScanKind { document, book }
