// Main editor screen: preview area on top, transport controls,
// timeline at the bottom.
//
// Preview playback is driven by [TimelinePlayer] (package:video_player);
// the [VideoEngine] (FFmpeg) remains the path for export rendering.

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart' hide VideoTrack;

import '../engine/ffmpeg_engine.dart';
import '../engine/video_engine.dart';
import '../media/media_picker.dart';
import '../playback/player_controller_factory.dart';
import '../playback/timeline_player.dart';
import 'timeline/timeline_view.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final VideoEngine _engine;
  late final TimelinePlayer _player;
  final MediaPicker _picker = MediaPicker();
  TimelineProject _project = const TimelineProject();
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _engine = FfmpegVideoEngine();
    _player = TimelinePlayer();
    _player.addListener(_onPlayerChanged);
    _engine.initialize();
  }

  void _onPlayerChanged() => setState(() {});

  @override
  void dispose() {
    _player.removeListener(_onPlayerChanged);
    _player.dispose();
    _engine.dispose();
    super.dispose();
  }

  /// Picks a video, probes its duration, and appends it as a clip.
  Future<void> _pickAndAdd() async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      final picked = await _picker.pickVideo();
      if (picked == null) return;
      final probe = createPlayerController(picked.path);
      try {
        await probe.initialize();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Gagal membaca video: $e')),
          );
        }
        return;
      }
      final duration = probe.value.duration;
      await probe.dispose();
      if (duration == Duration.zero) return;

      final source = MediaSource(
        id: picked.name,
        path: picked.path,
        duration: duration,
      );
      final clip = Clip(
        id: 'clip-${DateTime.now().millisecondsSinceEpoch}',
        source: source,
        timelineStart: _project.duration,
        sourceStart: Duration.zero,
        duration: duration,
      );
      final tracks = List<VideoTrack>.from(_project.tracks);
      if (tracks.isEmpty) {
        tracks.add(VideoTrack(id: 'v1', clips: [clip]));
      } else {
        final first = tracks.first;
        tracks[0] = VideoTrack(id: first.id, clips: [...first.clips, clip]);
      }
      _project = TimelineProject(tracks: tracks, overlays: _project.overlays);
      await _player.setProject(_project);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _export() async {
    const config = ExportConfig(outputPath: '/tmp/open_video_editor_out.mp4');
    try {
      await _engine.exportProject(
        _project,
        config,
        onProgress: (p) => debugPrint('export ${(p * 100).round()}%'),
      );
    } on UnimplementedError {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Export belum diimplementasikan')),
        );
      }
    }
  }

  Widget _buildPreview() {
    final controller = _player.controller;
    if (controller != null && controller.value.isInitialized) {
      return AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: VideoPlayer(controller),
      );
    }
    return Text(
      _project.tracks.isEmpty
          ? 'Ketuk + untuk menambahkan video'
          : 'Preview @ ${_player.position.inSeconds}s',
      style: const TextStyle(color: Colors.white70),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Open Video Editor'),
        actions: [
          IconButton(
            icon: _adding
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add),
            tooltip: 'Tambah video',
            onPressed: _pickAndAdd,
          ),
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Export',
            onPressed: _export,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: _buildPreview(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous),
                  onPressed: () => _player.seek(Duration.zero),
                ),
                IconButton(
                  icon: Icon(
                      _player.playing ? Icons.pause : Icons.play_arrow),
                  iconSize: 40,
                  onPressed: () =>
                      _player.playing ? _player.pause() : _player.play(),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  onPressed: () => _player.seek(_project.duration),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 220,
            child: TimelineView(
              project: _project,
              position: _player.position,
              onSeek: _player.seek,
            ),
          ),
        ],
      ),
    );
  }
}
