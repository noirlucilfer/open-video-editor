// Widget test for the export flow: tapping Export on a non-empty
// project shows a progress dialog, the engine reports progress, and a
// success snackbar appears. An empty timeline shows a snackbar instead.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_video_editor/engine/ffmpeg_runner.dart';
import 'package:open_video_editor/engine/video_engine.dart';
import 'package:open_video_editor/ui/editor_screen.dart';

class _FakeEngine implements VideoEngine {
  _FakeEngine(this.runner);

  final FakeFFmpegRunner runner;

  @override
  EngineCapabilities get capabilities => const EngineCapabilities();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> loadProject(TimelineProject project) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Stream<Duration> get positionStream => const Stream.empty();

  @override
  Future<void> exportProject(
    TimelineProject project,
    ExportConfig config, {
    void Function(double progress)? onProgress,
  }) async {
    final code = await runner.run([config.outputPath],
        total: project.duration, onProgress: onProgress);
    if (code != 0) throw Exception('fake export failed');
  }

  @override
  Future<void> dispose() async {}
}

TimelineProject _projectWithClip() => TimelineProject(
      tracks: [
        VideoTrack(id: 'v1', clips: [
          Clip(
            id: 'c1',
            source: MediaSource(
                id: 's1',
                path: '/tmp/fake.mp4',
                duration: const Duration(seconds: 5)),
            timelineStart: Duration.zero,
            sourceStart: Duration.zero,
            duration: const Duration(seconds: 5),
          ),
        ]),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getTemporaryDirectory') return '/tmp';
        return null;
      },
    );
  });

  testWidgets('empty timeline shows snackbar, no dialog', (tester) async {
    final runner = FakeFFmpegRunner();
    await tester.pumpWidget(
      MaterialApp(home: EditorScreen(engine: _FakeEngine(runner))),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Export'));
    await tester.pump();
    expect(find.text('Timeline kosong, belum ada yang diekspor'), findsOneWidget);
    expect(find.text('Mengekspor video...'), findsNothing);
    expect(runner.lastArgs, isNull);
  });

  testWidgets('export shows progress dialog then success snackbar',
      (tester) async {
    final runner = FakeFFmpegRunner(steps: 4);
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(
          engine: _FakeEngine(runner),
          initialProject: _projectWithClip(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Export'));
    await tester.pump();
    expect(find.text('Mengekspor video...'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('Mengekspor video...'), findsNothing);
    expect(find.textContaining('Tersimpan:'), findsOneWidget);
    expect(runner.lastArgs, isNotNull);
    expect(runner.lastArgs!.first, startsWith('/tmp/ove_export_'));
  });
}
