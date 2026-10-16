// Core domain models and the engine abstraction for Open Video Editor.
//
// The architecture mirrors the classic split found in mobile video editors:
// a native media engine (decode / filter / encode) behind a Dart interface,
// with the UI layer (timeline, preview, transport) written in Flutter.
// This file contains only the portable contract — no platform code.

/// A media file that can be placed on the timeline.
class MediaSource {
  const MediaSource({
    required this.id,
    required this.path,
    required this.duration,
    this.hasVideo = true,
    this.hasAudio = true,
  });

  final String id;
  final String path;
  final Duration duration;
  final bool hasVideo;
  final bool hasAudio;
}

/// A segment of a [MediaSource] placed on a track.
///
/// [sourceStart] is the trim offset inside the source file;
/// [timelineStart] is where the clip begins on the timeline.
class Clip {
  const Clip({
    required this.id,
    required this.source,
    required this.timelineStart,
    required this.sourceStart,
    required this.duration,
  });

  final String id;
  final MediaSource source;
  final Duration timelineStart;
  final Duration sourceStart;
  final Duration duration;

  Duration get timelineEnd => timelineStart + duration;
}

/// One horizontal lane on the timeline holding an ordered list of clips.
class VideoTrack {
  const VideoTrack({required this.id, this.clips = const []});

  final String id;
  final List<Clip> clips;
}

/// A text caption shown over the video between [start] and [end].
class TextOverlay {
  const TextOverlay({
    required this.id,
    required this.text,
    required this.start,
    required this.end,
    this.fontSize = 32,
  });

  final String id;
  final String text;
  final Duration start;
  final Duration end;
  final double fontSize;
}

/// The editable document: tracks of clips plus overlays.
class TimelineProject {
  const TimelineProject({
    this.tracks = const [],
    this.overlays = const [],
  });

  final List<VideoTrack> tracks;
  final List<TextOverlay> overlays;

  /// Total duration = end of the last clip on any track.
  Duration get duration {
    var end = Duration.zero;
    for (final track in tracks) {
      for (final clip in track.clips) {
        if (clip.timelineEnd > end) end = clip.timelineEnd;
      }
    }
    return end;
  }
}

/// Settings for rendering a project to a video file.
class ExportConfig {
  const ExportConfig({
    required this.outputPath,
    this.width = 1080,
    this.height = 1920,
    this.fps = 30,
    this.videoBitrate = 8 * 1000 * 1000,
  });

  final String outputPath;
  final int width;
  final int height;
  final int fps;
  final int videoBitrate;
}

/// What the active engine implementation can do.
class EngineCapabilities {
  const EngineCapabilities({
    this.maxVideoTracks = 8,
    this.supportsHardwareAcceleration = false,
    this.supportedExportFormats = const ['mp4'],
  });

  final int maxVideoTracks;
  final bool supportsHardwareAcceleration;
  final List<String> supportedExportFormats;
}

/// Portable contract for the native media engine.
///
/// Implementations (e.g. FFmpeg-based) live behind this interface so the
/// UI never depends on platform specifics. All methods are async because
/// engine work crosses an FFI / platform-channel boundary.
abstract class VideoEngine {
  EngineCapabilities get capabilities;

  /// Prepare the engine. Must be called before any other method.
  Future<void> initialize();

  /// Load a project for preview playback.
  Future<void> loadProject(TimelineProject project);

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// Emits the current playback position while playing.
  Stream<Duration> get positionStream;

  /// Render [project] to a file. Calls [onProgress] with 0.0–1.0.
  Future<void> exportProject(
    TimelineProject project,
    ExportConfig config, {
    void Function(double progress)? onProgress,
  });

  Future<void> dispose();
}
