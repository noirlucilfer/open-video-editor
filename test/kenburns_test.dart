import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_video_editor/engine/ffmpeg_command.dart';
import 'package:open_video_editor/engine/video_engine.dart';

Clip _clip(Duration dur, KenBurns kb) {
  final src = MediaSource(id: 's', path: '/tmp/a.mp4', duration: dur);
  return Clip(
    id: 'c',
    source: src,
    timelineStart: Duration.zero,
    sourceStart: Duration.zero,
    duration: dur,
    kenBurns: kb,
  );
}

TimelineProject _project(Clip clip) => TimelineProject(
      tracks: [
        VideoTrack(id: 'v', clips: [clip])
      ],
    );

String _fc(List<String> args) =>
    args[args.indexOf('-filter_complex') + 1];

void main() {
  group('Ken Burns export', () {
    test('disabled adds nothing', () {
      final args = buildExportCommand(
          _project(_clip(const Duration(seconds: 4), const KenBurns())),
          ExportConfig(outputPath: '/tmp/o.mp4'));
      expect(_fc(args), isNot(contains('zoompan')));
    });

    test('zoom in grows over the clip', () {
      final args = buildExportCommand(
          _project(_clip(
              const Duration(seconds: 4),
              const KenBurns(enabled: true, zoomIn: true, strength: 0.25))),
          ExportConfig(outputPath: '/tmp/o.mp4', width: 320, height: 240));
      final fc = _fc(args);
      expect(fc, contains("1+0.25*(in/120)"));
      expect(fc, contains('zoompan'));
      expect(fc, contains('s=320x240'));
    });

    test('zoom out shrinks over the clip', () {
      final args = buildExportCommand(
          _project(_clip(
              const Duration(seconds: 4),
              const KenBurns(enabled: true, zoomIn: false, strength: 0.5))),
          ExportConfig(outputPath: '/tmp/o.mp4', width: 320, height: 240));
      expect(_fc(args), contains('1+0.5*(1-(in/120))'));
    });

    test('accounts for clip speed in the progress', () {
      final src = MediaSource(id: 's', path: '/tmp/a.mp4', duration: const Duration(seconds: 8));
      final clip = Clip(
        id: 'c',
        source: src,
        timelineStart: Duration.zero,
        sourceStart: Duration.zero,
        duration: const Duration(seconds: 4),
        speed: 2.0,
        kenBurns: const KenBurns(enabled: true),
      );
      final args = buildExportCommand(_project(clip),
          ExportConfig(outputPath: '/tmp/o.mp4', width: 320, height: 240));
      // 4s at 2x speed -> 2s of output
      expect(_fc(args), contains('(in/60)'));
    });
  });

  group('Ken Burns E2E', () {
    test('zoom in enlarges the picture over time', () async {
      // Black clip with a 20px red square dead center.
      final src = '/tmp/kb_src.mp4';
      var r = await Process.run('ffmpeg', [
        '-y',
        '-f', 'lavfi', '-i', 'color=c=black:s=320x240:d=4:r=30',
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=4',
        '-vf', 'drawbox=x=150:y=110:w=20:h=20:c=red:t=fill',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-shortest', src,
      ]);
      expect(r.exitCode, 0);
      final ms =
          MediaSource(id: 's', path: src, duration: const Duration(seconds: 4));
      final project = _project(Clip(
        id: 'c',
        source: ms,
        timelineStart: Duration.zero,
        sourceStart: Duration.zero,
        duration: const Duration(seconds: 4),
        kenBurns: const KenBurns(enabled: true, zoomIn: true, strength: 1.0),
      ));
      const out = '/tmp/kb_out.mp4';
      final args = buildExportCommand(
          project, ExportConfig(outputPath: out, width: 320, height: 240));
      r = await Process.run('ffmpeg', ['-y', ...args]);
      expect(r.exitCode, 0);

      Future<List<int>> pixel(String at, int x, int y) async {
        final img = '/tmp/kb_${at}_$x-$y.png';
        var rr = await Process.run(
            'ffmpeg', ['-y', '-ss', at, '-i', out, '-frames:v', '1', img]);
        expect(rr.exitCode, 0);
        final px = await Process.run('ffmpeg', [
          '-i', img, '-vf', 'crop=1:1:$x:$y',
          '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-',
        ], stdoutEncoding: null);
        return (px.stdout as List<int>);
      }

      // (145,120): 15px left of center. At t=0.2 the square is ~21px wide
      // -> outside (black). At t=3.8 scale ~1.95x -> inside (red).
      final early = await pixel('0.2', 145, 120);
      final late = await pixel('3.8', 145, 120);
      expect(early[0] < 100 && early[2] < 100, isTrue,
          reason: 'square should not reach (145,120) early, got $early');
      expect(late[0] > 150, isTrue,
          reason: 'zoomed square should cover (145,120) late, got $late');
    });
  });
}
