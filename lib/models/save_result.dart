/// Outcome of finishing a recording: where the file ended up, or why it didn't.
///
/// Every stop-recording path returns one of these so the UI can always tell the
/// user something concrete instead of failing silently.
class SaveResult {
  const SaveResult.saved(this.path)
      : error = null,
        details = null;

  const SaveResult.failed(this.error, {this.details}) : path = null;

  /// Final path of the video on disk, when it was saved.
  final String? path;

  /// Short, user-facing reason the recording could not be saved.
  final String? error;

  /// Raw log (ffmpeg/scrcpy output) to show on demand.
  final String? details;

  bool get ok => path != null;
}
