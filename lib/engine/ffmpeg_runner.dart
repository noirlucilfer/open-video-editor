// Runs ffmpeg as a subprocess and reports progress.
//
// The runner is an interface so platforms pick their implementation:
//   - Android/iOS/macOS: [FFmpegKitRunner] (lib/engine/ffmpeg_kit_runner.dart)
//   - desktop / tests: [ProcessFFmpegRunner] shells out to an ffmpeg binary
//   - web: not supported; export is disabled in the UI.
//
// Use [createDefaultRunner] to pick automatically.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'ffmpeg_kit_runner.dart';
import 'ffmpeg_wasm_runner.dart';

/// Executes ffmpeg. Returns the process exit code (0 = success).
abstract class FFmpegRunner {
  Future<int> run(
    List<String> args, {
    Duration? total,
    void Function(double progress)? onProgress,
  });
}

/// Picks the right [FFmpegRunner] for the current platform:
/// ffmpeg.wasm in the browser, ffmpeg-kit on mobile, a subprocess
/// ffmpeg binary on desktop.
FFmpegRunner createDefaultRunner({void Function(double)? onWasmLoadProgress}) {
  if (kIsWeb) {
    return FFmpegWasmRunner(onLoadProgress: onWasmLoadProgress);
  }
  if (Platform.isAndroid || Platform.isIOS) return FFmpegKitRunner();
  return ProcessFFmpegRunner();
}

/// Rewrites ffmpeg [args] for the wasm runner: `-i <url>` inputs become
/// `-i <memfsName>` with descriptors for fetching into MEMFS, and the
/// output path is reduced to its file name. Pure for testing.
({List<String> args, List<Map<String, String>> inputs, String outputName})
    splitWasmArgs(List<String> args) {
  final inputs = <Map<String, String>>[];
  final rewritten = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '-i' && i + 1 < args.length) {
      final url = args[++i];
      final name = 'ove-in-${inputs.length}.mp4';
      inputs.add({'name': name, 'url': url});
      rewritten.addAll(['-i', name]);
    } else {
      rewritten.add(args[i]);
    }
  }
  final outputName = rewritten.last.split('/').last;
  rewritten[rewritten.length - 1] = outputName;
  return (args: rewritten, inputs: inputs, outputName: outputName);
}

/// Runs a locally installed ffmpeg binary via dart:io.
class ProcessFFmpegRunner implements FFmpegRunner {
  ProcessFFmpegRunner({this.executable = 'ffmpeg'});

  final String executable;

  @override
  Future<int> run(
    List<String> args, {
    Duration? total,
    void Function(double progress)? onProgress,
  }) async {
    final process = await Process.start(executable, [
      '-hide_banner',
      '-nostats',
      '-progress',
      'pipe:1',
      ...args,
    ]);
    final totalMs = total?.inMilliseconds ?? 0;
    // ffmpeg's out_time_ms can regress (audio/video interleaving), so only
    // ever report increases: progress bars must not move backwards.
    var peak = 0.0;
    void report(double p) {
      if (p > peak) {
        peak = p;
        onProgress?.call(p);
      }
    }

    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.startsWith('out_time_ms=')) {
        final ms =
            int.tryParse(line.substring('out_time_ms='.length).trim()) ?? 0;
        if (totalMs > 0) {
          report((ms / totalMs).clamp(0.0, 1.0));
        }
      } else if (line.trim() == 'progress=end') {
        report(1.0);
      }
    }
    // Drain stderr so a chatty ffmpeg never blocks on a full pipe.
    await process.stderr.drain();
    final code = await process.exitCode;
    if (code == 0) report(1.0);
    return code;
  }
}

/// A fake runner for widget tests: replays canned progress, then succeeds.
class FakeFFmpegRunner implements FFmpegRunner {
  FakeFFmpegRunner({this.exitCode = 0, this.steps = 5});

  final int exitCode;
  final int steps;
  List<String>? lastArgs;

  @override
  Future<int> run(
    List<String> args, {
    Duration? total,
    void Function(double progress)? onProgress,
  }) async {
    lastArgs = args;
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      onProgress?.call(i / steps);
    }
    return exitCode;
  }
}
