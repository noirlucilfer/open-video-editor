# Contributing to Open Video Editor

Thanks for wanting to help! This is a 100% original, MIT-licensed codebase —
no proprietary code, no copied snippets. Keep it that way.

## Setup

Requires Flutter 3.47+ (Dart 3.13+).

```sh
flutter pub get
flutter run              # desktop / connected device
flutter run -d chrome    # web (export runs fully in-browser via ffmpeg.wasm)
```

Desktop export shells out to a system `ffmpeg`/`ffprobe`; make sure they are
on your PATH. Mobile export uses ffmpeg-kit (Full GPL variant — see the
licensing note in README.md). Web export needs no local ffmpeg.

## Before you push

```sh
flutter analyze          # must report no issues
flutter test             # full suite must pass
```

CI runs `pub get` → `analyze` → `test` → `build web` on every push/PR to
`master`, plus a release workflow that builds a signed APK on `v*` tags.

## Architecture (the 30-second version)

```
lib/
├── main.dart
├── engine/
│   ├── video_engine.dart     # Pure data model: Clip, TextOverlay, StickerOverlay,
│   │                         # keyframes, ChromaKey, TimelineProject. No UI, no I/O.
│   ├── timeline_ops.dart     # Pure timeline editing: trim/split/merge/delete/speed.
│   ├── ffmpeg_command.dart   # Pure TimelineProject -> FFmpeg argv builder.
│   │                         # THIS is where export features live. Keep it pure:
│   │                         # no Process calls, no platform checks.
│   ├── project_io.dart       # Project save/load: versioned JSON + media bundle.
│   ├── undo_history.dart     # Generic undo/redo stack for project snapshots.
│   └── ffmpeg_runner.dart    # Runs the argv: subprocess (desktop/test),
│                             # ffmpeg-kit (mobile), ffmpeg.wasm (web).
└── ui/
    ├── editor_screen.dart    # The editor: preview, timeline, dialogs.
    └── timeline_player.dart  # Playhead-synced multi-clip playback.
```

Rules of thumb:

- **Model changes are pure.** New fields go in `video_engine.dart` with
  `copyWith`; timeline mutations go in `timeline_ops.dart` with unit tests.
- **Export features go in `ffmpeg_command.dart`** as filter-graph fragments,
  covered by builder unit tests in `test/ffmpeg_command_test.dart` (or a new
  focused test file). If the fragment is tricky (expressions, label reuse),
  add a real-ffmpeg E2E test like `test/chroma_key_test.dart` — CI installs
  ffmpeg, so they run there too.
- **Preview vs export parity.** The preview is an approximation (video_player
  + Flutter widgets). If an effect can't be previewed (e.g. chroma key),
  say so in the UI instead of faking it.
- **Keep the web runner working.** Anything using `dart:io` needs the
  conditional-import pattern already used by the runners.

## Pull requests

- One feature/fix per PR, with tests. Bug fixes should add a regression test.
- Update README.md's feature list if user-visible behavior changes.
- Write commit messages like the history does: short imperative subject,
  details in the body (`git log --oneline -10` for examples).

## Reporting bugs / requesting features

Use the issue templates — include the Flutter version (`flutter --version`),
the platform (Android/iOS/web/desktop), and for export bugs the smallest
project that reproduces it (clip count, effects used).
