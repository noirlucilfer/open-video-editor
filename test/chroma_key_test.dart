import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_video_editor/engine/ffmpeg_command.dart';
import 'package:open_video_editor/engine/video_engine.dart';

Clip _clip(String path, Duration dur, {ChromaKey? chromaKey}) {
  final src = MediaSource(id: 's', path: path, duration: dur);
  return Clip(
    id: 'c',
    source: src,
    timelineStart: Duration.zero,
    sourceStart: Duration.zero,
    duration: dur,
    chromaKey: chromaKey ?? const ChromaKey(),
  );
}

void main() {
  group('chroma key export', () {
    test('disabled chroma adds no keying filters', () {
      final project = TimelineProject(
        tracks: [
          VideoTrack(id: 'v', clips: [
            _clip('/tmp/a.mp4', const Duration(seconds: 4)),
          ])
        ],
      );
      final args = buildExportCommand(
          project, ExportConfig(outputPath: '/tmp/o.mp4'));
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(fc, isNot(contains('chromakey')));
    });

    test('enabled chroma keys color and composites over bg', () {
      final project = TimelineProject(
        tracks: [
          VideoTrack(id: 'v', clips: [
            _clip('/tmp/a.mp4', const Duration(seconds: 4),
                chromaKey: const ChromaKey(
                  enabled: true,
                  color: 0x00FF00,
                  similarity: 0.4,
                  blend: 0.2,
                  bgColor: 0x0000FF,
                )),
          ])
        ],
      );
      final args = buildExportCommand(
          project, ExportConfig(outputPath: '/tmp/o.mp4', width: 320, height: 240));
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(fc, contains('chromakey=0x00ff00:0.4:0.2'));
      expect(fc, contains('color=c=0x0000ff:s=320x240'));
      expect(fc, contains('[v0bg][v0k]overlay,format=yuv420p[v0]'));
    });
  });

  group('chroma key E2E', () {
    test('green background is replaced by blue', () async {
      // Green clip with a solid red box in the middle.
      final src = '/tmp/ck_src.mp4';
      var r = await Process.run('ffmpeg', [
        '-y',
        '-f', 'lavfi', '-i', 'color=c=0x00FF00:s=320x240:d=3:r=30',
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=3',
        '-vf', 'drawbox=x=120:y=80:w=80:h=80:c=red:t=fill',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-shortest', src,
      ]);
      expect(r.exitCode, 0);
      final ms =
          MediaSource(id: 's', path: src, duration: const Duration(seconds: 3));
      final project = TimelineProject(
        tracks: [
          VideoTrack(id: 'v', clips: [
            Clip(
              id: 'c',
              source: ms,
              timelineStart: Duration.zero,
              sourceStart: Duration.zero,
              duration: const Duration(seconds: 3),
              chromaKey: const ChromaKey(
                enabled: true,
                color: 0x00FF00,
                bgColor: 0x0000FF,
              ),
            )
          ])
        ],
      );
      const out = '/tmp/ck_out.mp4';
      final args = buildExportCommand(
          project, ExportConfig(outputPath: out, width: 320, height: 240));
      r = await Process.run('ffmpeg', ['-y', ...args]);
      expect(r.exitCode, 0);

      Future<List<int>> pixel(int x, int y) async {
        final img = '/tmp/ck_$x-$y.png';
        var rr = await Process.run(
            'ffmpeg', ['-y', '-ss', '1', '-i', out, '-frames:v', '1', img]);
        expect(rr.exitCode, 0);
        final px = await Process.run('ffmpeg', [
          '-i', img, '-vf', 'crop=1:1:$x:$y',
          '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-',
        ], stdoutEncoding: null);
        return (px.stdout as List<int>);
      }

      // Corner was green -> should now be blue.
      final bg = await pixel(10, 10);
      // Center was the red box -> should stay red.
      final box = await pixel(160, 120);
      expect(bg[2] > 150 && bg[0] < 100 && bg[1] < 100, isTrue,
          reason: 'keyed background should be blue, got $bg');
      expect(box[0] > 150 && box[2] < 100, isTrue,
          reason: 'red box should survive keying, got $box');
    });
  });
}
