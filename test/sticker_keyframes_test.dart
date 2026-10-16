import 'package:flutter_test/flutter_test.dart';
import 'package:open_video_editor/engine/ffmpeg_command.dart';
import 'package:open_video_editor/engine/video_engine.dart';

StickerOverlay _sticker({List<StickerKeyframe> kfs = const []}) =>
    StickerOverlay(
      id: 's',
      path: '/tmp/s.png',
      name: 's.png',
      start: const Duration(seconds: 2),
      end: const Duration(seconds: 6),
      x: 0.5,
      y: 0.5,
      scale: 1.0,
      keyframes: kfs,
    );

void main() {
  group('stickerPoseAt', () {
    test('no keyframes -> base pose', () {
      final p = stickerPoseAt(
          _sticker(), const Duration(seconds: 1));
      expect((p.x, p.y, p.scale), (0.5, 0.5, 1.0));
    });

    test('before first keyframe lerps from base pose', () {
      final p = stickerPoseAt(
          _sticker(kfs: [
            const StickerKeyframe(
                time: Duration(seconds: 2), x: 1.0, y: 0.0, scale: 2.0),
          ]),
          const Duration(seconds: 1));
      expect(p.x, closeTo(0.75, 1e-9));
      expect(p.y, closeTo(0.25, 1e-9));
      expect(p.scale, closeTo(1.5, 1e-9));
    });

    test('between keyframes interpolates', () {
      final p = stickerPoseAt(
          _sticker(kfs: [
            const StickerKeyframe(time: Duration(seconds: 1), x: 0.0, y: 0.0),
            const StickerKeyframe(time: Duration(seconds: 3), x: 1.0, y: 1.0),
          ]),
          const Duration(seconds: 2));
      expect(p.x, closeTo(0.5, 1e-9));
      expect(p.y, closeTo(0.5, 1e-9));
    });

    test('past last keyframe holds its pose', () {
      final p = stickerPoseAt(
          _sticker(kfs: [
            const StickerKeyframe(
                time: Duration(seconds: 1), x: 0.2, y: 0.8, scale: 3.0),
          ]),
          const Duration(seconds: 9));
      expect((p.x, p.y, p.scale), (0.2, 0.8, 3.0));
    });
  });

  group('keyframed sticker export', () {
    Clip clip(String id, String path, Duration start, Duration dur) {
      final src = MediaSource(id: 'src-$id', path: path, duration: dur);
      return Clip(
        id: id,
        source: src,
        timelineStart: start,
        sourceStart: Duration.zero,
        duration: dur,
      );
    }

    test('keyframes become piecewise overlay expressions', () {
      final project = TimelineProject(
        tracks: [
          VideoTrack(id: 'v', clips: [
            clip('c', '/tmp/a.mp4', Duration.zero,
                const Duration(seconds: 8)),
          ])
        ],
        stickers: [
          _sticker(kfs: [
            const StickerKeyframe(
                time: Duration(seconds: 2), x: 1.0, y: 0.0, scale: 2.0),
          ]),
        ],
      );
      final args = buildExportCommand(
          project, ExportConfig(outputPath: '/tmp/o.mp4'));
      final fc = args[args.indexOf('-filter_complex') + 1];
      // animated scale + per-frame eval
      expect(fc, contains('eval=frame'));
      expect(fc, contains('if(between(t,2,4)'));
      // base pose at sticker start (t=2), keyframe at t=4
      expect(fc, contains('0.5+(1-0.5)*(t-2)/(4-2)'));
    });

    test('static sticker keeps the old simple overlay', () {
      final project = TimelineProject(
        tracks: [
          VideoTrack(id: 'v', clips: [
            clip('c', '/tmp/a.mp4', Duration.zero,
                const Duration(seconds: 8)),
          ])
        ],
        stickers: [_sticker()],
      );
      final args = buildExportCommand(
          project, ExportConfig(outputPath: '/tmp/o.mp4'));
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(fc, isNot(contains('eval=frame')));
      expect(fc, contains("overlay=x='(0.5*W-w/2)'"));
    });
  });
}
