// Pure timeline editing operations: trim, split, merge.
//
// These are pure functions over the immutable model in video_engine.dart,
// so they are easy to unit-test and reuse across UI surfaces.

import 'video_engine.dart';

/// Clips may never be trimmed shorter than this.
const minClipDuration = Duration(milliseconds: 500);

Duration _clampDuration(Duration value, Duration min, Duration max) =>
    value < min ? min : (value > max ? max : value);

/// Moves the clip's start edge to [newTimelineStart].
///
/// The source offset shifts by the same delta; the result is clamped so the
/// clip never starts before the beginning of its source and never shrinks
/// below [minClipDuration]. The clip keeps its id.
Clip trimClipStart(Clip clip, Duration newTimelineStart) {
  final minStart = clip.timelineStart - clip.sourceStart;
  final maxStart = clip.timelineEnd - minClipDuration;
  final start = _clampDuration(newTimelineStart, minStart, maxStart);
  final delta = start - clip.timelineStart;
  return Clip(
    id: clip.id,
    source: clip.source,
    timelineStart: start,
    sourceStart: clip.sourceStart + delta,
    duration: clip.duration - delta,
  );
}

/// Moves the clip's end edge to [newTimelineEnd].
///
/// Clamped so the clip never extends past the end of its source and never
/// shrinks below [minClipDuration]. The clip keeps its id.
Clip trimClipEnd(Clip clip, Duration newTimelineEnd) {
  final minEnd = clip.timelineStart + minClipDuration;
  final maxEnd = clip.timelineStart + (clip.source.duration - clip.sourceStart);
  final end = _clampDuration(newTimelineEnd, minEnd, maxEnd);
  return Clip(
    id: clip.id,
    source: clip.source,
    timelineStart: clip.timelineStart,
    sourceStart: clip.sourceStart,
    duration: end - clip.timelineStart,
  );
}

/// Splits [clip] into two clips at timeline position [at].
///
/// Returns (first, second). The first half keeps the clip's id; the second
/// gets "`<id>`-b". Throws [ArgumentError] when [at] is not strictly inside
/// the clip.
(Clip, Clip) splitClipAt(Clip clip, Duration at) {
  if (at <= clip.timelineStart || at >= clip.timelineEnd) {
    throw ArgumentError('Split point must be strictly inside the clip');
  }
  final first = Clip(
    id: clip.id,
    source: clip.source,
    timelineStart: clip.timelineStart,
    sourceStart: clip.sourceStart,
    duration: at - clip.timelineStart,
  );
  final second = Clip(
    id: '${clip.id}-b',
    source: clip.source,
    timelineStart: at,
    sourceStart: clip.sourceStart + (at - clip.timelineStart),
    duration: clip.timelineEnd - at,
  );
  return (first, second);
}

/// Merges two clips into one when they are timeline-contiguous AND
/// source-contiguous (same source, no gap/overlap in either).
///
/// Returns the merged clip (keeping [a]'s id), or null when the clips
/// cannot be merged cleanly.
Clip? tryMergeClips(Clip a, Clip b) {
  if (a.source.id != b.source.id) return null;
  if (a.timelineEnd != b.timelineStart) return null;
  if (a.sourceStart + a.duration != b.sourceStart) return null;
  return Clip(
    id: a.id,
    source: a.source,
    timelineStart: a.timelineStart,
    sourceStart: a.sourceStart,
    duration: a.duration + b.duration,
  );
}
