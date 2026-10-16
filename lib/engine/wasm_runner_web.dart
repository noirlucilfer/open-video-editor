// Web implementation of the ffmpeg.wasm runner.
//
// Talks to window.oveWasm (web/ffmpeg_wasm.js) via dart:js_interop:
//   - polls loadProgress / exportProgress (no callback interop needed)
//   - input files are fetched from their blob URLs into the wasm MEMFS
//   - the browser download is triggered from JS after a successful run

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'ffmpeg_runner.dart';

@JS('oveWasm')
external OveWasmBridge? get oveWasm;

extension type OveWasmBridge._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> loadWasm();
  external JSPromise<JSNumber> runWasmExport(JSString payloadJson);
  external JSNumber get loadProgress;
  external JSNumber get exportProgress;
}

class FFmpegWasmRunner implements FFmpegRunner {
  FFmpegWasmRunner({this.onLoadProgress});

  /// Called with 0..1 while the wasm core downloads, then 1.0 when ready.
  final void Function(double)? onLoadProgress;

  static const _fontAssetUrl = 'assets/assets/fonts/DejaVuSans.ttf';

  @override
  Future<int> run(
    List<String> args, {
    Duration? total,
    void Function(double progress)? onProgress,
  }) async {
    final bridge = oveWasm;
    if (bridge == null) {
      throw StateError(
          'ffmpeg.wasm bridge not loaded (web/ffmpeg_wasm.js missing or blocked)');
    }

    // Phase 1: download + instantiate the core (~31MB, cached afterwards).
    final loadTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final p = bridge.loadProgress.toDartDouble;
      if (p >= 0) onLoadProgress?.call(p.clamp(0.0, 1.0));
    });
    try {
      await bridge.loadWasm().toDart.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw TimeoutException('ffmpeg.wasm load timed out'),
      );
    } finally {
      loadTimer.cancel();
    }
    onLoadProgress?.call(1.0);

    // Phase 2: rewrite -i paths to MEMFS names and run.
    final split = splitWasmArgs(args);
    final rewritten = split.args;
    final inputs = split.inputs;
    final outputName = split.outputName;

    final payload = jsonEncode({
      'args': rewritten,
      'inputs': inputs,
      'outputName': outputName,
      'fontUrl': _fontAssetUrl,
    });

    var peak = 0.0;
    final exportTimer =
        Timer.periodic(const Duration(milliseconds: 250), (_) {
      final p = bridge.exportProgress.toDartDouble;
      if (p >= 0) {
        final clamped = p.clamp(0.0, 1.0);
        if (clamped > peak) {
          peak = clamped;
          onProgress?.call(clamped);
        }
      }
    });
    try {
      final code = await bridge.runWasmExport(payload.toJS).toDart.timeout(
        const Duration(minutes: 30),
        onTimeout: () => throw TimeoutException('ffmpeg.wasm export timed out'),
      );
      final exitCode = code.toDartDouble.toInt();
      if (exitCode == 0 && peak < 1.0) onProgress?.call(1.0);
      return exitCode;
    } finally {
      exportTimer.cancel();
    }
  }
}
