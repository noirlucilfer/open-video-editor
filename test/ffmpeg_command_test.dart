import 'package:flutter_test/flutter_test.dart';
import 'package:open_video_editor/engine/ffmpeg_command.dart';
import 'package:open_video_editor/engine/video_engine.dart';

TimelineProject _project({
  List<Clip> clips = const [],
  List<TextOverlay> overlays = const [],
}) =>
    TimelineProject(
      tracks: clips.isEmpty ? const [] : [VideoTrack(id: 'v1', clips: clips)],
      overlays: overlays,
    );

Clip _clip(
  String id,
  String path,
  Duration timelineStart,
  Duration duration, {
  Duration sourceStart = Duration.zero,
  VideoFilter filter = VideoFilter.none,
  ClipTransition transitionIn = const ClipTransition(),
  ClipTransition transitionOut = const ClipTransition(),
}) =>
    Clip(
      id: id,
      source: MediaSource(
          id: 'src-$id', path: path, duration: const Duration(seconds: 10)),
      timelineStart: timelineStart,
      sourceStart: sourceStart,
      duration: duration,
      filter: filter,
      transitionIn: transitionIn,
      transitionOut: transitionOut,
    );

ExportConfig _config(String out) =>
    ExportConfig(outputPath: out, width: 1080, height: 1920, fps: 30);

void main() {
  group('buildExportCommand', () {
    test('throws on empty project', () {
      expect(
        () => buildExportCommand(_project(), _config('/tmp/o.mp4')),
        throwsArgumentError,
      );
    });

    test('single clip: input seeking, codecs, output', () {
      final args = buildExportCommand(
        _project(clips: [
          _clip('c1', '/tmp/a.mp4', Duration.zero,
              const Duration(seconds: 4),
              sourceStart: const Duration(seconds: 2)),
        ]),
        _config('/tmp/o.mp4'),
      );

      // Input: -ss 2 -t 4 -i /tmp/a.mp4
      final ss = args.indexOf('-ss');
      expect(args.sublist(ss, ss + 5),
          ['-ss', '2.0', '-t', '4.0', '-i', '/tmp/a.mp4'].sublist(0, 5));
      expect(args, contains('-i'));
      expect(args[args.indexOf('-i') + 1], '/tmp/a.mp4');

      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(fc, contains('[0:v]fps=30,scale=1080:1920,setpts=PTS-STARTPTS[v0]'));
      expect(
          fc,
          contains(
              '[0:a]aresample=44100,aformat=channel_layouts=stereo,asetpts=PTS-STARTPTS[a0]'));
      expect(fc, contains('[v0][a0]concat=n=1:v=1:a=1[catv][cata]'));
      // Output codecs + path
      expect(args, contains('libx264'));
      expect(args, contains('aac'));
      expect(args.last, '/tmp/o.mp4');
    });

    test('two clips concatenate in timeline order', () {
      final args = buildExportCommand(
        _project(clips: [
          _clip('c2', '/tmp/b.mp4', const Duration(seconds: 4),
              const Duration(seconds: 3)),
          _clip('c1', '/tmp/a.mp4', Duration.zero,
              const Duration(seconds: 4)),
        ]),
        _config('/tmp/o.mp4'),
      );
      // c1 first even though listed second
      expect(args[args.indexOf('-i') + 1], '/tmp/a.mp4');
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(fc, contains('[v0][a0][v1][a1]concat=n=2:v=1:a=1[catv][cata]'));
    });

    test('filters and fades land in the per-clip chain', () {
      final args = buildExportCommand(
        _project(clips: [
          _clip('c1', '/tmp/a.mp4', Duration.zero,
              const Duration(seconds: 4),
              filter: VideoFilter.sepia,
              transitionIn: const ClipTransition(
                  type: TransitionType.fade,
                  duration: Duration(seconds: 1)),
              transitionOut: const ClipTransition(
                  type: TransitionType.fade,
                  duration: Duration(seconds: 1))),
        ]),
        _config('/tmp/o.mp4'),
      );
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(fc, contains('colorchannelmixer='));
      expect(fc, contains('fade=t=in:st=0:d=1.0'));
      expect(fc, contains('fade=t=out:st=3.0:d=1.0'));
    });

    test('invert maps to negate, grayscale to hue=s=0', () {
      final args = buildExportCommand(
        _project(clips: [
          _clip('c1', '/tmp/a.mp4', Duration.zero,
              const Duration(seconds: 2),
              filter: VideoFilter.invert),
          _clip('c2', '/tmp/b.mp4', const Duration(seconds: 2),
              const Duration(seconds: 2),
              filter: VideoFilter.grayscale),
        ]),
        _config('/tmp/o.mp4'),
      );
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(fc, contains('[0:v]fps=30,scale=1080:1920,negate,setpts=PTS-STARTPTS[v0]'));
      expect(fc, contains('hue=s=0'));
    });

    test('text overlay becomes drawtext with enable window', () {
      final args = buildExportCommand(
        _project(
          clips: [
            _clip('c1', '/tmp/a.mp4', Duration.zero,
                const Duration(seconds: 6)),
          ],
          overlays: [
            const TextOverlay(
              id: 't1',
              text: 'Halo: dunia',
              start: Duration(seconds: 1),
              end: Duration(seconds: 4),
            ),
          ],
        ),
        _config('/tmp/o.mp4'),
        fontFile: '/usr/share/fonts/DejaVuSans.ttf',
      );
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(fc, contains("fontfile='/usr/share/fonts/DejaVuSans.ttf'"));
      // colon escaped inside the quoted text
      expect(fc, contains('text="Halo\\: dunia"'));
      expect(fc, contains("enable='between(t,1.0,4.0)'"));
      expect(fc, contains('[catv]drawtext='));
      expect(fc, contains('[ov0]format=yuv420p[outv]'));
    });

    test('clip without audio gets generated silence', () {
      final clip = Clip(
        id: 'c1',
        source: MediaSource(
          id: 's1',
          path: '/tmp/silent.mp4',
          duration: const Duration(seconds: 5),
          hasAudio: false,
        ),
        timelineStart: Duration.zero,
        sourceStart: Duration.zero,
        duration: const Duration(seconds: 5),
      );
      final args = buildExportCommand(
        _project(clips: [clip]),
        _config('/tmp/o.mp4'),
      );
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(fc, contains('aevalsrc=0:d=5.0:s=44100'));
    });
  });
}
