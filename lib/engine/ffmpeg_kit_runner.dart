// FFmpeg execution through the ffmpeg-kit plugin (Android/iOS/macOS/...).
//
// Takes the same argument list as [buildExportCommand] via
// [FFmpegKit.executeWithArgumentsAsync], so no shell quoting is needed.
// Progress comes from the statistics callback ([Statistics.getTime] is
// milliseconds of encoded output) and is reported monotonically.

import 'dart:async';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';

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
}
