// Core domain models and the engine abstraction for Open Video Editor.
//
// The architecture mirrors the classic split found in mobile video editors:
// a native media engine (decode / filter / encode) behind a Dart interface,
// with the UI layer (timeline, preview, transport) written in Flutter.
// This file contains only the portable contract — no platform code.

/// Color filter presets applied per clip.
///
/// Filters render live in the Flutter preview via [ColorFiltered]; the
/// FFmpeg export path translates them into filter-graph equivalents.
enum VideoFilter {
  none('None'),
  grayscale('B&W'),
  sepia('Sepia'),
  invert('Invert'),
  warm('Warm'),
  cool('Cool'),
  vintage('Vintage');

  const VideoFilter(this.label);

  final String label;

  /// 4x5 color matrix for [ColorFilter.matrix]. Identity for [none].
  List<double> get matrix {
    switch (this) {
      case VideoFilter.none:
        return const [
          1, 0, 0, 0, 0, //
          0, 1, 0, 0, 0, //
          0, 0, 1, 0, 0, //
          0, 0, 0, 1, 0,
        ];
      case VideoFilter.grayscale:
        return const [
          0.2126, 0.7152, 0.0722, 0, 0, //
          0.2126, 0.7152, 0.0722, 0, 0, //
          0.2126, 0.7152, 0.0722, 0, 0, //
          0, 0, 0, 1, 0,
        ];
      case VideoFilter.sepia:
        return const [
          0.393, 0.769, 0.189, 0, 0, //
          0.349, 0.686, 0.168, 0, 0, //
          0.272, 0.534, 0.131, 0, 0, //
          0, 0, 0, 1, 0,
        ];
      case VideoFilter.invert:
        return const [
          -1, 0, 0, 0, 255, //
          0, -1, 0, 0, 255, //
          0, 0, -1, 0, 255, //
          0, 0, 0, 1, 0,
        ];
      case VideoFilter.warm:
        return const [
          1.2, 0.1, 0, 0, 0, //
          0, 1.0, 0, 0, 0, //
          0, 0, 0.8, 0, 0, //
          0, 0, 0, 1, 0,
        ];
      case VideoFilter.cool:
        return const [
          0.8, 0, 0, 0, 0, //
          0, 1.0, 0.1, 0, 0, //
          0, 0, 1.2, 0, 0, //
          0, 0, 0, 1, 0,
        ];
      case VideoFilter.vintage:
        return const [
          0.9, 0.1, 0.1, 0, 20, //
          0.1, 0.9, 0.1, 0, 20, //
          0.1, 0.1, 0.9, 0, 20, //
          0, 0, 0, 1, 0,
        ];
    }
  }
}

/// Transition style for a clip boundary.
enum TransitionType {
  none,
  fade,
  /// Dissolve into the next clip (only meaningful on [Clip.transitionOut]
  /// when the next clip is timeline-contiguous). Export renders it with
  /// xfade/acrossfade; the preview shows a hard cut.
  crossfade,
}

/// Visual style of a [TransitionType.crossfade] boundary, mapped to
/// ffmpeg's xfade transition names.
enum XfadeKind {
  dissolve('fade', 'Dissolve'),
  wipeLeft('wipeleft', 'Wipe ←'),
  wipeRight('wiperight', 'Wipe →'),
  slideUp('slideup', 'Slide ↑'),
  slideDown('slidedown', 'Slide ↓'),
  circleOpen('circleopen', 'Circle');

  const XfadeKind(this.filterName, this.label);

  /// Name passed to `xfade=transition=`.
  final String filterName;

  /// Short label for the UI.
  final String label;
}

/// A transition applied at the start ([transitionIn]) or end
/// ([transitionOut]) of a clip. Preview renders fades as opacity ramps;
/// the FFmpeg export path will translate them into filter graphs.
class ClipTransition {
  const ClipTransition({
    this.type = TransitionType.none,
    this.duration = Duration.zero,
    this.xfadeKind = XfadeKind.dissolve,
  });

  final TransitionType type;
  final Duration duration;

  /// Only meaningful when [type] is [TransitionType.crossfade].
  final XfadeKind xfadeKind;

  bool get isEnabled => type != TransitionType.none && duration > Duration.zero;

  ClipTransition copyWith({
    TransitionType? type,
    Duration? duration,
    XfadeKind? xfadeKind,
  }) =>
      ClipTransition(
        type: type ?? this.type,
        duration: duration ?? this.duration,
        xfadeKind: xfadeKind ?? this.xfadeKind,
      );
}

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
/// [speed] scales playback: 2.0 plays twice as fast, so the clip consumes
/// [duration] * [speed] of source media.
class Clip {
  const Clip({
    required this.id,
    required this.source,
    required this.timelineStart,
    required this.sourceStart,
    required this.duration,
    this.speed = 1.0,
    this.filter = VideoFilter.none,
    this.transitionIn = const ClipTransition(),
    this.transitionOut = const ClipTransition(),
  }) : assert(speed > 0, 'speed must be positive');

  final String id;
  final MediaSource source;
  final Duration timelineStart;
  final Duration sourceStart;
  final Duration duration;

  /// Playback speed multiplier (1.0 = normal). Clamped to 0.25..4.0 by
  /// [setClipSpeed] in timeline_ops.dart.
  final double speed;
  final VideoFilter filter;
  final ClipTransition transitionIn;
  final ClipTransition transitionOut;

  Duration get timelineEnd => timelineStart + duration;

  /// How much source media this clip consumes (timeline duration * speed).
  Duration get sourceDuration =>
      Duration(milliseconds: (duration.inMilliseconds * speed).round());

  Clip copyWith({
    String? id,
    MediaSource? source,
    Duration? timelineStart,
    Duration? sourceStart,
    Duration? duration,
    double? speed,
    VideoFilter? filter,
    ClipTransition? transitionIn,
    ClipTransition? transitionOut,
  }) =>
      Clip(
        id: id ?? this.id,
        source: source ?? this.source,
        timelineStart: timelineStart ?? this.timelineStart,
        sourceStart: sourceStart ?? this.sourceStart,
        duration: duration ?? this.duration,
        speed: speed ?? this.speed,
        filter: filter ?? this.filter,
        transitionIn: transitionIn ?? this.transitionIn,
        transitionOut: transitionOut ?? this.transitionOut,
      );
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

  TextOverlay copyWith({
    String? text,
    Duration? start,
    Duration? end,
    double? fontSize,
  }) =>
      TextOverlay(
        id: id,
        text: text ?? this.text,
        start: start ?? this.start,
        end: end ?? this.end,
        fontSize: fontSize ?? this.fontSize,
      );
}

/// A background music / audio track laid over the timeline.
///
/// [timelineStart] is where it starts on the timeline, [trimStart] the
/// offset inside the audio file, [duration] how long it plays.
class AudioTrack {
  const AudioTrack({
    required this.id,
    required this.path,
    required this.name,
    required this.timelineStart,
    required this.trimStart,
    required this.duration,
    required this.sourceDuration,
    this.volume = 1.0,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
  });

  final String id;

  /// File path on mobile, blob URL on web.
  final String path;
  final String name;
  final Duration timelineStart;
  final Duration trimStart;
  final Duration duration;
  final Duration sourceDuration;
  final double volume;

  /// Ramps applied at export; clamped to the track duration.
  final Duration fadeIn;
  final Duration fadeOut;

  Duration get timelineEnd => timelineStart + duration;

  AudioTrack copyWith({
    Duration? timelineStart,
    Duration? trimStart,
    Duration? duration,
    double? volume,
    Duration? fadeIn,
    Duration? fadeOut,
  }) =>
      AudioTrack(
        id: id,
        path: path,
        name: name,
        timelineStart: timelineStart ?? this.timelineStart,
        trimStart: trimStart ?? this.trimStart,
        duration: duration ?? this.duration,
        sourceDuration: sourceDuration,
        volume: volume ?? this.volume,
        fadeIn: fadeIn ?? this.fadeIn,
        fadeOut: fadeOut ?? this.fadeOut,
      );
}

/// An image sticker pinned over the video between [start] and [end].
///
/// [x] and [y] are the normalized (0..1) center position on the frame;
/// [scale] multiplies the base size (25% of the frame width).
class StickerOverlay {
  const StickerOverlay({
    required this.id,
    required this.path,
    required this.name,
    required this.start,
    required this.end,
    this.x = 0.5,
    this.y = 0.5,
    this.scale = 1.0,
  });

  final String id;

  /// File path on mobile, blob URL on web.
  final String path;
  final String name;
  final Duration start;
  final Duration end;
  final double x;
  final double y;
  final double scale;

  StickerOverlay copyWith({
    Duration? start,
    Duration? end,
    double? x,
    double? y,
    double? scale,
  }) =>
      StickerOverlay(
        id: id,
        path: path,
        name: name,
        start: start ?? this.start,
        end: end ?? this.end,
        x: x ?? this.x,
        y: y ?? this.y,
        scale: scale ?? this.scale,
      );
}

/// The editable document: tracks of clips plus overlays.
class TimelineProject {
  const TimelineProject({
    this.tracks = const [],
    this.overlays = const [],
    this.audioTracks = const [],
    this.stickers = const [],
  });

  final List<VideoTrack> tracks;
  final List<TextOverlay> overlays;
  final List<AudioTrack> audioTracks;
  final List<StickerOverlay> stickers;

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
    this.videoCodec = 'libx264',
  });

  final String outputPath;
  final int width;
  final int height;
  final int fps;
  final int videoBitrate;

  /// Video encoder, e.g. 'libx264'. Use a platform hardware encoder
  /// ('h264_mediacodec' / 'h264_videotoolbox') with an LGPL ffmpeg-kit
  /// variant to avoid GPL codecs.
  final String videoCodec;
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
