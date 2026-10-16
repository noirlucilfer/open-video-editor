# Open Video Editor

An open-source video editor inspired by CapCut — built from scratch with
100% original code (MIT licensed). One Flutter codebase targeting Android,
iOS, and Web.

> **Legal note:** this project is inspired by CapCut's *features*, not its
> code. No proprietary code, assets, or resources from ByteDance are used
> here. Clean-room reimplementation only.

## Architecture

```
lib/
├── main.dart                  # App entry
├── engine/
│   ├── video_engine.dart      # Portable engine contract + timeline models
│   └── ffmpeg_engine.dart     # FFmpeg-backed implementation (stub → real)
└── ui/
    ├── editor_screen.dart     # Preview + transport + timeline shell
    └── timeline/
        └── timeline_view.dart # Multi-track timeline widget + playhead
```

The design mirrors the classic mobile-editor split: a **native media engine**
(decode / filter / encode, FFmpeg-based) behind a Dart `VideoEngine`
interface, with the **UI layer** (timeline, preview, transport) in Flutter.
The web target will swap in an ffmpeg.wasm engine behind the same interface.

## Roadmap

- [x] Milestone 1: repo scaffold, engine abstraction, timeline UI skeleton
- [ ] Milestone 2: media picking + real preview playback (platform player)
- [ ] Milestone 3: trim / split / merge on the timeline
- [ ] Milestone 4: text overlays, filters, transitions
- [ ] Milestone 5: export to MP4 via FFmpeg filter graph
- [ ] Milestone 6: web target via ffmpeg.wasm

## Developing

Requires Flutter 3.47+. Dependencies are vendored for offline environments
(see `tooling/`); normally just run:

```bash
flutter pub get
flutter run
```

## Contributing

PRs welcome. Keep it original — do not submit code, assets, or resources
copied from proprietary apps.
