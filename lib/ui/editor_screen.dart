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

  /// Shows a dialog to input overlay text. Returns null when cancelled.
  Future<String?> _showTextDialog({String? initial}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(initial == null ? 'Tambah teks' : 'Edit teks'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Ketik teks...'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _addTextOverlay() async {
    final text = await _showTextDialog();
    if (text == null || text.trim().isEmpty) return;
    final start = _player.position;
    final overlay = TextOverlay(
      id: 'txt-${DateTime.now().millisecondsSinceEpoch}',
      text: text.trim(),
      start: start,
      end: start + const Duration(seconds: 3),
    );
    await _updateProject(TimelineProject(
      tracks: _project.tracks,
      overlays: [..._project.overlays, overlay],
    ));
  }

  Future<void> _onOverlayTap(TextOverlay overlay) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('"$overlay.text"'.length > 24
            ? '"${overlay.text.substring(0, 24)}..."'
            : '"${overlay.text}"'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'edit'),
            child: const Text('Edit'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child:
                const Text('Hapus', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (action == 'delete') {
      await _updateProject(TimelineProject(
        tracks: _project.tracks,
        overlays:
            _project.overlays.where((o) => o.id != overlay.id).toList(),
      ));
    } else if (action == 'edit') {
      final text = await _showTextDialog(initial: overlay.text);
      if (text == null || text.trim().isEmpty) return;
      await _updateProject(TimelineProject(
        tracks: _project.tracks,
        overlays: _project.overlays
            .map((o) =>
                o.id == overlay.id ? o.copyWith(text: text.trim()) : o)
            .toList(),
      ));
    }
  }

  Future<void> _setClipFilter(VideoFilter filter) async {
    final found = _selectedClipId == null ? null : _findClip(_selectedClipId!);
    if (found == null) return;
    final (ti, ci, clip) = found;
    await _replaceClip(ti, ci, clip.copyWith(filter: filter));
  }

  Future<void> _toggleFade(bool isIn) async {
    final found = _selectedClipId == null ? null : _findClip(_selectedClipId!);
    if (found == null) return;
    final (ti, ci, clip) = found;
    final current = isIn ? clip.transitionIn : clip.transitionOut;
    const oneSec = Duration(seconds: 1);
    final updated = current.isEnabled
        ? const ClipTransition()
        : const ClipTransition(type: TransitionType.fade, duration: oneSec);
    await _replaceClip(
      ti,
      ci,
      clip.copyWith(
        transitionIn: isIn ? updated : clip.transitionIn,
        transitionOut: isIn ? clip.transitionOut : updated,
      ),
    );
  }

  Future<void> _export() async {    const config = ExportConfig(outputPath: '/tmp/open_video_editor_out.mp4');
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

  /// Opacity for fade in/out transitions of the active clip.
  double _fadeOpacity(Clip? clip) {
    if (clip == null) return 1.0;
    var opacity = 1.0;
    final pos = _player.position;
    final tIn = clip.transitionIn;
    if (tIn.isEnabled) {
      final elapsed = pos - clip.timelineStart;
      if (elapsed < tIn.duration) {
        opacity *= elapsed.inMilliseconds / tIn.duration.inMilliseconds;
      }
    }
    final tOut = clip.transitionOut;
    if (tOut.isEnabled) {
      final remaining = clip.timelineEnd - pos;
      if (remaining < tOut.duration) {
        opacity *= remaining.inMilliseconds / tOut.duration.inMilliseconds;
      }
    }
    return opacity.clamp(0.0, 1.0);
  }

  List<TextOverlay> _activeOverlays() {
    final pos = _player.position;
    return _project.overlays
        .where((o) => pos >= o.start && pos < o.end)
        .toList();
  }

  Widget _buildPreview() {
    final controller = _player.controller;
    final clip = _player.activeClip;
    Widget? video;
    if (controller != null && controller.value.isInitialized) {
      video = AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: VideoPlayer(controller),
      );
      if (clip != null && clip.filter != VideoFilter.none) {
        video = ColorFiltered(
          colorFilter: ColorFilter.matrix(clip.filter.matrix),
          child: video,
        );
      }
      final opacity = _fadeOpacity(clip);
      if (opacity < 1.0) {
        video = Opacity(opacity: opacity, child: video);
      }
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        video ??
            Text(
              _project.tracks.isEmpty
                  ? 'Ketuk + untuk menambahkan video'
                  : 'Preview @ ${_player.position.inSeconds}s',
              style: const TextStyle(color: Colors.white70),
            ),
        for (final o in _activeOverlays())
          Positioned.fill(
            child: Align(
              alignment: Alignment.center,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  o.text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: o.fontSize,
                    color: Colors.white,
                    shadows: const [
                      Shadow(blurRadius: 8, color: Colors.black87),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
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

  Widget _buildFilterRow() {
    final clip = _selectedClip;
    if (clip == null) return const SizedBox.shrink();
    return Container(
      color: Colors.grey.shade900,
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        children: [
          for (final f in VideoFilter.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: ChoiceChip(
                label: Text(f.label),
                selected: clip.filter == f,
                onSelected: (_) => _setClipFilter(f),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFadeRow() {
    final clip = _selectedClip;
    if (clip == null) return const SizedBox.shrink();
    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FilterChip(
            label: const Text('Fade in'),
            selected: clip.transitionIn.isEnabled,
            onSelected: (_) => _toggleFade(true),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Fade out'),
            selected: clip.transitionOut.isEnabled,
            onSelected: (_) => _toggleFade(false),
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
            icon: const Icon(Icons.text_fields),
            tooltip: 'Tambah teks',
            onPressed: _addTextOverlay,
          ),
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
          if (_selectedClipId != null) _buildFilterRow(),
          if (_selectedClipId != null) _buildFadeRow(),
          SizedBox(
            height: 220,
            child: TimelineView(
              project: _project,
              position: _player.position,
              selectedClipId: _selectedClipId,
              onSeek: _player.seek,
              onClipSelected: (id) => setState(() => _selectedClipId = id),
              onOverlayTap: _onOverlayTap,
              onTrim: _trimClip,
            ),
          ),
        ],
      ),
    );
  }
}
