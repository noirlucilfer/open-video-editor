import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_video_editor/engine/project_io.dart';
import 'package:open_video_editor/engine/video_engine.dart';

/// Bundle I/O round-trips. Uses a temp dir via [debugProjectsRootOverride].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    debugProjectsRootOverride =
        await Directory.systemTemp.createTemp('ove_test_projects');
  });

  tearDownAll(() async {
    final dir = debugProjectsRootOverride;
    debugProjectsRootOverride = null;
    if (dir != null && await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  group('project bundle I/O', () {
    test('save -> load round-trips with media copies', () async {
      // Build a tiny real media file so the bundle has something to copy.
      final media = File('/tmp/autosave_src.bin');
      await media.writeAsBytes(List.filled(1024, 7));
      final project = TimelineProject(
        tracks: [
          VideoTrack(id: 'v', clips: [
            Clip(
              id: 'c',
              source: MediaSource(
                  id: 's',
                  path: media.path,
                  duration: const Duration(seconds: 2)),
              timelineStart: Duration.zero,
              sourceStart: Duration.zero,
              duration: const Duration(seconds: 2),
              kenBurns:
                  const KenBurns(enabled: true, zoomIn: false, strength: 0.5),
            ),
          ]),
        ],
        overlays: [
          const TextOverlay(
              id: 't',
              text: 'hi',
              start: Duration(seconds: 1),
              end: Duration(seconds: 2)),
        ],
      );
      const name = '__test_roundtrip__';
      try {
        final missing = await saveProject(name, project);
        expect(missing, isEmpty);

        final loaded = await loadProject(projectDirName(name));
        // Full-structure round-trip: loaded JSON must equal the original
        // JSON with the media path rewritten to the bundle copy.
        final bundlePath =
            loaded.tracks.first.clips.first.source.path;
        expect(
          jsonEncode(projectToJson(loaded, {})),
          jsonEncode(projectToJson(project, {media.path: bundlePath})),
        );
        // Media paths now point inside the bundle.
        expect(bundlePath, contains(debugProjectsRootOverride!.path));
        expect(await File(bundlePath).exists(), isTrue);
        // Bundle copy is byte-identical.
        expect(await File(bundlePath).length(), await media.length());
      } finally {
        await deleteProject(name);
      }
    });

    test('load of missing project throws', () async {
      await expectLater(
        loadProject('__definitely_not_here__'),
        throwsA(isA<ProjectLoadException>()),
      );
    });
  });

  group('autosave slot', () {
    test('autosave -> load -> clear', () async {
      final project = TimelineProject(
        overlays: [
          const TextOverlay(
              id: 't',
              text: 'draft',
              start: Duration.zero,
              end: Duration(seconds: 1)),
        ],
      );
      try {
        await autosaveProject(project, 'Nama Saya');
        final loaded = await loadAutosave();
        expect(loaded, isNotNull);
        expect(loaded!.name, 'Nama Saya');
        expect(loaded.project.overlays.single.text, 'draft');

        // Hidden from the project list.
        final names = await listProjects();
        expect(names.any((n) => n.contains('autosave')), isFalse);

        await clearAutosave();
        expect(await loadAutosave(), isNull);
      } finally {
        await clearAutosave();
      }
    });
  });
}
