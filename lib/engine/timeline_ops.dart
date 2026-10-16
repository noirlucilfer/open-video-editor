// Pure timeline editing operations: trim, split, merge.
//
// These are pure functions over the immutable model in video_engine.dart,
// so they are easy to unit-test and reuse across UI surfaces.

import 'video_engine.dart';

/// Clips may never be trimmed shorter than this.
const minClipDuration = Duration(milliseconds: 500);

/// Allowed playback speed range.
const minClipSpeed = 0.25;
const maxClipSpeed = 4.0;

Duration _clampDuration(Duration value, Duration min, Duration max) =>
    value < min ? min : (value > max ? max : value);

/// Changes [clip]'s playback speed, resampling its timeline duration so
/// the same source segment is covered faster/slower.
///
/// The new duration is clamped to the available source media and to
/// [minClipDuration]. [maxEnd] optionally caps the new end (used to avoid
/// overlapping the next clip).
Clip setClipSpeed(Clip clip, double speed,
    {Duration? maxEnd}) {
  final s = speed.clamp(minClipSpeed, maxClipSpeed);
  final sourceMs = clip.sourceDuration.inMilliseconds;
  // The same source segment at the new speed: timeline = source / speed.
  var timelineMs = (sourceMs / s).round();
  final maxSourceMs =
      (clip.source.duration - clip.sourceStart).inMilliseconds;
  timelineMs = timelineMs.clamp(
      minClipDuration.inMilliseconds, (maxSourceMs / s).round());
  if (maxEnd != null) {
    final cap = (maxEnd - clip.timelineStart).inMilliseconds;
    if (cap < timelineMs) {
      timelineMs = cap.clamp(minClipDuration.inMilliseconds, cap);
    }
  }
  return clip.copyWith(
    speed: s,
    duration: Duration(milliseconds: timelineMs),
  );
}

/// Moves the clip's start edge to [newTimelineStart].
///
/// The source offset shifts by the same delta multiplied by [Clip.speed];
/// the result is clamped so the clip never starts before the beginning of
/// its source and never shrinks below [minClipDuration]. The clip keeps
/// its id.
Clip trimClipStart(Clip clip, Duration newTimelineStart) {
  final minStart = clip.timelineStart -
      Duration(
          milliseconds:
              (clip.sourceStart.inMilliseconds / clip.speed).round());
  final maxStart = clip.timelineEnd - minClipDuration;
  final start = _clampDuration(newTimelineStart, minStart, maxStart);
  final delta = start - clip.timelineStart;
  return clip.copyWith(
    timelineStart: start,
    sourceStart: clip.sourceStart +
        Duration(
            milliseconds: (delta.inMilliseconds * clip.speed).round()),
    duration: clip.duration - delta,
  );
}

/// Moves the clip's end edge to [newTimelineEnd].
///
/// Clamped so the clip never extends past the end of its source (scaled by
/// [Clip.speed]) and never shrinks below [minClipDuration]. The clip keeps
/// its id.
Clip trimClipEnd(Clip clip, Duration newTimelineEnd) {
  final minEnd = clip.timelineStart + minClipDuration;
  final maxSourceMs =
      (clip.source.duration - clip.sourceStart).inMilliseconds;
  final maxEnd = clip.timelineStart +
      Duration(milliseconds: (maxSourceMs / clip.speed).round());
  final end = _clampDuration(newTimelineEnd, minEnd, maxEnd);
  return clip.copyWith(duration: end - clip.timelineStart);
}

/// Splits [clip] into two clips at timeline position [at].
///
/// Returns (first, second). The first half keeps the clip's id; the second
/// gets "`<id>`-b". Speed is preserved on both halves. Throws
/// [ArgumentError] when [at] is not strictly inside the clip.
(Clip, Clip) splitClipAt(Clip clip, Duration at) {
  if (at <= clip.timelineStart || at >= clip.timelineEnd) {
    throw ArgumentError('Split point must be strictly inside the clip');
  }
  final first = clip.copyWith(
    duration: at - clip.timelineStart,
    // Splitting breaks edge transitions; the inner edges start clean.
    transitionOut: const ClipTransition(),
  );
  final second = clip.copyWith(
    id: '${clip.id}-b',
    timelineStart: at,
    sourceStart: clip.sourceStart +
        Duration(
            milliseconds:
                ((at - clip.timelineStart).inMilliseconds * clip.speed)
                    .round()),
    duration: clip.timelineEnd - at,
    transitionIn: const ClipTransition(),
  );
  return (first, second);
}

/// Merges two clips into one when they are timeline-contiguous AND
/// source-contiguous (same source, same speed, no gap/overlap in either).
///
/// Returns the merged clip (keeping [a]'s id), or null when the clips
/// cannot be merged cleanly.
Clip? tryMergeClips(Clip a, Clip b) {
  if (a.source.id != b.source.id) return null;
  if (a.speed != b.speed) return null;
  if (a.timelineEnd != b.timelineStart) return null;
  if (a.sourceStart + a.sourceDuration != b.sourceStart) return null;
  return a.copyWith(duration: a.duration + b.duration);
}
