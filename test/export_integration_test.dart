// End-to-end export verification with a real ffmpeg binary.
//
// Generates synthetic clips, exports a TimelineProject through
// FfmpegVideoEngine + ProcessFFmpegRunner, then verifies the output with
// ffprobe (duration, resolution, streams, codecs).
//
// Skipped automatically when ffmpeg/ffprobe are not on PATH.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_video_editor/engine/ffmpeg_engine.dart';
import 'package:open_video_editor/engine/video_engine.dart';

Future<bool> _hasBinary(String name) async {
  try {
    final r = await Process.run('which', [name]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<void> _generateClip(String path, int seed) async {
  final r = await Process.run('ffmpeg', [
    '-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'lavfi', '-i', 'testsrc=duration=10:size=320x240:rate=30',
    '-f', 'lavfi', '-i', 'sine=frequency=${440 + seed * 110}:duration=10',
    '-pix_fmt', 'yuv420p',
    '-c:v', 'libx264', '-preset', 'ultrafast',
    '-c:a', 'aac',
    path,
  ]);
  if (r.exitCode != 0) throw Exception('clip generation failed: ${r.stderr}');
}

Future<Map<String, dynamic>> _probe(String path) async {
  final r = await Process.run('ffprobe', [
    '-hide_banner', '-loglevel', 'error',
    '-show_entries', 'stream=codec_name,width,height,codec_type',
    '-show_entries', 'format=duration',
    '-of', 'json',
    path,
  ]);
  if (r.exitCode != 0) throw Exception('ffprobe failed');
  final json = jsonDecode(r.stdout as String) as Map<String, dynamic>;
  final streams = (json['streams'] as List).cast<Map<String, dynamic>>();
  final video = streams.firstWhere((s) => s['codec_type'] == 'video');
  final audio = streams.firstWhere((s) => s['codec_type'] == 'audio');
  return {
    'vcodec': video['codec_name'],
    'acodec': audio['codec_name'],
    'width': video['width'],
    'height': video['height'],
    'duration': double.parse((json['format'] as Map)['duration'] as String),
  };
}

void main() {
  test('real ffmpeg export: trim + concat + filter + fade + text', () async {
    if (!await _hasBinary('ffmpeg') || !await _hasBinary('ffprobe')) {
      markTestSkipped('ffmpeg/ffprobe not on PATH');
    }

    final tmp = await Directory.systemTemp.createTemp('ove_export_');
    final clipAPath = '${tmp.path}/a.mp4';
    final clipBPath = '${tmp.path}/b.mp4';
    await _generateClip(clipAPath, 0);
    await _generateClip(clipBPath, 1);
    final outPath = '${tmp.path}/out.mp4';

    MediaSource src(String id, String path) =>
        MediaSource(id: id, path: path, duration: const Duration(seconds: 10));

    final project = TimelineProject(
      tracks: [
        VideoTrack(id: 'v1', clips: [
          Clip(
            id: 'c1',
            source: src('s1', clipAPath),
            timelineStart: Duration.zero,
            sourceStart: const Duration(seconds: 2),
            duration: const Duration(seconds: 4),
            filter: VideoFilter.sepia,
            transitionIn: const ClipTransition(
                type: TransitionType.fade, duration: Duration(seconds: 1)),
          ),
          Clip(
            id: 'c2',
            source: src('s2', clipBPath),
            timelineStart: const Duration(seconds: 4),
            sourceStart: const Duration(seconds: 1),
            duration: const Duration(seconds: 3),
            filter: VideoFilter.invert,
            transitionOut: const ClipTransition(
                type: TransitionType.fade, duration: Duration(seconds: 1)),
          ),
        ]),
      ],
      overlays: [
        const TextOverlay(
          id: 't1',
          text: 'Halo dunia',
          start: Duration(seconds: 1),
          end: Duration(seconds: 6),
        ),
      ],
    );

    final engine = FfmpegVideoEngine(
      fontFile: '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    );
    await engine.initialize();
    var lastProgress = 0.0;
    var progressCalls = 0;
    await engine.exportProject(
      project,
      ExportConfig(outputPath: outPath, width: 1080, height: 1920, fps: 30),
      onProgress: (p) {
        progressCalls++;
        expect(p, greaterThanOrEqualTo(lastProgress));
        expect(p, inInclusiveRange(0.0, 1.0));
        lastProgress = p;
      },
    );
    await engine.dispose();

    expect(progressCalls, greaterThan(0));
    expect(lastProgress, 1.0);
    expect(await File(outPath).exists(), isTrue);

    final info = await _probe(outPath);
    expect(info['vcodec'], 'h264');
    expect(info['acodec'], 'aac');
    expect(info['width'], 1080);
    expect(info['height'], 1920);
    // 4s + 3s of content (tolerance for encoder rounding)
    expect(info['duration'], closeTo(7.0, 0.5));

    await tmp.delete(recursive: true);
  });
}
