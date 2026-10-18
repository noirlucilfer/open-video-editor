import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_video_editor/engine/ffmpeg_command.dart';
import 'package:open_video_editor/engine/video_engine.dart';

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

void main() {
  group('PiP export', () {
    test('video overlay becomes scaled overlay + mixed audio', () {
      final project = TimelineProject(
        tracks: [
          VideoTrack(id: 'v', clips: [
            _clip('/tmp/a.mp4', const Duration(seconds: 6)),
          ])
        ],
        videoOverlays: [
          const VideoOverlay(
            id: 'p1',
            path: '/tmp/pip.mp4',
            name: 'pip.mp4',
            start: Duration(seconds: 1),
            end: Duration(seconds: 4),
            x: 0.8,
            y: 0.2,
            scale: 0.5,
            volume: 0.5,
          ),
        ],
      );
      final args = buildExportCommand(
          project, ExportConfig(outputPath: '/tmp/o.mp4', width: 320, height: 240));
      final fc = args[args.indexOf('-filter_complex') + 1];
      // input 1 = the PiP video, trimmed to the 3s window
      expect(args, contains('-i'));
      expect(fc, contains('[1:v]scale=160:-1,fps=30,setpts=PTS-STARTPTS[pvs0]'));
      expect(fc, contains("overlay=x='(0.8*W-w/2)':y='(0.2*H-h/2)'"));
      expect(fc, contains("enable='between(t,1.0,4.0)'"));
      // audio mixed under the main track
      expect(fc, contains('[1:a]aresample=44100'));
      expect(fc, contains('volume=0.5'));
      expect(fc, contains('amix=inputs=2'));
    });

    test('muted PiP adds no audio mix', () {
      final project = TimelineProject(
        tracks: [
          VideoTrack(id: 'v', clips: [
            _clip('/tmp/a.mp4', const Duration(seconds: 6)),
          ])
        ],
        videoOverlays: [
          const VideoOverlay(
            id: 'p1',
            path: '/tmp/pip.mp4',
            name: 'pip.mp4',
            start: Duration(seconds: 1),
            end: Duration(seconds: 4),
            volume: 0.0,
          ),
        ],
      );
      final args = buildExportCommand(
          project, ExportConfig(outputPath: '/tmp/o.mp4'));
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(fc, isNot(contains('amix')));
      expect(fc, contains('[1:v]scale='));
    });
  });

  group('PiP E2E', () {
    test('PiP video is composited over the main clip', () async {
      Future<void> gen(List<String> extra, String out) async {
        final r = await Process.run('ffmpeg', ['-y', ...extra, out]);
        expect(r.exitCode, 0);
      }

      // Main: red 4s with audio. PiP: blue 4s with audio.
      await gen([
        '-f', 'lavfi', '-i', 'color=c=red:s=320x240:d=4:r=30',
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=4',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest',
      ], '/tmp/pip_main.mp4');
      await gen([
        '-f', 'lavfi', '-i', 'color=c=blue:s=160x120:d=4:r=30',
        '-f', 'lavfi', '-i', 'sine=frequency=880:duration=4',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest',
      ], '/tmp/pip_pip.mp4');

      MediaSource ms(String id, String p) =>
          MediaSource(id: id, path: p, duration: const Duration(seconds: 4));
      final project = TimelineProject(
        tracks: [
          VideoTrack(id: 'v', clips: [
            Clip(
                id: 'c',
                source: ms('m', '/tmp/pip_main.mp4'),
                timelineStart: Duration.zero,
                sourceStart: Duration.zero,
                duration: const Duration(seconds: 4))
          ])
        ],
        videoOverlays: [
          VideoOverlay(
            id: 'p1',
            path: '/tmp/pip_pip.mp4',
            name: 'pip.mp4',
            start: const Duration(seconds: 1),
            end: const Duration(seconds: 3),
            x: 0.8,
            y: 0.8,
            scale: 0.5,
            volume: 0.5,
          ),
        ],
      );
      const out = '/tmp/pip_out.mp4';
      final args = buildExportCommand(
          project, ExportConfig(outputPath: out, width: 320, height: 240));
      final r = await Process.run('ffmpeg', ['-y', ...args]);
      expect(r.exitCode, 0);

      Future<List<int>> pixel(String at, int x, int y) async {
        final img = '/tmp/pip_${at}_$x-$y.png';
        var rr = await Process.run(
            'ffmpeg', ['-y', '-ss', at, '-i', out, '-frames:v', '1', img]);
        expect(rr.exitCode, 0);
        final px = await Process.run('ffmpeg', [
          '-i', img, '-vf', 'crop=1:1:$x:$y',
          '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-',
        ], stdoutEncoding: null);
        return (px.stdout as List<int>);
      }

      // t=2: inside the PiP window. PiP center = (256,192), 160x90 box.
      final inside = await pixel('2', 250, 190);
      // Far from the PiP box -> main red.
      final outside = await pixel('2', 30, 30);
      // t=0.5: before the PiP window -> red everywhere.
      final before = await pixel('0.5', 250, 190);
      expect(inside[2] > 150 && inside[0] < 100, isTrue,
          reason: 'PiP region should be blue, got $inside');
      expect(outside[0] > 150 && outside[2] < 100, isTrue,
          reason: 'outside PiP should stay red, got $outside');
      expect(before[0] > 150 && before[2] < 100, isTrue,
          reason: 'before PiP window should be red, got $before');
    });
  });
}
