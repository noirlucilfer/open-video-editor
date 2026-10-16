// Stub used on non-web platforms: wasm export only exists in the browser.

import 'ffmpeg_runner.dart';

class FFmpegWasmRunner implements FFmpegRunner {
  FFmpegWasmRunner({void Function(double)? onLoadProgress});

  @override
  Future<int> run(
    List<String> args, {
    Duration? total,
    void Function(double progress)? onProgress,
  }) =>
      throw UnsupportedError('FFmpeg.wasm export is only available on web');
}
