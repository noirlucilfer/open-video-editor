// Platform-conditional FFmpeg.wasm runner.
//
// Web builds use the real @ffmpeg/ffmpeg bridge (wasm_runner_web.dart);
// every other platform gets a stub that throws, since wasm export only
// makes sense in the browser.

export 'wasm_runner_stub.dart'
    if (dart.library.js_interop) 'wasm_runner_web.dart';
