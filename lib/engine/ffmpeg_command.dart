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
  final pipBase = stickerBase + project.stickers.length;
  for (final pip in project.videoOverlays) {
    args.addAll([
      '-ss',
      _sec(pip.sourceStart),
      '-t',
      _sec(pip.end - pip.start),
      '-i',
      pip.path,
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
    if (clip.chromaKey.enabled) {
      // Green screen: key out the color, composite over a solid color.
      // The [v$i] label is reused as the composited output (ffmpeg resolves
      // labels in order, so downstream concat/xfade keeps working).
      final ck = clip.chromaKey;
      final key = '0x${ck.color.toRadixString(16).padLeft(6, '0')}';
      final bg = '0x${ck.bgColor.toRadixString(16).padLeft(6, '0')}';
      final outDur = clip.duration.inMilliseconds / clip.speed / 1000;
      filters.add(
          '[v$i]chromakey=$key:${_num(ck.similarity)}:${_num(ck.blend)}[v${i}k]');
      filters.add('color=c=$bg:s=${config.width}x${config.height}'
          ':d=${_num(outDur)}[v${i}bg]');
      // format back to yuv420p so concat/xfade sees uniform pixel formats.
      filters.add('[v${i}bg][v${i}k]overlay,format=yuv420p[v$i]');
    }
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
    _xfadeChains(filters, clips, xfades, _xfadeKinds(clips));
  } else {
    final maps =
        [for (var i = 0; i < clips.length; i++) '[v$i][a$i]'].join();
    filters.add('${maps}concat=n=${clips.length}:v=1:a=1[catv][cata]');
  }

  // Background audio tracks: delay to their timeline start, apply volume,
  // then mix under the clip audio. duration=first keeps the project length.
  // Timeline starts are remapped past any earlier crossfades.
  // PiP overlay audio joins the same mix when audible.
  var audioLabel = 'cata';
  final mixInputs = <String>['[cata]'];
  for (var j = 0; j < project.audioTracks.length; j++) {
    final track = project.audioTracks[j];
    final ms =
        _mapOutputTime(track.timelineStart, clips, xfades).inMilliseconds;
    final chain = <String>[
      'aresample=44100',
      'aformat=channel_layouts=stereo',
      ..._audioFades(track),
      'adelay=$ms|$ms',
      'volume=${track.volume}',
    ];
    filters.add('[${audioBase + j}:a]${chain.join(',')}[am$j]');
    mixInputs.add('[am$j]');
  }
  for (var p = 0; p < project.videoOverlays.length; p++) {
    final pip = project.videoOverlays[p];
    if (!pip.hasAudio || pip.volume <= 0) continue;
    final ms = _mapOutputTime(pip.start, clips, xfades).inMilliseconds;
    filters.add('[${pipBase + p}:a]aresample=44100,'
        'aformat=channel_layouts=stereo,'
        'volume=${pip.volume},'
        'adelay=$ms|$ms[pa$p]');
    mixInputs.add('[pa$p]');
  }
  if (mixInputs.length > 1) {
    filters.add(
        '${mixInputs.join()}amix=inputs=${mixInputs.length}:duration=first:dropout_transition=0[outa]');
    audioLabel = 'outa';
  }

  var videoLabel = 'catv';
  for (var i = 0; i < project.overlays.length; i++) {
    final o = project.overlays[i];
    final next = 'ov$i';
    final start = _mapOutputTime(o.start, clips, xfades);
    final end = _mapOutputTime(o.end, clips, xfades);
    filters.add(
        '[$videoLabel]${_drawtext(o, start, end, clips, xfades, fontFile)}[$next]');
    videoLabel = next;
  }
  for (var k = 0; k < project.stickers.length; k++) {
    final sticker = project.stickers[k];
    final next = 'sv$k';
    final start = _mapOutputTime(sticker.start, clips, xfades);
    final end = _mapOutputTime(sticker.end, clips, xfades);
    if (sticker.keyframes.isEmpty) {
      final w = (config.width * 0.25 * sticker.scale).round().clamp(8, 4096);
      filters.add('[${stickerBase + k}:v]scale=$w:-1[st$k]');
      filters.add('[$videoLabel][st$k]'
          "overlay=x='(${_num(sticker.x)}*W-w/2)':y='(${_num(sticker.y)}*H-h/2)'"
          ":enable='between(t,${_sec(start)},${_sec(end)})'"
          '[$next]');
    } else {
      // Animated sticker: piecewise-linear x/y/scale expressions over t.
      final w0 = (config.width * 0.25).round().clamp(8, 4096);
      final pts = _keyframePoints(sticker, clips, xfades);
      final xe = _piecewise(pts.map((p) => (p.t, p.x)).toList());
      final ye = _piecewise(pts.map((p) => (p.t, p.y)).toList());
      final se = _piecewise(pts.map((p) => (p.t, p.s)).toList());
      filters.add('[${stickerBase + k}:v]scale=w=\'$w0*($se)\':h=-1'
          ':eval=frame[st$k]');
      filters.add('[$videoLabel][st$k]'
          "overlay=x='(($xe)*W-w/2)':y='(($ye)*H-h/2)'"
          ":enable='between(t,${_sec(start)},${_sec(end)})'"
          ":eval=frame[$next]");
    }
    videoLabel = next;
  }
  for (var p = 0; p < project.videoOverlays.length; p++) {
    final pip = project.videoOverlays[p];
    final next = 'pv$p';
    final start = _mapOutputTime(pip.start, clips, xfades);
    final end = _mapOutputTime(pip.end, clips, xfades);
    final w = (config.width * pip.scale).round().clamp(8, 4096);
    filters.add('[${pipBase + p}:v]scale=$w:-1,fps=${config.fps},'
        'setpts=PTS-STARTPTS[pvs$p]');
    filters.add('[$videoLabel][pvs$p]'
        "overlay=x='(${_num(pip.x)}*W-w/2)':y='(${_num(pip.y)}*H-h/2)'"
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

/// A keyframe point remapped onto the output timeline.
typedef _KP = ({double t, double x, double y, double s});

/// Base pose plus keyframes as output-timeline points for expression gen.
List<_KP> _keyframePoints(
    StickerOverlay sticker, List<Clip> clips, List<Duration> xfades) {
  final t0 = _mapOutputTime(sticker.start, clips, xfades);
  final pts = <_KP>[
    (
      t: t0.inMilliseconds / 1000,
      x: sticker.x,
      y: sticker.y,
      s: sticker.scale,
    )
  ];
  final kfs = [...sticker.keyframes]..sort((a, b) => a.time.compareTo(b.time));
  for (final kf in kfs) {
    final t = _mapOutputTime(sticker.start + kf.time, clips, xfades);
    pts.add((
      t: t.inMilliseconds / 1000,
      x: kf.x,
      y: kf.y,
      s: kf.scale,
    ));
  }
  return pts;
}

/// Piecewise-linear expression of (tSecs, value) points, as nested
/// if(between(t,...),...) — single-quoted by the caller.
String _piecewise(List<(double, double)> pts) {
  var expr = _num(pts.last.$2);
  for (var i = pts.length - 2; i >= 0; i--) {
    final t0 = _num(pts[i].$1);
    final t1 = _num(pts[i + 1].$1);
    final v0 = _num(pts[i].$2);
    final v1 = _num(pts[i + 1].$2);
    final seg = t0 == t1
        ? v1
        : '$v0+($v1-$v0)*(t-$t0)/($t1-$t0)';
    expr = 'if(between(t,$t0,$t1),$seg,$expr)';
  }
  return expr;
}

/// afade in/out for a background music track, clamped to its duration.
/// Applied before adelay so timings are relative to the track content.
List<String> _audioFades(AudioTrack track) {
  final out = <String>[];
  final durMs = track.duration.inMilliseconds;
  if (track.fadeIn > Duration.zero) {
    final d = Duration(milliseconds: track.fadeIn.inMilliseconds.clamp(1, durMs));
    out.add('afade=t=in:st=0:d=${_sec(d)}');
  }
  if (track.fadeOut > Duration.zero) {
    final d = Duration(milliseconds: track.fadeOut.inMilliseconds.clamp(1, durMs));
    out.add('afade=t=out:st=${_sec(Duration(milliseconds: durMs) - d)}'
        ':d=${_sec(d)}');
  }
  return out;
}

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

/// Crossfade style at each clip boundary (null when the boundary has no
/// crossfade). Mirrors [_xfadeDurations].
List<XfadeKind?> _xfadeKinds(List<Clip> clips) {
  final kinds = List<XfadeKind?>.filled(
      clips.isNotEmpty ? clips.length - 1 : 0, null);
  for (var i = 0; i + 1 < clips.length; i++) {
    final t = clips[i].transitionOut;
    if (t.type == TransitionType.crossfade &&
        t.duration > Duration.zero &&
        clips[i].timelineEnd == clips[i + 1].timelineStart) {
      kinds[i] = t.xfadeKind;
    }
  }
  return kinds;
}
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
void _xfadeChains(List<String> filters, List<Clip> clips,
    List<Duration> xfades, List<XfadeKind?> kinds) {
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
      final kind = kinds[i]?.filterName ?? 'fade';
      final xv = 'x${i + 1}';
      final xa = 'xa${i + 1}';
      filters.add(
          '[$vAcc][$nextV]xfade=transition=$kind:duration=$d:offset=$offset[$xv]');
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

/// drawtext for a text overlay. Position (x/y center) and font size are
/// piecewise-linear expressions over t so keyframes animate; a static
/// overlay collapses to its base pose. Keyframe times are remapped onto the
/// output timeline (crossfades shift them).
String _drawtext(TextOverlay o, Duration start, Duration end, List<Clip> clips,
    List<Duration> xfades, String? fontFile) {
  final font = fontFile != null ? "fontfile='$fontFile':" : '';
  final pts = <(double, double, double, double)>[
    (start.inMilliseconds / 1000, o.x, o.y, o.fontSize),
  ];
  final kfs = [...o.keyframes]..sort((a, b) => a.time.compareTo(b.time));
  for (final kf in kfs) {
    final t = _mapOutputTime(o.start + kf.time, clips, xfades);
    pts.add((t.inMilliseconds / 1000, kf.x, kf.y, kf.fontSize));
  }
  final xe = _piecewise(pts.map((p) => (p.$1, p.$2)).toList());
  final ye = _piecewise(pts.map((p) => (p.$1, p.$3)).toList());
  final se = _piecewise(pts.map((p) => (p.$1, p.$4)).toList());
  return 'drawtext=${font}text="${_escape(o.text)}"'
      ":fontsize='($se)'"
      ':fontcolor=white:borderw=2:bordercolor=black'
      ":x='(($xe)*w-text_w/2)':y='(($ye)*h-text_h/2)'"
      ":enable='between(t,${_sec(start)},${_sec(end)})'";
}

/// drawtext text escaping for a double-quoted value: backslash, double
/// quote and colon (the option separator) must be escaped.
String _escape(String text) => text
    .replaceAll('\\', '\\\\')
    .replaceAll('"', '\\"')
    .replaceAll(':', '\\:');
