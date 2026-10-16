import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_video_editor/engine/ffmpeg_command.dart';
import 'package:open_video_editor/engine/video_engine.dart';

Future<List<int>> pixel(String video, String at, int x) async {
  final img = '/tmp/kf_f_${at}_$x.png';
  var r = await Process.run('ffmpeg', ['-y', '-ss', at, '-i', video, '-frames:v', '1', img]);
  expect(r.exitCode, 0);
  final px = await Process.run('ffmpeg', ['-i', img, '-vf', 'crop=1:1:$x:120',
      '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], stdoutEncoding: null);
  return (px.stdout as List<int>);
}

void main() {
  test('animated sticker moves across the frame', () async {
    final src = '/tmp/kf_bg.mp4';
    var r = await Process.run('ffmpeg', ['-y', '-f', 'lavfi', '-i',
        'color=c=red:s=320x240:d=4:r=30', '-f', 'lavfi', '-i',
        'sine=frequency=440:duration=4', '-c:v', 'libx264', '-pix_fmt',
        'yuv420p', '-c:a', 'aac', '-shortest', src]);
    expect(r.exitCode, 0);
    final ms = MediaSource(id: 's', path: src, duration: const Duration(seconds: 4));
    final project = TimelineProject(
      tracks: [VideoTrack(id: 'v', clips: [Clip(id: 'c', source: ms,
          timelineStart: Duration.zero, sourceStart: Duration.zero,
          duration: const Duration(seconds: 4))])],
      stickers: [StickerOverlay(id: 'st', path: '/tmp/kf_sticker.png', name: 'b.png',
          start: Duration.zero, end: const Duration(seconds: 4),
          x: 0.1, y: 0.5, scale: 1.0, keyframes: [
            const StickerKeyframe(time: Duration(seconds: 3), x: 0.9, y: 0.5, scale: 1.0),
          ])],
    );
    const out = '/tmp/kf_out.mp4';
    final args = buildExportCommand(project, ExportConfig(outputPath: out, width: 320, height: 240));
    r = await Process.run('ffmpeg', ['-y', ...args]);
    expect(r.exitCode, 0);

    // t=0.2: sticker near left (center ~49) -> blue pixel there
    final left = await pixel(out, '0.2', 49);
    // t=3.8: sticker near right (center ~288) -> blue there, red at x=49
    final rightAtSticker = await pixel(out, '3.8', 288);
    final rightAtLeft = await pixel(out, '3.8', 49);
    expect(left[2] > 150 && left[0] < 100, isTrue,
        reason: 'sticker should be left at t=0.2');
    expect(rightAtSticker[2] > 150 && rightAtSticker[0] < 100, isTrue,
        reason: 'sticker should be right at t=3.8');
    expect(rightAtLeft[0] > 150 && rightAtLeft[2] < 100, isTrue,
        reason: 'left side should be red again at t=3.8');
  });
}
