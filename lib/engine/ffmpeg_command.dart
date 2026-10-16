// Translates a [TimelineProject] into an ffmpeg CLI invocation.
//
// Layout of the generated command:
//   - one input per clip: `-ss <sourceStart> -t <sourceDuration> -i <path>`
//     (input seeking trims both video and audio; sourceDuration is the
//     timeline duration divided by the clip speed)
//   - one input per audio track: `-ss <trimStart> -t <duration> -i <path>`
//   - one looped input per sticker image
//   - filter_complex:
//       per clip: scale + color filter + setpts (speed) + fps + fades
//                 (video), aresample/aformat + atempo (speed) + asetpts
//                 (audio, or generated silence when the source has none)
//       concat all segments
//       audio tracks: adelay + volume, mixed with amix (duration=first)
//       drawtext overlays, then sticker overlays, then format=yuv420p
//   - output: libx264 + aac, faststart
//
// This is a pure function so the exact command can be unit-tested and
// inspected without running anything.

import 'video_engine.dart';

String _sec(Duration d) => (d.inMilliseconds / 1000).toString();

/// Formats a speed multiplier for filter expressions (1.5, 0.5, ...).
String _speedStr(double speed) {
  final s = speed.toStringAsFixed(3).replaceAll(RegExp(r'\.?0+$'), '');
  return s.isEmpty ? '0' : s;
}

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
      _sec(clip.sourceDuration),
      '-i',
      clip.source.path,
    ]);
  }
  final audioBase = clips.length;
  for (final track in project.audioTracks) {
    args.addAll([
      '-ss',
      _sec(track.trimStart),
      '-t',
      _sec(track.duration),
      '-i',
      track.path,
    ]);
  }
  final stickerBase = audioBase + project.audioTracks.length;
  for (final sticker in project.stickers) {
    args.addAll([
      '-loop',
      '1',
      '-t',
      _sec(sticker.end - sticker.start),
      '-i',
      sticker.path,
    ]);
  }

  final filters = <String>[];
  for (var i = 0; i < clips.length; i++) {
    final clip = clips[i];
    final videoChain = <String>[
      'scale=${config.width}:${config.height}',
      ..._colorFilter(clip.filter),
      // setpts before fps: retime first, then resample to the target rate
      // so speed changes stay smooth instead of choppy.
      if (clip.speed != 1.0)
        'setpts=(PTS-STARTPTS)/${_speedStr(clip.speed)}'
      else
        'setpts=PTS-STARTPTS',
      'fps=${config.fps}',
      ..._fades(clip),
    ];
    filters.add('[$i:v]${videoChain.join(',')}[v$i]');
    if (clip.source.hasAudio) {
      final audioChain = <String>[
        'aresample=44100',
        'aformat=channel_layouts=stereo',
        ..._atempo(clip.speed),
        'asetpts=PTS-STARTPTS',
      ];
      filters.add('[$i:a]${audioChain.join(',')}[a$i]');
    } else {
      filters.add(
          'aevalsrc=0:d=${_sec(clip.duration)}:s=44100,aformat=channel_layouts=stereo[a$i]');
    }
  }

  // concat wants segment-interleaved inputs: [v0][a0][v1][a1]...
  // With crossfades, boundaries dissolve via xfade/acrossfade chains
  // instead of a plain concat.
  final xfades = _xfadeDurations(clips);
  final hasXfade = xfades.any((d) => d > Duration.zero);
  if (hasXfade) {
    _xfadeChains(filters, clips, xfades);
  } else {
    final maps =
        [for (var i = 0; i < clips.length; i++) '[v$i][a$i]'].join();
    filters.add('${maps}concat=n=${clips.length}:v=1:a=1[catv][cata]');
  }

  // Background audio tracks: delay to their timeline start, apply volume,
  // then mix under the clip audio. duration=first keeps the project length.
  // Timeline starts are remapped past any earlier crossfades.
  var audioLabel = 'cata';
  if (project.audioTracks.isNotEmpty) {
    final mixInputs = <String>['[cata]'];
    for (var j = 0; j < project.audioTracks.length; j++) {
      final track = project.audioTracks[j];
      final ms =
          _mapOutputTime(track.timelineStart, clips, xfades).inMilliseconds;
      final chain = <String>[
        'aresample=44100',
        'aformat=channel_layouts=stereo',
        'adelay=$ms|$ms',
        'volume=${track.volume}',
      ];
      filters.add('[${audioBase + j}:a]${chain.join(',')}[am$j]');
      mixInputs.add('[am$j]');
    }
    filters.add(
        '${mixInputs.join()}amix=inputs=${mixInputs.length}:duration=first:dropout_transition=0[outa]');
    audioLabel = 'outa';
  }

  var videoLabel = 'catv';
  for (var i = 0; i < project.overlays.length; i++) {
    final o = project.overlays[i];
    final next = 'ov$i';
    final mapped = TextOverlay(
      id: o.id,
      text: o.text,
      start: _mapOutputTime(o.start, clips, xfades),
      end: _mapOutputTime(o.end, clips, xfades),
      fontSize: o.fontSize,
    );
    filters.add('[$videoLabel]${_drawtext(mapped, fontFile)}[$next]');
    videoLabel = next;
  }
  for (var k = 0; k < project.stickers.length; k++) {
    final sticker = project.stickers[k];
    final w = (config.width * 0.25 * sticker.scale).round().clamp(8, 4096);
    filters.add('[${stickerBase + k}:v]scale=$w:-1[st$k]');
    final next = 'sv$k';
    final start =
        _mapOutputTime(sticker.start, clips, xfades);
    final end = _mapOutputTime(sticker.end, clips, xfades);
    filters.add('[$videoLabel][st$k]'
        "overlay=x='(${_num(sticker.x)}*W-w/2)':y='(${_num(sticker.y)}*H-h/2)'"
        ":enable='between(t,${_sec(start)},${_sec(end)})'"
        '[$next]');
    videoLabel = next;
  }
  filters.add('[$videoLabel]format=yuv420p[outv]');

  args.addAll([
    '-filter_complex',
    filters.join(';'),
    '-map',
    '[outv]',
    '-map',
    '[$audioLabel]',
    '-c:v',
    config.videoCodec,
    // x264-specific quality settings; hardware encoders use their own
    // defaults (tune via videoBitrate in a future pass).
    if (config.videoCodec == 'libx264') ...[
      '-preset',
      'veryfast',
      '-crf',
      '23',
    ],
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

String _num(double v) =>
    v.toStringAsFixed(3).replaceAll(RegExp(r'\.?0+$'), '');

/// Crossfade duration at each clip boundary (0 when the boundary has no
/// crossfade). A crossfade only applies between timeline-contiguous clips.
List<Duration> _xfadeDurations(List<Clip> clips) {
  final durs = List<Duration>.filled(
      clips.isNotEmpty ? clips.length - 1 : 0, Duration.zero);
  for (var i = 0; i + 1 < clips.length; i++) {
    final t = clips[i].transitionOut;
    if (t.type == TransitionType.crossfade &&
        t.duration > Duration.zero &&
        clips[i].timelineEnd == clips[i + 1].timelineStart) {
      // The overlap cannot exceed either clip.
      final maxD = clips[i].duration < clips[i + 1].duration
          ? clips[i].duration
          : clips[i + 1].duration;
      durs[i] = t.duration > maxD ? maxD : t.duration;
    }
  }
  return durs;
}

/// Total output duration: crossfades overlap, so each one shortens the
/// result by its duration.
Duration exportDuration(TimelineProject project) {
  final clips = [
    for (final track in project.tracks) for (final clip in track.clips) clip
  ]..sort((a, b) => a.timelineStart.compareTo(b.timelineStart));
  var total = Duration.zero;
  for (final clip in clips) {
    total += clip.duration;
  }
  for (final d in _xfadeDurations(clips)) {
    total -= d;
  }
  return total;
}

/// Maps an original-timeline time to the output timeline, accounting for
/// the time each earlier crossfade absorbed.
Duration _mapOutputTime(
    Duration t, List<Clip> clips, List<Duration> xfades) {
  var shift = Duration.zero;
  for (var i = 0; i < xfades.length; i++) {
    if (clips[i].timelineEnd <= t) shift += xfades[i];
  }
  return t - shift;
}

/// Builds the video/audio join chains when at least one boundary has a
/// crossfade. Boundaries dissolve with xfade/acrossfade; plain boundaries
/// use two-input concats. Produces [catv] and [cata] like the concat path.
void _xfadeChains(
    List<String> filters, List<Clip> clips, List<Duration> xfades) {
  var vAcc = 'v0';
  var aAcc = 'a0';
  var accDurMs = clips[0].duration.inMilliseconds;
  for (var i = 0; i < xfades.length; i++) {
    final dMs = xfades[i].inMilliseconds;
    final nextV = 'v${i + 1}';
    final nextA = 'a${i + 1}';
    if (dMs > 0) {
      final d = _sec(xfades[i]);
      final offset = _sec(Duration(milliseconds: accDurMs - dMs));
      final xv = 'x${i + 1}';
      final xa = 'xa${i + 1}';
      filters.add(
          '[$vAcc][$nextV]xfade=transition=fade:duration=$d:offset=$offset[$xv]');
      filters.add('[$aAcc][$nextA]acrossfade=d=$d[$xa]');
      vAcc = xv;
      aAcc = xa;
      accDurMs = accDurMs + clips[i + 1].duration.inMilliseconds - dMs;
    } else {
      final cv = 'cv${i + 1}';
      final ca = 'ca${i + 1}';
      filters.add('[$vAcc][$nextV]concat=n=2:v=1:a=0[$cv]');
      filters.add('[$aAcc][$nextA]concat=n=2:v=0:a=1[$ca]');
      vAcc = cv;
      aAcc = ca;
      accDurMs = accDurMs + clips[i + 1].duration.inMilliseconds;
    }
  }
  // Normalize to the labels the rest of the graph expects.
  filters.add('[$vAcc]copy[catv]');
  filters.add('[$aAcc]acopy[cata]');
}

/// atempo only supports 0.5..2.0; chain filters for wider speeds.
List<String> _atempo(double speed) {
  if (speed == 1.0) return const [];
  var s = speed;
  final parts = <String>[];
  while (s > 2.0) {
    parts.add('atempo=2.0');
    s /= 2;
  }
  while (s < 0.5) {
    parts.add('atempo=0.5');
    s *= 2;
  }
  parts.add('atempo=${_speedStr(s)}');
  return parts;
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
/// input (each input starts at its own 0). Crossfades are handled by the
/// xfade chain, not here.
List<String> _fades(Clip clip) {
  final out = <String>[];
  final tIn = clip.transitionIn;
  if (tIn.isEnabled && tIn.type == TransitionType.fade) {
    out.add('fade=t=in:st=0:d=${_sec(tIn.duration)}');
  }
  final tOut = clip.transitionOut;
  if (tOut.isEnabled && tOut.type == TransitionType.fade) {
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
