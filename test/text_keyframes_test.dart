import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_video_editor/engine/ffmpeg_command.dart';
import 'package:open_video_editor/engine/video_engine.dart';

TextOverlay _text({List<TextKeyframe> kfs = const []}) => TextOverlay(
      id: 't',
      text: 'Hi',
      start: const Duration(seconds: 1),
      end: const Duration(seconds: 5),
      fontSize: 32,
      x: 0.5,
      y: 0.5,
      keyframes: kfs,
    );

Clip _clip(String path, Duration dur) {
  final src = MediaSource(id: 's', path: path, duration: dur);
  return Clip(
    id: 'c',
    source: src,
    timelineStart: Duration.zero,
    sourceStart: Duration.zero,
    duration: dur,
  );
}

TimelineProject _project({List<TextOverlay> overlays = const []}) =>
    TimelineProject(
      tracks: [
        VideoTrack(id: 'v', clips: [
          _clip('/tmp/a.mp4', const Duration(seconds: 6))
        ])
      ],
      overlays: overlays,
    );

String _fc(List<String> args) =>
    args[args.indexOf('-filter_complex') + 1];

void main() {
  group('textPoseAt', () {
    test('no keyframes -> base pose', () {
      final p = textPoseAt(_text(), const Duration(seconds: 1));
      expect((p.x, p.y, p.fontSize), (0.5, 0.5, 32));
    });

    test('before first keyframe lerps from base', () {
      final p = textPoseAt(
          _text(kfs: [
            const TextKeyframe(
                time: Duration(seconds: 2), x: 1.0, y: 0.0, fontSize: 64),
          ]),
          const Duration(seconds: 1));
      expect(p.x, closeTo(0.75, 1e-9));
      expect(p.y, closeTo(0.25, 1e-9));
      expect(p.fontSize, closeTo(48, 1e-9));
    });

    test('between keyframes interpolates', () {
      final p = textPoseAt(
          _text(kfs: [
            const TextKeyframe(
                time: Duration(seconds: 1), x: 0.0, y: 0.0, fontSize: 20),
            const TextKeyframe(
                time: Duration(seconds: 3), x: 1.0, y: 1.0, fontSize: 60),
          ]),
          const Duration(seconds: 2));
      expect(p.x, closeTo(0.5, 1e-9));
      expect(p.fontSize, closeTo(40, 1e-9));
    });

    test('past last keyframe holds its pose', () {
      final p = textPoseAt(
          _text(kfs: [
            const TextKeyframe(
                time: Duration(seconds: 1), x: 0.2, y: 0.8, fontSize: 90),
          ]),
          const Duration(seconds: 9));
      expect((p.x, p.y, p.fontSize), (0.2, 0.8, 90));
    });
  });

  group('keyframed text export', () {
    test('keyframes become piecewise drawtext expressions', () {
      final args = buildExportCommand(
        _project(overlays: [
          _text(kfs: [
            const TextKeyframe(
                time: Duration(seconds: 2), x: 0.9, y: 0.1, fontSize: 64),
          ]),
        ]),
        ExportConfig(outputPath: '/tmp/o.mp4'),
      );
      final fc = _fc(args);
      // overlay starts at t=1, keyframe at t=3
      expect(fc, contains('if(between(t,1,3)'));
      expect(fc, contains("fontsize='("));
      expect(fc, contains('text_w/2'));
    });

    test('static text keeps centered simple expressions', () {
      final args = buildExportCommand(
        _project(overlays: [_text()]),
        ExportConfig(outputPath: '/tmp/o.mp4'),
      );
      final fc = _fc(args);
      expect(fc, contains("fontsize='(32)'"));
      expect(fc, contains("x='((0.5)*w-text_w/2)'"));
      expect(fc, contains("enable='between(t,1.0,5.0)'"));
    });
  });

  group('text keyframe E2E', () {
    test('animated text moves across the frame', () async {
      const font = 'assets/fonts/DejaVuSans.ttf';
      final src = '/tmp/tkf_bg.mp4';
      var r = await Process.run('ffmpeg', [
        '-y',
        '-f', 'lavfi', '-i', 'color=c=black:s=320x240:d=4:r=30',
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=4',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-shortest', src,
      ]);
      expect(r.exitCode, 0);
      final ms =
          MediaSource(id: 's', path: src, duration: const Duration(seconds: 4));
      final project = TimelineProject(
        tracks: [
          VideoTrack(id: 'v', clips: [
            Clip(
                id: 'c',
                source: ms,
                timelineStart: Duration.zero,
                sourceStart: Duration.zero,
                duration: const Duration(seconds: 4))
          ])
        ],
        overlays: [
          TextOverlay(
            id: 't',
            text: 'HELLO',
            start: Duration.zero,
            end: const Duration(seconds: 4),
            fontSize: 48,
            x: 0.2,
            y: 0.5,
            keyframes: const [
              TextKeyframe(
                  time: Duration(seconds: 3), x: 0.8, y: 0.5, fontSize: 48),
            ],
          ),
        ],
      );
      const out = '/tmp/tkf_out.mp4';
      final args = buildExportCommand(
          project,
          ExportConfig(outputPath: out, width: 320, height: 240),
          fontFile: font);
      r = await Process.run('ffmpeg', ['-y', ...args]);
      expect(r.exitCode, 0);

      Future<double> meanBrightness(String at, int x) async {
        final img = '/tmp/tkf_$at-$x.png';
        var rr = await Process.run('ffmpeg',
            ['-y', '-ss', at, '-i', out, '-frames:v', '1', img]);
        expect(rr.exitCode, 0);
        final px = await Process.run('ffmpeg', [
          '-i', img, '-vf', 'crop=100:240:$x:0',
          '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-',
        ], stdoutEncoding: null);
        final bytes = px.stdout as List<int>;
        var sum = 0;
        for (final b in bytes) {
          sum += b;
        }
        return sum / bytes.length;
      }

      // t=0.2: text near left -> left region bright, right dark.
      final leftEarly = await meanBrightness('0.2', 0);
      final rightEarly = await meanBrightness('0.2', 220);
      // t=3.8: text near right -> swapped.
      final leftLate = await meanBrightness('3.8', 0);
      final rightLate = await meanBrightness('3.8', 220);
      expect(leftEarly, greaterThan(rightEarly + 5));
      expect(rightLate, greaterThan(leftLate + 5));
    });
  });
}
