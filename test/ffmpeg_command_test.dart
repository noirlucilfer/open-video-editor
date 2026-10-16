import 'package:flutter_test/flutter_test.dart';
import 'package:open_video_editor/engine/ffmpeg_command.dart';
import 'package:open_video_editor/engine/ffmpeg_runner.dart';
import 'package:open_video_editor/engine/timeline_ops.dart';
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
      expect(fc,
          contains('[0:v]scale=1080:1920,setpts=PTS-STARTPTS,fps=30[v0]'));
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
      expect(fc,
          contains('[0:v]scale=1080:1920,negate,setpts=PTS-STARTPTS,fps=30[v0]'));
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

    test('default codec is libx264 with x264 quality flags', () {
      final args = buildExportCommand(
        _project(clips: [
          _clip('c1', '/tmp/a.mp4', Duration.zero,
              const Duration(seconds: 2)),
        ]),
        _config('/tmp/o.mp4'),
      );
      expect(args[args.indexOf('-c:v') + 1], 'libx264');
      expect(args, contains('-preset'));
      expect(args, contains('-crf'));
    });

    test('speed 2x: input spans full source segment, setpts + atempo applied',
        () {
      final clip = _clip('c1', '/tmp/a.mp4', Duration.zero,
          const Duration(seconds: 4),
          sourceStart: const Duration(seconds: 1));
      // 4s of source at 2x -> 2s timeline; input still reads the 4s segment.
      final fast = setClipSpeed(clip, 2.0);
      expect(fast.duration, const Duration(seconds: 2));
      final args = buildExportCommand(
        _project(clips: [fast]),
        _config('/tmp/o.mp4'),
      );
      final ss = args.indexOf('-ss');
      expect(args.sublist(ss, ss + 4), ['-ss', '1.0', '-t', '4.0']);
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(fc, contains('setpts=(PTS-STARTPTS)/2'));
      expect(fc, contains('atempo=2'));
    });

    test('speed 0.5x: atempo=0.5 slows audio', () {
      final clip = _clip('c1', '/tmp/a.mp4', Duration.zero,
          const Duration(seconds: 4));
      final slow = setClipSpeed(clip, 0.5);
      expect(slow.duration, const Duration(seconds: 8));
      final args = buildExportCommand(
        _project(clips: [slow]),
        _config('/tmp/o.mp4'),
      );
      final ss = args.indexOf('-ss');
      expect(args.sublist(ss, ss + 4), ['-ss', '0.0', '-t', '4.0']);
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(fc, contains('setpts=(PTS-STARTPTS)/0.5'));
      expect(fc, contains('atempo=0.5'));
    });

    test('speed 4x chains atempo=2.0 twice', () {
      final clip = _clip('c1', '/tmp/a.mp4', Duration.zero,
          const Duration(seconds: 8));
      final args = buildExportCommand(
        _project(clips: [setClipSpeed(clip, 4.0)]),
        _config('/tmp/o.mp4'),
      );
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(fc, contains('atempo=2.0,atempo=2')); // chained: 4 = 2x2
    });

    test('audio track is delayed, volumed and mixed', () {
      final project = _project(
        clips: [
          _clip('c1', '/tmp/a.mp4', Duration.zero,
              const Duration(seconds: 6)),
        ],
      );
      final withAudio = TimelineProject(
        tracks: project.tracks,
        audioTracks: [
          const AudioTrack(
            id: 'aud1',
            path: '/tmp/song.mp3',
            name: 'song.mp3',
            timelineStart: Duration(seconds: 1),
            trimStart: Duration.zero,
            duration: Duration(seconds: 5),
            sourceDuration: Duration(seconds: 30),
            volume: 0.5,
          ),
        ],
      );
      final args = buildExportCommand(withAudio, _config('/tmp/o.mp4'));
      // extra input after the clip input
      final firstI = args.indexOf('-i');
      final secondI = args.indexOf('-i', firstI + 1);
      expect(args[secondI + 1], '/tmp/song.mp3');
      expect(args.sublist(secondI - 4, secondI + 1),
          ['-ss', '0.0', '-t', '5.0', '-i']);
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(
          fc,
          contains(
              '[1:a]aresample=44100,aformat=channel_layouts=stereo,adelay=1000|1000,volume=0.5[am0]'));
      expect(fc, contains('[cata][am0]amix=inputs=2:duration=first'));
      expect(fc, contains('[outa]'));
      // mixed audio is what gets mapped
      expect(args[args.indexOf('-map', args.indexOf('[outv]')) + 1], '[outa]');
    });

    test('audio track fades become afade filters before adelay', () {
      final withAudio = TimelineProject(
        tracks: [
          VideoTrack(id: 'v1', clips: [
            _clip('c1', '/tmp/a.mp4', Duration.zero,
                const Duration(seconds: 6)),
          ])
        ],
        audioTracks: [
          const AudioTrack(
            id: 'aud1',
            path: '/tmp/song.mp3',
            name: 'song.mp3',
            timelineStart: Duration(seconds: 1),
            trimStart: Duration.zero,
            duration: Duration(seconds: 5),
            sourceDuration: Duration(seconds: 30),
            fadeIn: Duration(seconds: 1),
            fadeOut: Duration(seconds: 2),
          ),
        ],
      );
      final args = buildExportCommand(withAudio, _config('/tmp/o.mp4'));
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(
          fc,
          contains(
              '[1:a]aresample=44100,aformat=channel_layouts=stereo'
              ',afade=t=in:st=0:d=1.0'
              ',afade=t=out:st=3.0:d=2.0'
              ',adelay=1000|1000,volume=1.0[am0]'));
    });

    test('sticker becomes a scaled overlay with enable window', () {
      final project = _project(
        clips: [
          _clip('c1', '/tmp/a.mp4', Duration.zero,
              const Duration(seconds: 6)),
        ],
      );
      final withSticker = TimelineProject(
        tracks: project.tracks,
        stickers: [
          const StickerOverlay(
            id: 's1',
            path: '/tmp/sticker.png',
            name: 'sticker.png',
            start: Duration(seconds: 1),
            end: Duration(seconds: 4),
            x: 0.25,
            y: 0.75,
            scale: 2.0,
          ),
        ],
      );
      final args = buildExportCommand(withSticker, _config('/tmp/o.mp4'));
      // looped image input: -loop 1 -t 3.0 -i /tmp/sticker.png
      final loopIdx = args.indexOf('-loop');
      expect(args.sublist(loopIdx, loopIdx + 5),
          ['-loop', '1', '-t', '3.0', '-i']);
      expect(args[loopIdx + 5], '/tmp/sticker.png');
      final fc = args[args.indexOf('-filter_complex') + 1];
      // 1080 * 0.25 * 2.0 = 540px wide
      expect(fc, contains('[1:v]scale=540:-1[st0]'));
      expect(fc, contains("overlay=x='(0.25*W-w/2)':y='(0.75*H-h/2)'"));
      expect(fc, contains("enable='between(t,1.0,4.0)'"));
      expect(fc, contains('[sv0]format=yuv420p[outv]'));
    });

    test('crossfade boundary uses xfade + acrossfade', () {
      final c1 = _clip('c1', '/tmp/a.mp4', Duration.zero,
          const Duration(seconds: 4));
      final c2 = _clip('c2', '/tmp/b.mp4', const Duration(seconds: 4),
          const Duration(seconds: 4));
      final withXfade = c1.copyWith(
        transitionOut: const ClipTransition(
            type: TransitionType.crossfade, duration: Duration(seconds: 1)),
      );
      final args = buildExportCommand(
        _project(clips: [withXfade, c2]),
        _config('/tmp/o.mp4'),
      );
      final fc = args[args.indexOf('-filter_complex') + 1];
      // offset = 4s - 1s = 3s into the first clip
      expect(
          fc,
          contains(
              '[v0][v1]xfade=transition=fade:duration=1.0:offset=3.0[x1]'));
      expect(fc, contains('[a0][a1]acrossfade=d=1.0[xa1]'));
      expect(fc, contains('[x1]copy[catv]'));
      expect(fc, contains('[xa1]acopy[cata]'));
      // no plain concat of the two clips
      expect(fc, isNot(contains('concat=n=2:v=1:a=1')));
      // output is 4 + 4 - 1 = 7s
      expect(
          exportDuration(_project(clips: [withXfade, c2])),
          const Duration(seconds: 7));
    });

    test('mixed boundaries: xfade where set, concat elsewhere', () {
      Clip cx(String id, String path, Duration start) =>
          _clip(id, path, start, const Duration(seconds: 4));
      final c1 = cx('c1', '/tmp/a.mp4', Duration.zero).copyWith(
        transitionOut: const ClipTransition(
            type: TransitionType.crossfade, duration: Duration(seconds: 1)),
      );
      final c2 = cx('c2', '/tmp/b.mp4', const Duration(seconds: 4));
      final c3 = cx('c3', '/tmp/c.mp4', const Duration(seconds: 8));
      final args = buildExportCommand(
        _project(clips: [c1, c2, c3]),
        _config('/tmp/o.mp4'),
      );
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(fc, contains('xfade=transition=fade:duration=1.0:offset=3.0[x1]'));
      // second boundary is a plain concat of the xfade result and v2
      expect(fc, contains('[x1][v2]concat=n=2:v=1:a=0[cv2]'));
      expect(fc, contains('[xa1][a2]concat=n=2:v=0:a=1[ca2]'));
      expect(
          exportDuration(_project(clips: [c1, c2, c3])),
          const Duration(seconds: 11));
    });

    test('crossfade shifts later overlays and audio delays', () {
      final c1 = _clip('c1', '/tmp/a.mp4', Duration.zero,
          const Duration(seconds: 4));
      final c2 = _clip('c2', '/tmp/b.mp4', const Duration(seconds: 4),
          const Duration(seconds: 4));
      final withXfade = c1.copyWith(
        transitionOut: const ClipTransition(
            type: TransitionType.crossfade, duration: Duration(seconds: 2)),
      );
      final project = TimelineProject(
        tracks: [
          VideoTrack(id: 'v1', clips: [withXfade, c2])
        ],
        overlays: const [
          TextOverlay(
              id: 't', text: 'hi', start: Duration(seconds: 5), end: Duration(seconds: 6)),
        ],
        audioTracks: const [
          AudioTrack(
              id: 'a',
              path: '/tmp/s.mp3',
              name: 's.mp3',
              timelineStart: Duration(seconds: 5),
              trimStart: Duration.zero,
              duration: Duration(seconds: 1),
              sourceDuration: Duration(seconds: 10)),
        ],
      );
      final args = buildExportCommand(project, _config('/tmp/o.mp4'));
      final fc = args[args.indexOf('-filter_complex') + 1];
      // 5s and 6s shift 2s earlier (transition at 4s boundary)
      expect(fc, contains("enable='between(t,3.0,4.0)'"));
      expect(fc, contains('adelay=3000|3000'));
    });

    test('crossfade kind maps to the xfade transition name', () {
      final c1 = _clip('c1', '/tmp/a.mp4', Duration.zero,
          const Duration(seconds: 4));
      final c2 = _clip('c2', '/tmp/b.mp4', const Duration(seconds: 4),
          const Duration(seconds: 4));
      final withWipe = c1.copyWith(
        transitionOut: const ClipTransition(
            type: TransitionType.crossfade,
            duration: Duration(seconds: 1),
            xfadeKind: XfadeKind.wipeLeft),
      );
      final args = buildExportCommand(
        _project(clips: [withWipe, c2]),
        _config('/tmp/o.mp4'),
      );
      final fc = args[args.indexOf('-filter_complex') + 1];
      expect(
          fc,
          contains(
              '[v0][v1]xfade=transition=wipeleft:duration=1.0:offset=3.0[x1]'));
      // audio still uses a plain crossfade
      expect(fc, contains('[a0][a1]acrossfade=d=1.0[xa1]'));
    });

    test('crossfade longer than a clip is clamped', () {
      final c1 = _clip('c1', '/tmp/a.mp4', Duration.zero,
          const Duration(seconds: 4));
      final c2 = _clip('c2', '/tmp/b.mp4', const Duration(seconds: 4),
          const Duration(seconds: 1));
      final withXfade = c1.copyWith(
        transitionOut: const ClipTransition(
            type: TransitionType.crossfade, duration: Duration(seconds: 9)),
      );
      final args = buildExportCommand(
        _project(clips: [withXfade, c2]),
        _config('/tmp/o.mp4'),
      );
      final fc = args[args.indexOf('-filter_complex') + 1];
      // clamped to the 1s clip: duration=1.0, offset=4-1=3
      expect(
          fc,
          contains(
              '[v0][v1]xfade=transition=fade:duration=1.0:offset=3.0[x1]'));
    });

    test('custom video codec replaces libx264, drops x264-only flags', () {
      final args = buildExportCommand(
        _project(clips: [
          _clip('c1', '/tmp/a.mp4', Duration.zero,
              const Duration(seconds: 2)),
        ]),
        ExportConfig(outputPath: '/tmp/o.mp4', videoCodec: 'h264_mediacodec'),
      );
      expect(args[args.indexOf('-c:v') + 1], 'h264_mediacodec');
      expect(args, isNot(contains('-preset')));
      expect(args, isNot(contains('-crf')));
    });
  });

  group('createDefaultRunner', () {
    test('picks subprocess runner on desktop', () {
      expect(createDefaultRunner(), isA<ProcessFFmpegRunner>());
    });
  });

  group('splitWasmArgs', () {
    test('rewrites -i urls to MEMFS names and strips output dir', () {
      final r = splitWasmArgs([
        '-ss', '2.0', '-t', '4.0', '-i', 'blob:http://x/abc',
        '-ss', '1.0', '-t', '3.0', '-i', 'blob:http://x/def',
        '-filter_complex', '[0:v]copy[v0]',
        '-y', '/tmp/ove_export_1.mp4',
      ]);
      expect(r.inputs, [
        {'name': 'ove-in-0.mp4', 'url': 'blob:http://x/abc'},
        {'name': 'ove-in-1.mp4', 'url': 'blob:http://x/def'},
      ]);
      expect(r.outputName, 'ove_export_1.mp4');
      expect(
        r.args,
        [
          '-ss', '2.0', '-t', '4.0', '-i', 'ove-in-0.mp4',
          '-ss', '1.0', '-t', '3.0', '-i', 'ove-in-1.mp4',
          '-filter_complex', '[0:v]copy[v0]',
          '-y', 'ove_export_1.mp4',
        ],
      );
    });
  });
}
