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

/// Green-screen (chroma key) settings for a [Clip].
///
/// When enabled, the export keys out [color] via ffmpeg's chromakey filter
/// and composites the result over a solid [bgColor]. The preview shows the
/// original clip; the effect is visible in the exported video.
class ChromaKey {
  const ChromaKey({
    this.enabled = false,
    this.color = 0x00FF00,
    this.similarity = 0.3,
    this.blend = 0.1,
    this.bgColor = 0x000000,
  });

  /// Whether the effect is applied.
  final bool enabled;

  /// The key color as 0xRRGGBB.
  final int color;

  /// How close a pixel must be to the key color (0.01..1.0).
  final double similarity;

  /// Edge softness (0.0..1.0).
  final double blend;

  /// Background color as 0xRRGGBB shown where the key is removed.
  final int bgColor;

  ChromaKey copyWith({
    bool? enabled,
    int? color,
    double? similarity,
    double? blend,
    int? bgColor,
  }) =>
      ChromaKey(
        enabled: enabled ?? this.enabled,
        color: color ?? this.color,
        similarity: similarity ?? this.similarity,
        blend: blend ?? this.blend,
        bgColor: bgColor ?? this.bgColor,
      );
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
    this.chromaKey = const ChromaKey(),
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

  /// Green-screen settings; inert unless [ChromaKey.enabled].
  final ChromaKey chromaKey;

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
    ChromaKey? chromaKey,
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
        chromaKey: chromaKey ?? this.chromaKey,
      );
}

/// One horizontal lane on the timeline holding an ordered list of clips.
class VideoTrack {
  const VideoTrack({required this.id, this.clips = const []});

  final String id;
  final List<Clip> clips;
}

/// A text caption shown over the video between [start] and [end].
/// A text caption burned into the exported video via drawtext.
///
/// [x]/[y] are the normalized center position (0..1); [keyframes] animate
/// position and size over the overlay's lifetime. Times are offsets from
/// [start].
class TextOverlay {
  const TextOverlay({
    required this.id,
    required this.text,
    required this.start,
    required this.end,
    this.fontSize = 32,
    this.x = 0.5,
    this.y = 0.5,
    this.keyframes = const [],
  });

  final String id;
  final String text;
  final Duration start;
  final Duration end;
  final double fontSize;

  /// Normalized center position, 0..1.
  final double x;
  final double y;

  /// Animation keyframes, sorted by time. Empty = static.
  final List<TextKeyframe> keyframes;

  TextOverlay copyWith({
    String? text,
    Duration? start,
    Duration? end,
    double? fontSize,
    double? x,
    double? y,
    List<TextKeyframe>? keyframes,
  }) =>
      TextOverlay(
        id: id,
        text: text ?? this.text,
        start: start ?? this.start,
        end: end ?? this.end,
        fontSize: fontSize ?? this.fontSize,
        x: x ?? this.x,
        y: y ?? this.y,
        keyframes: keyframes ?? this.keyframes,
      );
}

/// One animation waypoint for a [TextOverlay].
///
/// [time] is the offset from the overlay's start; [x]/[y] the normalized
/// center position; [fontSize] the text size in logical px.
class TextKeyframe {
  const TextKeyframe({
    required this.time,
    required this.x,
    required this.y,
    required this.fontSize,
  });

  final Duration time;
  final double x;
  final double y;
  final double fontSize;
}

/// Interpolated pose of a text overlay at [offset] from its start.
///
/// The base pose (x, y, fontSize) holds at t=0; poses lerp linearly between
/// keyframes and the last keyframe's pose holds after it.
({double x, double y, double fontSize}) textPoseAt(
    TextOverlay o, Duration offset) {
  final kfs = [...o.keyframes]..sort((a, b) => a.time.compareTo(b.time));
  var px = o.x;
  var py = o.y;
  var ps = o.fontSize;
  var pt = Duration.zero;
  for (final k in kfs) {
    if (offset < k.time) {
      final span = (k.time - pt).inMilliseconds;
      final f = span <= 0
          ? 1.0
          : (offset - pt).inMilliseconds / span;
      return (
        x: px + (k.x - px) * f,
        y: py + (k.y - py) * f,
        fontSize: ps + (k.fontSize - ps) * f,
      );
    }
    px = k.x;
    py = k.y;
    ps = k.fontSize;
    pt = k.time;
  }
  return (x: px, y: py, fontSize: ps);
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
/// A pose snapshot for a sticker animation: normalized center (x, y)
/// and scale at [time] after the sticker's start.
class StickerKeyframe {
  const StickerKeyframe({
    required this.time,
    required this.x,
    required this.y,
    this.scale = 1.0,
  });

  final Duration time;
  final double x;
  final double y;
  final double scale;
}

/// A picture-in-picture video laid over the timeline.
///
/// Like [StickerOverlay] but for video: the source plays (optionally with
/// audio) inside [start]..[end], scaled to [scale] (fraction of the export
/// width) and centered at the normalized ([x], [y]) position.
class VideoOverlay {
  const VideoOverlay({
    required this.id,
    required this.path,
    required this.name,
    required this.start,
    required this.end,
    this.sourceStart = Duration.zero,
    this.x = 0.5,
    this.y = 0.5,
    this.scale = 0.35,
    this.volume = 1.0,
    this.hasAudio = true,
  });

  final String id;

  /// File path on mobile, blob URL on web.
  final String path;
  final String name;
  final Duration start;
  final Duration end;

  /// Offset inside the source video where playback begins.
  final Duration sourceStart;

  /// Normalized center position, 0..1.
  final double x;
  final double y;

  /// Width as a fraction of the export width.
  final double scale;

  /// 0.0 = muted, 1.0 = full.
  final double volume;

  /// Whether the source file carries an audio stream (export contract:
  /// must be accurate, like [MediaSource.hasAudio]).
  final bool hasAudio;

  VideoOverlay copyWith({
    Duration? start,
    Duration? end,
    Duration? sourceStart,
    double? x,
    double? y,
    double? scale,
    double? volume,
    bool? hasAudio,
  }) =>
      VideoOverlay(
        id: id,
        path: path,
        name: name,
        start: start ?? this.start,
        end: end ?? this.end,
        sourceStart: sourceStart ?? this.sourceStart,
        x: x ?? this.x,
        y: y ?? this.y,
        scale: scale ?? this.scale,
        volume: volume ?? this.volume,
        hasAudio: hasAudio ?? this.hasAudio,
      );
}

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
    this.keyframes = const [],
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

  /// Pose snapshots after [start]; empty = static sticker.
  final List<StickerKeyframe> keyframes;

  StickerOverlay copyWith({
    Duration? start,
    Duration? end,
    double? x,
    double? y,
    double? scale,
    List<StickerKeyframe>? keyframes,
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
        keyframes: keyframes ?? this.keyframes,
      );
}

/// Interpolated sticker pose at [offset] after the sticker's start.
/// The base x/y/scale is the pose at t=0; keyframes lerp between each
/// other (and from the base pose to the first keyframe).
({double x, double y, double scale}) stickerPoseAt(
    StickerOverlay s, Duration offset) {
  final kfs = [...s.keyframes]..sort((a, b) => a.time.compareTo(b.time));
  if (kfs.isEmpty || offset <= Duration.zero) {
    return (x: s.x, y: s.y, scale: s.scale);
  }
  double lerp(double a, double b, double t) => a + (b - a) * t;
  StickerKeyframe prev =
      StickerKeyframe(time: Duration.zero, x: s.x, y: s.y, scale: s.scale);
  for (final kf in kfs) {
    if (offset <= kf.time) {
      final span = kf.time.inMilliseconds - prev.time.inMilliseconds;
      final t = span <= 0
          ? 1.0
          : (offset.inMilliseconds - prev.time.inMilliseconds) / span;
      final c = t.clamp(0.0, 1.0);
      return (
        x: lerp(prev.x, kf.x, c),
        y: lerp(prev.y, kf.y, c),
        scale: lerp(prev.scale, kf.scale, c),
      );
    }
    prev = kf;
  }
  return (x: prev.x, y: prev.y, scale: prev.scale);
}

/// The editable document: tracks of clips plus overlays.
class TimelineProject {
  const TimelineProject({
    this.tracks = const [],
    this.overlays = const [],
    this.audioTracks = const [],
    this.stickers = const [],
    this.videoOverlays = const [],
  });

  final List<VideoTrack> tracks;
  final List<TextOverlay> overlays;
  final List<AudioTrack> audioTracks;
  final List<StickerOverlay> stickers;

  /// Picture-in-picture videos composited over the main timeline.
  final List<VideoOverlay> videoOverlays;

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
