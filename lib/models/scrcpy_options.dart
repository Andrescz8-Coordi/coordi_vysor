class ScrcpyOptions {
  // Video
  final int? maxSize; // --max-size (0 = no limit)
  final int? bitrateMbps; // --video-bit-rate (Mbps)
  final int? maxFps; // --max-fps

  // Window
  final bool fullscreen; // -f
  final bool borderless; // --window-borderless
  final bool alwaysOnTop; // --always-on-top

  // Behaviour
  final bool turnScreenOff; // -S
  final bool stayAwake; // -w
  final bool noAudio; // --no-audio
  final bool noControl; // -n (view only)

  // Recording
  final bool record; // --record
  final String? recordPath; // file path

  const ScrcpyOptions({
    this.maxSize,
    this.bitrateMbps,
    this.maxFps,
    this.fullscreen = false,
    this.borderless = false,
    this.alwaysOnTop = false,
    this.turnScreenOff = false,
    this.stayAwake = false,
    this.noAudio = false,
    this.noControl = false,
    this.record = false,
    this.recordPath,
  });

  ScrcpyOptions copyWith({
    int? maxSize,
    int? bitrateMbps,
    int? maxFps,
    bool? fullscreen,
    bool? borderless,
    bool? alwaysOnTop,
    bool? turnScreenOff,
    bool? stayAwake,
    bool? noAudio,
    bool? noControl,
    bool? record,
    String? recordPath,
  }) {
    return ScrcpyOptions(
      maxSize: maxSize ?? this.maxSize,
      bitrateMbps: bitrateMbps ?? this.bitrateMbps,
      maxFps: maxFps ?? this.maxFps,
      fullscreen: fullscreen ?? this.fullscreen,
      borderless: borderless ?? this.borderless,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      turnScreenOff: turnScreenOff ?? this.turnScreenOff,
      stayAwake: stayAwake ?? this.stayAwake,
      noAudio: noAudio ?? this.noAudio,
      noControl: noControl ?? this.noControl,
      record: record ?? this.record,
      recordPath: recordPath ?? this.recordPath,
    );
  }

  /// Build scrcpy CLI args for a given device serial.
  List<String> toArgs(String serial) {
    final args = <String>['--serial', serial];

    if (maxSize != null && maxSize! > 0) {
      args.addAll(['--max-size', '$maxSize']);
    }
    if (bitrateMbps != null && bitrateMbps! > 0) {
      args.addAll(['--video-bit-rate', '${bitrateMbps}M']);
    }
    if (maxFps != null && maxFps! > 0) {
      args.addAll(['--max-fps', '$maxFps']);
    }
    if (fullscreen) args.add('--fullscreen');
    if (borderless) args.add('--window-borderless');
    if (alwaysOnTop) args.add('--always-on-top');
    if (turnScreenOff) args.add('--turn-screen-off');
    if (stayAwake) args.add('--stay-awake');
    if (noAudio) args.add('--no-audio');
    if (noControl) args.add('--no-control');
    if (record && recordPath != null && recordPath!.isNotEmpty) {
      args.addAll(['--record', recordPath!]);
    }

    return args;
  }
}
