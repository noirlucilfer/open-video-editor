// Translates a [TimelineProject] into an ffmpeg CLI invocation.
//
// Layout of the generated command:
//   - one input per clip: `-ss <sourceStart> -t <duration> -i <path>`
//     (input seeking trims both video and audio)
//   - filter_complex:
//       per clip: fps + scale + color filter + fades + setpts (video),
//                 aresample/aformat + asetpts (audio, or generated silence
//                 when the source has no audio)
//       concat all segments, then drawtext overlays, then format=yuv420p
//   - output: libx264 + aac, faststart
//
// This is a pure function so the exact command can be unit-tested and
// inspected without running anything.

import 'video_engine.dart';

String _sec(Duration d) => (d.inMilliseconds / 1000).toString();

/// Builds the full ffmpeg argument list (without the executable name).
///
/// [fontFile] selects the typeface for drawtext overlays; when null,
/// drawtext uses ffmpeg's default font handling. Throws [ArgumentError]
/// for projects without clips.
List<String> buildExportCommand(
  TimelineProject project,
  ExportConfig config, {
  String? fontFile,
}) {
  final clips = [
    for (final track in project.tracks) for (final clip in track.clips) clip
  ]..sort((a, b) => a.timelineStart.compareTo(b.timelineStart));
  if (clips.isEmpty) {
    throw ArgumentError('Cannot export a project without clips');
  }

  final args = <String>[];
  for (final clip in clips) {
    args.addAll([
      '-ss',
      _sec(clip.sourceStart),
      '-t',
      _sec(clip.duration),
      '-i',
      clip.source.path,
    ]);
  }

  final filters = <String>[];
  for (var i = 0; i < clips.length; i++) {
    final clip = clips[i];
    final videoChain = <String>[
      'fps=${config.fps}',
      'scale=${config.width}:${config.height}',
      ..._colorFilter(clip.filter),
      ..._fades(clip),
      'setpts=PTS-STARTPTS',
    ];
    filters.add('[$i:v]${videoChain.join(',')}[v$i]');
    if (clip.source.hasAudio) {
      filters.add(
          '[$i:a]aresample=44100,aformat=channel_layouts=stereo,asetpts=PTS-STARTPTS[a$i]');
    } else {
      filters.add(
          'aevalsrc=0:d=${_sec(clip.duration)}:s=44100,aformat=channel_layouts=stereo[a$i]');
    }
  }

  // concat wants segment-interleaved inputs: [v0][a0][v1][a1]...
  final maps = [for (var i = 0; i < clips.length; i++) '[v$i][a$i]'].join();
  filters.add('${maps}concat=n=${clips.length}:v=1:a=1[catv][cata]');

  var videoLabel = 'catv';
  for (var i = 0; i < project.overlays.length; i++) {
    final next = 'ov$i';
    filters.add('[$videoLabel]${_drawtext(project.overlays[i], fontFile)}[$next]');
    videoLabel = next;
  }
  filters.add('[$videoLabel]format=yuv420p[outv]');

  args.addAll([
    '-filter_complex',
    filters.join(';'),
    '-map',
    '[outv]',
    '-map',
    '[cata]',
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '23',
    '-r',
    '${config.fps}',
    '-c:a',
    'aac',
    '-b:a',
    '128k',
    '-movflags',
    '+faststart',
    '-y',
    config.outputPath,
  ]);
  return args;
}

/// Per-clip color filter chain for [filter].
List<String> _colorFilter(VideoFilter filter) {
  switch (filter) {
    case VideoFilter.none:
      return const [];
    case VideoFilter.grayscale:
      return const ['hue=s=0'];
    case VideoFilter.sepia:
      return const [
        'colorchannelmixer=.393:.769:.189:0:.349:.686:.168:0:.272:.534:.131:0:0:0:0:1'
      ];
    case VideoFilter.invert:
      return const ['negate'];
    case VideoFilter.warm:
      return const [
        'colorchannelmixer=1.2:.1:0:0:0:1:0:0:0:.8:0:0:0:0:1'
      ];
    case VideoFilter.cool:
      return const [
        'colorchannelmixer=.8:0:0:0:0:1:.1:0:0:1.2:0:0:0:0:1'
      ];
    case VideoFilter.vintage:
      // The preview matrix carries a +20 offset that colorchannelmixer
      // cannot express; approximate it with a small brightness lift.
      return const [
        'colorchannelmixer=.9:.1:.1:0:.1:.9:.1:0:.1:.1:.9:0:0:0:0:1',
        'eq=brightness=0.078',
      ];
  }
}

/// Fade in/out filters for [clip]. Timings are relative to the trimmed
/// input (each input starts at its own 0).
List<String> _fades(Clip clip) {
  final out = <String>[];
  final tIn = clip.transitionIn;
  if (tIn.isEnabled) {
    out.add('fade=t=in:st=0:d=${_sec(tIn.duration)}');
  }
  final tOut = clip.transitionOut;
  if (tOut.isEnabled) {
    final start = _sec(clip.duration - tOut.duration);
    out.add('fade=t=out:st=$start:d=${_sec(tOut.duration)}');
  }
  return out;
}

String _drawtext(TextOverlay overlay, String? fontFile) {
  final font = fontFile != null ? "fontfile='$fontFile':" : '';
  return 'drawtext=${font}text="${_escape(overlay.text)}"'
      ':fontsize=${overlay.fontSize.round()}'
      ':fontcolor=white:borderw=2:bordercolor=black'
      ':x=(w-text_w)/2:y=(h-text_h)/2'
      ":enable='between(t,${_sec(overlay.start)},${_sec(overlay.end)})'";
}

/// drawtext text escaping for a double-quoted value: backslash, double
/// quote and colon (the option separator) must be escaped.
String _escape(String text) => text
    .replaceAll('\\', '\\\\')
    .replaceAll('"', '\\"')
    .replaceAll(':', '\\:');
