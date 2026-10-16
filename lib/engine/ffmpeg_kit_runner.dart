// FFmpeg execution through the ffmpeg-kit plugin (Android/iOS/macOS/...).
//
// Takes the same argument list as [buildExportCommand] via
// [FFmpegKit.executeWithArgumentsAsync], so no shell quoting is needed.
// Progress comes from the statistics callback ([Statistics.getTime] is
// milliseconds of encoded output) and is reported monotonically.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:path_provider/path_provider.dart';

import 'ffmpeg_runner.dart';

class FFmpegKitRunner implements FFmpegRunner {
  @override
  Future<int> run(
    List<String> args, {
    Duration? total,
    void Function(double progress)? onProgress,
  }) async {
    final totalMs = total?.inMilliseconds ?? 0;
    var peak = 0.0;
    final done = Completer<int>();
    await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        final rc = await session.getReturnCode();
        done.complete(rc?.getValue() ?? -1);
      },
      null,
      (Statistics stats) {
        if (totalMs > 0) {
          final p = (stats.getTime() / totalMs).clamp(0.0, 1.0);
          if (p > peak) {
            peak = p;
            onProgress?.call(p);
          }
        }
      },
    );
    final code = await done.future;
    if (code == 0 && peak < 1.0) onProgress?.call(1.0);
    return code;
  }

  @override
  Future<Uint8List?> extractFrame(String inputPath, Duration at,
      {int width = 160}) async {
    try {
      final tmp = await getTemporaryDirectory();
      final out =
          '${tmp.path}/ove_thumb_${DateTime.now().microsecondsSinceEpoch}.png';
      final session = await FFmpegKit.executeWithArguments([
        '-hide_banner',
        '-loglevel',
        'error',
        '-ss',
        (at.inMilliseconds / 1000).toString(),
        '-i',
        inputPath,
        '-frames:v',
        '1',
        '-vf',
        'scale=$width:-1',
        '-y',
        out,
      ]);
      final rc = await session.getReturnCode();
      if (rc?.getValue() != 0) return null;
      final bytes = await File(out).readAsBytes();
      try {
        await File(out).delete();
      } catch (_) {}
      return bytes;
    } catch (_) {
      return null;
    }
  }
}
