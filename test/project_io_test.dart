import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_video_editor/engine/project_io.dart';
import 'package:open_video_editor/engine/video_engine.dart';

TimelineProject _richProject() {
  final src = MediaSource(
      id: 's1', path: '/tmp/a.mp4', duration: const Duration(seconds: 6));
  return TimelineProject(
    tracks: [
      VideoTrack(id: 'v1', clips: [
        Clip(
          id: 'c1',
          source: src,
          timelineStart: Duration.zero,
          sourceStart: const Duration(seconds: 1),
          duration: const Duration(seconds: 5),
          speed: 1.5,
          filter: VideoFilter.sepia,
          transitionIn: const ClipTransition(
              type: TransitionType.fade, duration: Duration(seconds: 1)),
          transitionOut: const ClipTransition(
              type: TransitionType.crossfade,
              duration: Duration(milliseconds: 500),
              xfadeKind: XfadeKind.wipeLeft),
          chromaKey: const ChromaKey(
              enabled: true,
              color: 0x00FF00,
              similarity: 0.4,
              blend: 0.2,
              bgColor: 0x0000FF),
        ),
      ]),
    ],
    overlays: [
      TextOverlay(
        id: 't1',
        text: 'Halo',
        start: const Duration(seconds: 1),
        end: const Duration(seconds: 4),
        fontSize: 40,
        x: 0.3,
        y: 0.7,
        keyframes: const [
          TextKeyframe(
              time: Duration(seconds: 2), x: 0.8, y: 0.2, fontSize: 64),
        ],
      ),
    ],
    audioTracks: [
      AudioTrack(
        id: 'a1',
        path: '/tmp/m.mp3',
        name: 'm.mp3',
        timelineStart: Duration.zero,
        trimStart: const Duration(seconds: 2),
        duration: const Duration(seconds: 5),
        sourceDuration: const Duration(seconds: 30),
        volume: 0.8,
        fadeIn: const Duration(seconds: 1),
        fadeOut: const Duration(seconds: 2),
      ),
    ],
    stickers: [
      StickerOverlay(
        id: 's1',
        path: '/tmp/st.png',
        name: 'st.png',
        start: const Duration(seconds: 1),
        end: const Duration(seconds: 3),
        x: 0.2,
        y: 0.9,
        scale: 1.5,
        keyframes: const [
          StickerKeyframe(
              time: Duration(seconds: 1), x: 0.9, y: 0.1, scale: 2.0),
        ],
      ),
    ],
    videoOverlays: [
      const VideoOverlay(
        id: 'p1',
        path: '/tmp/pip.mp4',
        name: 'pip.mp4',
        start: Duration(seconds: 1),
        end: Duration(seconds: 4),
        sourceStart: Duration(seconds: 2),
        x: 0.8,
        y: 0.8,
        scale: 0.4,
        volume: 0.5,
        hasAudio: false,
      ),
    ],
  );
}

void main() {
  group('project JSON round-trip', () {
    test('toJson -> fromJson -> toJson is stable', () {
      final p = _richProject();
      final once = jsonEncode(projectToJson(p, {}));
      final back = projectFromJson(jsonDecode(once));
      final twice = jsonEncode(projectToJson(back, {}));
      expect(twice, once);
    });

    test('media paths are rewritten through pathMap', () {
      final p = _richProject();
      final j = projectToJson(p, {'/tmp/a.mp4': '/bundle/media/a.mp4'});
      final clip =
          ((j['tracks'] as List).first as Map)['clips'].first as Map;
      expect((clip['source'] as Map)['path'], '/bundle/media/a.mp4');
      // untouched paths stay as-is
      final sticker = (j['stickers'] as List).first as Map;
      expect(sticker['path'], '/tmp/st.png');
    });

    test('unknown enum names fall back to defaults', () {
      final j = projectToJson(_richProject(), {});
      final clip =
          ((j['tracks'] as List).first as Map)['clips'].first as Map;
      clip['filter'] = 'nope_not_a_filter';
      final back = projectFromJson(j);
      expect(back.tracks.first.clips.first.filter, VideoFilter.none);
    });

    test('projectMediaPaths collects every referenced file', () {
      final paths = projectMediaPaths(_richProject());
      expect(paths,
          {'/tmp/a.mp4', '/tmp/m.mp3', '/tmp/st.png', '/tmp/pip.mp4'});
    });
  });

  group('projectDirName', () {
    test('sanitizes into a safe directory name', () {
      expect(projectDirName('Liburan 2026!'), 'Liburan_2026');
      expect(projectDirName('  '), 'proyek');
      expect(projectDirName('a/b\\c'), 'abc');
    });
  });
}
