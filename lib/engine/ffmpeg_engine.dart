// FFmpeg-backed implementation of [VideoEngine].
//
// Export is real: [buildExportCommand] translates the [TimelineProject]
// into an ffmpeg CLI invocation (trim/concat per clip, color filters,
// fades, drawtext overlays, libx264+aac encode) and an [FFmpegRunner]
// executes it. Preview playback is still driven by video_player in the UI
// layer (see lib/playback/timeline_player.dart).

import 'dart:async';

import 'ffmpeg_command.dart';
import 'ffmpeg_runner.dart';
import 'video_engine.dart';

class FfmpegVideoEngine implements VideoEngine {
  FfmpegVideoEngine({
    FFmpegRunner? runner,
    this.fontFile,
    this.fontFileProvider,
    void Function(double)? onWasmLoadProgress,
  }) : _runner = runner ??
            createDefaultRunner(onWasmLoadProgress: onWasmLoadProgress);

  final FFmpegRunner _runner;

  /// Typeface used for drawtext overlays, if any.
  final String? fontFile;

  /// Lazy font resolver (e.g. copy a bundled font to a temp file on mobile,
  /// or a MEMFS name on web). Used when [fontFile] is null.
  final Future<String?> Function()? fontFileProvider;

  final _positionController = StreamController<Duration>.broadcast();
  bool _initialized = false;
  TimelineProject? _project;

  @override
  EngineCapabilities get capabilities => const EngineCapabilities(
        maxVideoTracks: 8,
        supportsHardwareAcceleration: false,
        supportedExportFormats: ['mp4'],
      );

  @override
  Future<void> initialize() async {
    // TODO: load native FFmpeg libraries / create engine context.
    _initialized = true;
  }

  void _requireInitialized() {
    if (!_initialized) {
      throw StateError('FfmpegVideoEngine.initialize() must be called first');
    }
  }

  @override
  Future<void> loadProject(TimelineProject project) async {
    _requireInitialized();
    // TODO: build the internal render graph from the project.
    _project = project;
  }

  @override
  Future<void> play() async {
    _requireInitialized();
    if (_project == null) throw StateError('No project loaded');
    // TODO: start decode + clock; emit positions on _positionController.
    throw UnimplementedError('Preview playback not wired to FFmpeg yet');
  }

  @override
  Future<void> pause() async {
    _requireInitialized();
    // TODO: pause the decode clock.
  }

  @override
  Future<void> seek(Duration position) async {
    _requireInitialized();
    // TODO: seek decoders; emit the new position.
    _positionController.add(position);
  }

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Future<void> exportProject(
    TimelineProject project,
    ExportConfig config, {
    void Function(double progress)? onProgress,
  }) async {
    _requireInitialized();
    final font = fontFile ?? await fontFileProvider?.call();
    final args = buildExportCommand(project, config, fontFile: font);
    final code = await _runner.run(
      args,
      total: project.duration,
      onProgress: onProgress,
    );
    if (code != 0) {
      throw Exception('FFmpeg export failed with exit code $code');
    }
  }

  @override
  Future<void> dispose() async {
    await _positionController.close();
  }
}
