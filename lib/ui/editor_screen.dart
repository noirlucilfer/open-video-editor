// Main editor screen: preview area on top, transport controls,
// timeline at the bottom.
//
// Preview playback is driven by [TimelinePlayer] (package:video_player);
// the [VideoEngine] (FFmpeg) remains the path for export rendering.
//
// Milestone 3: clips are selectable; the selected clip can be trimmed
// (drag handles), split at the playhead, merged with its neighbour,
// or deleted.

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart' hide VideoTrack;

import '../engine/ffmpeg_engine.dart';
import '../engine/timeline_ops.dart';
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
  String? _selectedClipId;
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

  /// Locates a clip by id. Returns (trackIndex, clipIndex, clip).
  (int, int, Clip)? _findClip(String id) {
    for (var ti = 0; ti < _project.tracks.length; ti++) {
      final clips = _project.tracks[ti].clips;
      for (var ci = 0; ci < clips.length; ci++) {
        if (clips[ci].id == id) return (ti, ci, clips[ci]);
      }
    }
    return null;
  }

  Clip? get _selectedClip {
    final id = _selectedClipId;
    if (id == null) return null;
    return _findClip(id)?.$3;
  }

  Future<void> _updateProject(TimelineProject project) async {
    _project = project;
    await _player.setProject(_project);
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
      await _updateProject(
          TimelineProject(tracks: tracks, overlays: _project.overlays));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _replaceClip(int trackIndex, int clipIndex, Clip clip) async {
    final tracks = List<VideoTrack>.from(_project.tracks);
    final clips = List<Clip>.from(tracks[trackIndex].clips);
    clips[clipIndex] = clip;
    tracks[trackIndex] =
        VideoTrack(id: tracks[trackIndex].id, clips: clips);
    await _updateProject(
        TimelineProject(tracks: tracks, overlays: _project.overlays));
  }

  Future<void> _trimClip(
      String clipId, TrimEdge edge, Duration newTimelinePos) async {
    final found = _findClip(clipId);
    if (found == null) return;
    final (ti, ci, clip) = found;
    final updated = edge == TrimEdge.start
        ? trimClipStart(clip, newTimelinePos)
        : trimClipEnd(clip, newTimelinePos);
    await _replaceClip(ti, ci, updated);
  }

  Future<void> _splitSelected() async {
    final found = _selectedClipId == null ? null : _findClip(_selectedClipId!);
    if (found == null) return;
    final (ti, ci, clip) = found;
    final pos = _player.position;
    if (pos <= clip.timelineStart || pos >= clip.timelineEnd) return;
    final (first, second) = splitClipAt(clip, pos);
    final tracks = List<VideoTrack>.from(_project.tracks);
    final clips = List<Clip>.from(tracks[ti].clips);
    clips.replaceRange(ci, ci + 1, [first, second]);
    tracks[ti] = VideoTrack(id: tracks[ti].id, clips: clips);
    _selectedClipId = first.id;
    await _updateProject(
        TimelineProject(tracks: tracks, overlays: _project.overlays));
  }

  Future<void> _mergeSelected() async {
    final found = _selectedClipId == null ? null : _findClip(_selectedClipId!);
    if (found == null) return;
    final (ti, ci, clip) = found;
    final clips = _project.tracks[ti].clips;
    if (ci + 1 >= clips.length) return;
    final merged = tryMergeClips(clip, clips[ci + 1]);
    if (merged == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Tidak bisa digabung: harus bersebelahan & satu sumber')),
        );
      }
      return;
    }
    final tracks = List<VideoTrack>.from(_project.tracks);
    final updated = List<Clip>.from(clips);
    updated.replaceRange(ci, ci + 2, [merged]);
    tracks[ti] = VideoTrack(id: tracks[ti].id, clips: updated);
    _selectedClipId = merged.id;
    await _updateProject(
        TimelineProject(tracks: tracks, overlays: _project.overlays));
  }

  Future<void> _deleteSelected() async {
    final found = _selectedClipId == null ? null : _findClip(_selectedClipId!);
    if (found == null) return;
    final (ti, ci, _) = found;
    final tracks = List<VideoTrack>.from(_project.tracks);
    final clips = List<Clip>.from(tracks[ti].clips)..removeAt(ci);
    tracks[ti] = VideoTrack(id: tracks[ti].id, clips: clips);
    _selectedClipId = null;
    await _updateProject(
        TimelineProject(tracks: tracks, overlays: _project.overlays));
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

  bool get _canSplit {
    final clip = _selectedClip;
    if (clip == null) return false;
    final pos = _player.position;
    return pos > clip.timelineStart && pos < clip.timelineEnd;
  }

  bool get _canMerge {
    final found = _selectedClipId == null ? null : _findClip(_selectedClipId!);
    if (found == null) return false;
    final (ti, ci, clip) = found;
    final clips = _project.tracks[ti].clips;
    return ci + 1 < clips.length && tryMergeClips(clip, clips[ci + 1]) != null;
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

  Widget _buildClipToolbar() {
    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.content_cut, size: 18),
            label: const Text('Split'),
            onPressed: _canSplit ? _splitSelected : null,
          ),
          TextButton.icon(
            icon: const Icon(Icons.merge_type, size: 18),
            label: const Text('Merge'),
            onPressed: _canMerge ? _mergeSelected : null,
          ),
          TextButton.icon(
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Hapus'),
            onPressed: _deleteSelected,
          ),
        ],
      ),
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
          if (_selectedClipId != null) _buildClipToolbar(),
          SizedBox(
            height: 220,
            child: TimelineView(
              project: _project,
              position: _player.position,
              selectedClipId: _selectedClipId,
              onSeek: _player.seek,
              onClipSelected: (id) => setState(() => _selectedClipId = id),
              onTrim: _trimClip,
            ),
          ),
        ],
      ),
    );
  }
}
