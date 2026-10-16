// FFmpeg-backed implementation of [VideoEngine].
//
// Currently a structural stub: it satisfies the interface so the UI can be
// built and tested, but every media operation throws [UnimplementedError].
//
// Integration plan (TODO):
//  1. Add `ffmpeg_kit_flutter` (mobile) for decode/filter/encode via FFmpeg.
//  2. For preview playback, drive a platform video player from the engine's
//     position stream and composite overlays in Flutter.
//  3. For export, translate the [TimelineProject] into an FFmpeg filter
//     graph (concat, trim, overlay, drawtext) and run it off the UI thread.
//  4. On web, swap this for an ffmpeg.wasm-based engine behind the same
//     [VideoEngine] interface.

import 'dart:async';

import 'video_engine.dart';

class FfmpegVideoEngine implements VideoEngine {
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
    // TODO: translate the project into an FFmpeg filter graph and run it,
    // reporting progress via onProgress.
    throw UnimplementedError('Export not wired to FFmpeg yet');
  }

  @override
  Future<void> dispose() async {
    await _positionController.close();
  }
}
