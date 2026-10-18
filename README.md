# Open Video Editor

An open-source video editor inspired by CapCut — built from scratch with
100% original code (MIT licensed). One Flutter codebase targeting Android,
iOS, and Web, with real FFmpeg-powered export on every platform.

<a href="demo/demo.mp4"><img src="demo/demo.gif" width="480" alt="Demo reel"></a>

> Demo reel rendered by the app's own export engine: three clips joined
> with `wipeleft` and `slideup` xfade transitions plus a text overlay.

> **Legal note:** this project is inspired by CapCut's *features*, not its
> code. No proprietary code, assets, or resources from ByteDance are used
> here. Clean-room reimplementation only.

## Features

- **Timeline editing** — multi-track timeline with ruler, draggable
  playhead, selectable clips, and draggable trim handles
- **Trim / split / merge / delete** — pure, unit-tested timeline ops
- **Text overlays** — add, edit, reposition by dragging; keyframe animation
  of position and size, text color + background box, rendered in preview
  and export
- **Ken Burns** — per-clip slow zoom in/out with adjustable strength,
  previewed live and rendered at export
- **Color filters** — 7 per-clip presets (B&W, Sepia, Invert, Warm, Cool,
  Vintage)
- **Green screen** — per-clip chroma key with key-color picker, sensitivity
  and edge-softness sliders, composited over a chosen background color
- **Clip speed** — 0.5x–2x (up to 4x in the engine), timeline resampled
- **Background music** — audio tracks with trim handles, volume control,
  mixed at export
- **Stickers** — image overlays, draggable in preview, scaled at export,
  with keyframe animation of position and scale
- **Picture-in-picture** — video overlays with position, size and volume
  control, draggable in preview, composited (video + mixed audio) at export
- **Project save/load** — projects persist as JSON bundles with their media
  (save, open, delete from the Project menu); drafts auto-save every
  couple of seconds and restore on launch
- **Undo/redo** — every edit is revertable, including drag gestures
- **Transitions** — fade in/out per clip; crossfade between clips in 6
  styles (dissolve, wipe ←/→, slide ↑/↓, circle) with a live dissolve
  preview and xfade/acrossfade export
- **Real MP4 export** — a pure-Dart builder translates the timeline into
  an FFmpeg filter graph (trim/concat, filters, speed, fades, xfade,
  drawtext, audio mix, sticker overlays) → H.264 + AAC

## Export engines

| Platform    | Engine                          |
| ----------- | ------------------------------- |
| Android/iOS | ffmpeg-kit (`ffmpeg_kit_flutter_new`, Full GPL variant) |
| Web         | ffmpeg.wasm (single-threaded core, no COOP/COEP needed) |
| Desktop     | system `ffmpeg` binary (subprocess) |

Note: the mobile build links the Full-GPL ffmpeg-kit variant (for x264),
so distributed mobile binaries fall under GPL-3.0. The Dart code itself
is MIT.

## Architecture

```
lib/
├── main.dart                  # App entry
├── engine/
│   ├── video_engine.dart      # Portable engine contract + timeline models
│   ├── timeline_ops.dart      # Pure trim/split/merge/speed/audio-trim ops
│   ├── ffmpeg_command.dart    # Timeline -> FFmpeg filter graph (pure, tested)
│   ├── ffmpeg_engine.dart     # VideoEngine implementation
│   ├── ffmpeg_runner.dart     # Runner interface (process/kit/wasm/fake)
│   ├── ffmpeg_kit_runner.dart # Mobile runner (Android/iOS)
│   └── ffmpeg_wasm_runner.dart# Web runner (ffmpeg.wasm via JS bridge)
├── playback/
│   └── timeline_player.dart   # Preview playback: clip chaining, speed,
│                              # background-audio sync
├── media/
│   └── media_picker.dart      # Gallery / file pickers (video, image, audio)
└── ui/
    ├── editor_screen.dart     # Preview + transport + timeline shell
    └── timeline/
        └── timeline_view.dart # Lanes: video, text, audio, stickers + playhead
```

The design mirrors the classic mobile-editor split: a **native media
engine** (decode / filter / encode, FFmpeg-based) behind a Dart
`VideoEngine` interface, with the **UI layer** (timeline, preview,
transport) in Flutter. `buildExportCommand` is a pure function, so the
exact FFmpeg invocation is unit-tested without running anything.

## Developing

Requires Flutter 3.47+.

```bash
flutter pub get
flutter run              # desktop / connected device
flutter run -d chrome    # web (export runs fully in-browser via ffmpeg.wasm)
```

Platform folders (`android/`, `ios/`) are generated; build with
`flutter build apk` / `flutter build ipa` on a machine with the Android
SDK / Xcode.

```bash
flutter analyze   # must be clean
flutter test      # unit + widget tests
```

## Contributing

PRs welcome. Keep it original — do not submit code, assets, or resources
copied from proprietary apps.
