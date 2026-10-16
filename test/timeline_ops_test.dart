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
  });
}
