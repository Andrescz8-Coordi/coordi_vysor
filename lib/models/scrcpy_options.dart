class ScrcpyOptions {
  // Video
  final int? maxSize; // --max-size (0 = no limit)
  final int? bitrateMbps; // --video-bit-rate (Mbps)
  final int? maxFps; // --max-fps
  final String? videoCodec; // --video-codec (h264, h265, av1)

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
  final bool compress; // re-encode with ffmpeg after recording
  final int compressCrf; // CRF for h265 (0-51, lower=better, 28=good)

  const ScrcpyOptions({
    this.maxSize,
    this.bitrateMbps,
    this.maxFps,
    this.videoCodec,
    this.fullscreen = false,
    this.borderless = false,
    this.alwaysOnTop = false,
    this.turnScreenOff = false,
    this.stayAwake = false,
    this.noAudio = false,
    this.noControl = false,
    this.record = false,
    this.recordPath,
    this.compress = true,
    this.compressCrf = 28,
  });

  ScrcpyOptions copyWith({
    int? maxSize,
    int? bitrateMbps,
    int? maxFps,
    String? videoCodec,
    bool? fullscreen,
    bool? borderless,
    bool? alwaysOnTop,
    bool? turnScreenOff,
    bool? stayAwake,
    bool? noAudio,
    bool? noControl,
    bool? record,
    String? recordPath,
    bool? compress,
    int? compressCrf,
  }) {
    return ScrcpyOptions(
      maxSize: maxSize ?? this.maxSize,
      bitrateMbps: bitrateMbps ?? this.bitrateMbps,
      maxFps: maxFps ?? this.maxFps,
      videoCodec: videoCodec ?? this.videoCodec,
      fullscreen: fullscreen ?? this.fullscreen,
      borderless: borderless ?? this.borderless,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      turnScreenOff: turnScreenOff ?? this.turnScreenOff,
      stayAwake: stayAwake ?? this.stayAwake,
      noAudio: noAudio ?? this.noAudio,
      noControl: noControl ?? this.noControl,
      record: record ?? this.record,
      recordPath: recordPath ?? this.recordPath,
      compress: compress ?? this.compress,
      compressCrf: compressCrf ?? this.compressCrf,
    );
  }

  Map<String, dynamic> toJson() => {
        'maxSize': maxSize,
        'bitrateMbps': bitrateMbps,
        'maxFps': maxFps,
        'videoCodec': videoCodec,
        'fullscreen': fullscreen,
        'borderless': borderless,
        'alwaysOnTop': alwaysOnTop,
        'turnScreenOff': turnScreenOff,
        'stayAwake': stayAwake,
        'noAudio': noAudio,
        'noControl': noControl,
        'compress': compress,
        'compressCrf': compressCrf,
      };

  factory ScrcpyOptions.fromJson(Map<String, dynamic> json) => ScrcpyOptions(
        maxSize: json['maxSize'] as int?,
        bitrateMbps: json['bitrateMbps'] as int?,
        maxFps: json['maxFps'] as int?,
        videoCodec: json['videoCodec'] as String?,
        fullscreen: json['fullscreen'] as bool? ?? false,
        borderless: json['borderless'] as bool? ?? false,
        alwaysOnTop: json['alwaysOnTop'] as bool? ?? false,
        turnScreenOff: json['turnScreenOff'] as bool? ?? false,
        stayAwake: json['stayAwake'] as bool? ?? false,
        noAudio: json['noAudio'] as bool? ?? false,
        noControl: json['noControl'] as bool? ?? false,
        compress: json['compress'] as bool? ?? true,
        compressCrf: json['compressCrf'] as int? ?? 28,
      );

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
    if (videoCodec != null && videoCodec!.isNotEmpty) {
      args.addAll(['--video-codec', videoCodec!]);
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
