// Filmstrip thumbnails for timeline clips.
//
// Extracts small frames via the platform FFmpeg runner (desktop subprocess,
// mobile ffmpeg-kit) and caches them per clip geometry. Web has no frame
// extraction, so callers must handle a null result with a placeholder.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../engine/ffmpeg_runner.dart';
import '../engine/video_engine.dart';

class ThumbnailService {
  ThumbnailService({FFmpegRunner? runner, ChangeNotifier? invalidator})
      : _runner = runner ?? createDefaultRunner() {
    invalidator?.addListener(invalidate);
  }

  final FFmpegRunner _runner;
  final Map<String, Future<Uint8List?>> _cache = {};

  String _key(Clip clip, int index) =>
      '${clip.id}_${clip.source.path}_${clip.sourceStart.inMilliseconds}'
      '_${clip.duration.inMilliseconds}_${clip.speed}_$index';

  /// PNG bytes of the frame at fraction [t] (0..1) through the clip's
  /// media, or null when extraction is unavailable/failed.
  Future<Uint8List?> frameAt(Clip clip, double t) {
    final index = (t * 32).round();
    return _cache.putIfAbsent(_key(clip, index), () {
      final at = clip.sourceStart +
          Duration(
              milliseconds:
                  (clip.sourceDuration.inMilliseconds * t).round());
      return _runner.extractFrame(clip.source.path, at);
    });
  }

  void invalidate() => _cache.clear();
}
