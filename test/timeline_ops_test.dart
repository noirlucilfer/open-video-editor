import 'package:flutter_test/flutter_test.dart';
import 'package:open_video_editor/engine/timeline_ops.dart';
import 'package:open_video_editor/engine/video_engine.dart';

const _src = MediaSource(
  id: 's',
  path: '/tmp/s.mp4',
  duration: Duration(seconds: 10),
);

/// Clip on timeline 5s..9s, showing source 2s..6s.
Clip _clip() => const Clip(
      id: 'c',
      source: _src,
      timelineStart: Duration(seconds: 5),
      sourceStart: Duration(seconds: 2),
      duration: Duration(seconds: 4),
    );

void main() {
  group('trimClipStart', () {
    test('moves start and shifts source offset', () {
      final c = trimClipStart(_clip(), const Duration(seconds: 6));
      expect(c.timelineStart, const Duration(seconds: 6));
      expect(c.sourceStart, const Duration(seconds: 3));
      expect(c.duration, const Duration(seconds: 3));
      expect(c.id, 'c');
    });

    test('clamps at source beginning', () {
      final c = trimClipStart(_clip(), Duration.zero);
      // sourceStart is 2s, so earliest timeline start is 5s - 2s = 3s.
      expect(c.timelineStart, const Duration(seconds: 3));
      expect(c.sourceStart, Duration.zero);
    });

    test('never shrinks below minClipDuration', () {
      final c = trimClipStart(_clip(), const Duration(seconds: 20));
      expect(c.duration, minClipDuration);
    });
  });

  group('trimClipEnd', () {
    test('extends and shrinks duration', () {
      final c = trimClipEnd(_clip(), const Duration(seconds: 11));
      // source allows up to 5s + (10s - 2s) = 13s.
      expect(c.timelineEnd, const Duration(seconds: 11));
      expect(c.sourceStart, const Duration(seconds: 2));
    });

    test('clamps at source end', () {
      final c = trimClipEnd(_clip(), const Duration(seconds: 99));
      expect(c.timelineEnd, const Duration(seconds: 13));
    });

    test('never shrinks below minClipDuration', () {
      final c = trimClipEnd(_clip(), const Duration(seconds: 5));
      expect(c.duration, minClipDuration);
    });
  });

  group('splitClipAt', () {
    test('produces two contiguous clips with correct offsets', () {
      final (a, b) = splitClipAt(_clip(), const Duration(seconds: 7));
      expect(a.id, 'c');
      expect(a.timelineStart, const Duration(seconds: 5));
      expect(a.duration, const Duration(seconds: 2));
      expect(a.sourceStart, const Duration(seconds: 2));
      expect(b.timelineEnd, const Duration(seconds: 9));
      expect(b.duration, const Duration(seconds: 2));
      expect(b.sourceStart, const Duration(seconds: 4));
      expect(a.timelineEnd, b.timelineStart);
    });

    test('throws outside the clip', () {
      expect(() => splitClipAt(_clip(), const Duration(seconds: 5)),
          throwsArgumentError);
      expect(() => splitClipAt(_clip(), const Duration(seconds: 9)),
          throwsArgumentError);
    });
  });

  group('tryMergeClips', () {
    test('merges contiguous same-source clips', () {
      const a = Clip(
        id: 'a',
        source: _src,
        timelineStart: Duration(seconds: 0),
        sourceStart: Duration.zero,
        duration: Duration(seconds: 4),
      );
      const b = Clip(
        id: 'b',
        source: _src,
        timelineStart: Duration(seconds: 4),
        sourceStart: Duration(seconds: 4),
        duration: Duration(seconds: 3),
      );
      final m = tryMergeClips(a, b);
      expect(m, isNotNull);
      expect(m!.id, 'a');
      expect(m.duration, const Duration(seconds: 7));
      expect(m.sourceStart, Duration.zero);
    });

    test('returns null for different sources, gaps, or overlaps', () {
      const other = MediaSource(id: 'x', path: 'x', duration: Duration(seconds: 10));
      const a = Clip(
        id: 'a',
        source: _src,
        timelineStart: Duration(seconds: 0),
        sourceStart: Duration.zero,
        duration: Duration(seconds: 4),
      );
      const gap = Clip(
        id: 'g',
        source: _src,
        timelineStart: Duration(seconds: 5),
        sourceStart: Duration(seconds: 4),
        duration: Duration(seconds: 3),
      );
      const diffSrc = Clip(
        id: 'd',
        source: other,
        timelineStart: Duration(seconds: 4),
        sourceStart: Duration(seconds: 4),
        duration: Duration(seconds: 3),
      );
      const srcGap = Clip(
        id: 's',
        source: _src,
        timelineStart: Duration(seconds: 4),
        sourceStart: Duration(seconds: 5),
        duration: Duration(seconds: 3),
      );
      expect(tryMergeClips(a, gap), isNull);
      expect(tryMergeClips(a, diffSrc), isNull);
      expect(tryMergeClips(a, srcGap), isNull);
    });

    test('returns null when speeds differ', () {
      const a = Clip(
        id: 'a',
        source: _src,
        timelineStart: Duration(seconds: 0),
        sourceStart: Duration.zero,
        duration: Duration(seconds: 4),
        speed: 2.0,
      );
      const b = Clip(
        id: 'b',
        source: _src,
        timelineStart: Duration(seconds: 4),
        sourceStart: Duration(seconds: 2),
        duration: Duration(seconds: 4),
      );
      expect(tryMergeClips(a, b), isNull);
    });

    test('merges speed-adjusted source contiguity', () {
      // a: timeline 0..2s @2x -> source 0..4s; b: timeline 2..4s @2x -> 4..8s.
      const a = Clip(
        id: 'a',
        source: _src,
        timelineStart: Duration(seconds: 0),
        sourceStart: Duration.zero,
        duration: Duration(seconds: 2),
        speed: 2.0,
      );
      const b = Clip(
        id: 'b',
        source: _src,
        timelineStart: Duration(seconds: 2),
        sourceStart: Duration(seconds: 4),
        duration: Duration(seconds: 2),
        speed: 2.0,
      );
      final m = tryMergeClips(a, b);
      expect(m, isNotNull);
      expect(m!.duration, const Duration(seconds: 4));
      expect(m.speed, 2.0);
    });
  });

  group('setClipSpeed', () {
    test('2x halves the timeline duration', () {
      final c = setClipSpeed(_clip(), 2.0);
      expect(c.speed, 2.0);
      // 4s of source at 2x -> 8s? No: same 4s source segment at 2x -> 2s.
      // _clip covers source 2s..6s = 4s of source.
      expect(c.duration, const Duration(seconds: 2));
      expect(c.sourceDuration, const Duration(seconds: 4));
    });

    test('0.5x doubles the timeline duration', () {
      final c = setClipSpeed(_clip(), 0.5);
      expect(c.speed, 0.5);
      expect(c.duration, const Duration(seconds: 8));
    });

    test('clamps speed to 0.25..4.0', () {
      expect(setClipSpeed(_clip(), 99).speed, maxClipSpeed);
      expect(setClipSpeed(_clip(), 0.01).speed, minClipSpeed);
    });

    test('clamps duration to available source media', () {
      // _clip covers source 2s..6s (4s). At 0.25x that stretches to 16s of
      // timeline — inside the 8s of remaining source (8 / 0.25 = 32s cap).
      final c = setClipSpeed(_clip(), 0.25);
      expect(c.duration, const Duration(seconds: 16));
      // A clip already at the source end cannot grow past it: source
      // 8s..10s (2s) at 0.5x -> 4s timeline, within the 2s of source.
      const tail = Clip(
        id: 't',
        source: _src,
        timelineStart: Duration(seconds: 8),
        sourceStart: Duration(seconds: 8),
        duration: Duration(seconds: 2),
      );
      final slow = setClipSpeed(tail, 0.5);
      expect(slow.duration, const Duration(seconds: 4));
      expect(slow.sourceStart + slow.sourceDuration,
          lessThanOrEqualTo(_src.duration));
    });

    test('respects maxEnd to avoid overlapping the next clip', () {
      final c =
          setClipSpeed(_clip(), 0.5, maxEnd: const Duration(seconds: 10));
      // 4s of source at 0.5x wants 8s, but capped at 10s - 5s = 5s.
      expect(c.timelineEnd, const Duration(seconds: 10));
      expect(c.duration, const Duration(seconds: 5));
    });
  });

  group('speed-aware trim/split', () {    test('trimClipStart shifts source by delta * speed', () {
      final fast = setClipSpeed(_clip(), 2.0); // 5s..7s, source 2s..6s
      final c = trimClipStart(fast, const Duration(seconds: 6));
      expect(c.timelineStart, const Duration(seconds: 6));
      // 1s timeline delta * 2 = 2s source shift
      expect(c.sourceStart, const Duration(seconds: 4));
      expect(c.duration, const Duration(seconds: 1));
    });

    test('trimClipEnd clamps to source end scaled by speed', () {
      final fast = setClipSpeed(_clip(), 2.0); // source 2s..6s of 10s
      final c = trimClipEnd(fast, const Duration(seconds: 99));
      // max: 5s + (10s - 2s) / 2 = 9s
      expect(c.timelineEnd, const Duration(seconds: 9));
    });

    test('splitClipAt scales source offset by speed', () {
      final fast = setClipSpeed(_clip(), 2.0); // 5s..7s timeline, 2s..6s src
      final (first, second) = splitClipAt(fast, const Duration(seconds: 6));
      expect(first.duration, const Duration(seconds: 1));
      expect(second.sourceStart, const Duration(seconds: 4));
      expect(second.speed, 2.0);
    });
  });

  group('trimAudioStart/trimAudioEnd', () {
    const track = AudioTrack(
      id: 'a',
      path: '/tmp/song.mp3',
      name: 'song.mp3',
      timelineStart: Duration(seconds: 2),
      trimStart: Duration(seconds: 5),
      duration: Duration(seconds: 10),
      sourceDuration: Duration(seconds: 30),
    );

    test('trimAudioStart moves start and shifts trim offset', () {
      final t = trimAudioStart(track, const Duration(seconds: 4));
      expect(t.timelineStart, const Duration(seconds: 4));
      expect(t.trimStart, const Duration(seconds: 7));
      expect(t.duration, const Duration(seconds: 8));
    });

    test('trimAudioStart clamps at source beginning', () {
      // trimStart is 5s and timelineStart is 2s: dragging to -99s clamps at
      // minStart = 2s - 5s = -3s, where trimStart hits exactly 0.
      final t = trimAudioStart(track, const Duration(seconds: -99));
      expect(t.timelineStart, const Duration(seconds: -3));
      expect(t.trimStart, Duration.zero);
      expect(t.duration, const Duration(seconds: 15));
    });

    test('trimAudioStart never shrinks below minAudioDuration', () {
      final t = trimAudioStart(track, const Duration(seconds: 99));
      expect(t.duration, minAudioDuration);
    });

    test('trimAudioEnd extends and shrinks duration', () {
      final t = trimAudioEnd(track, const Duration(seconds: 20));
      // source allows up to 2s + (30s - 5s) = 27s.
      expect(t.timelineEnd, const Duration(seconds: 20));
      expect(t.trimStart, const Duration(seconds: 5));
    });

    test('trimAudioEnd clamps at source end', () {
      final t = trimAudioEnd(track, const Duration(seconds: 99));
      expect(t.timelineEnd, const Duration(seconds: 27));
    });

    test('trimAudioEnd never shrinks below minAudioDuration', () {
      final t = trimAudioEnd(track, const Duration(seconds: 2));
      expect(t.duration, minAudioDuration);
    });
  });
}
