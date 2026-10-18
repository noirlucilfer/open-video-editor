// Main editor screen: preview area on top, transport controls,
// timeline at the bottom.
//
// Preview playback is driven by [TimelinePlayer] (package:video_player);
// the [VideoEngine] (FFmpeg) remains the path for export rendering.
//
// Milestone 3: clips are selectable; the selected clip can be trimmed
// (drag handles), split at the playhead, merged with its neighbour,
// or deleted.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart' hide VideoTrack;

import '../engine/export_font.dart';
import '../engine/ffmpeg_engine.dart';
import '../engine/ffmpeg_runner.dart';
import '../engine/project_io.dart';
import '../engine/timeline_ops.dart';
import '../engine/undo_history.dart';
import '../engine/video_engine.dart';
import '../media/media_picker.dart';
import '../media/sticker_image.dart';
import '../media/thumbnails.dart';
import '../playback/audio_source.dart';
import '../playback/player_controller_factory.dart';
import '../playback/timeline_player.dart';
import 'timeline/timeline_view.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, this.engine, this.initialProject});

  /// Injected engine (tests); defaults to [FfmpegVideoEngine].
  final VideoEngine? engine;

  /// Injected project (tests); defaults to an empty project.
  final TimelineProject? initialProject;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final VideoEngine _engine;
  late final TimelinePlayer _player;
  final MediaPicker _picker = MediaPicker();
  final ThumbnailService _thumbnails = ThumbnailService();
  TimelineProject _project = const TimelineProject();
  String? _selectedClipId;
  String? _selectedAudioId;
  bool _adding = false;
  final _exportProgress = ValueNotifier<double>(0);

  /// Undo/redo snapshots; every [_updateProject] pushes the pre-change
  /// project, drag gestures push once via [_beginDrag].
  final _history = UndoStack<TimelineProject>();

  /// Name of the saved project loaded/saved this session, if any.
  String? _projectName;

  /// Set by drag start; the first move of the gesture pushes history.
  bool _dragNeedsPush = false;

  /// True while ffmpeg.wasm downloads its core on web (first export).
  final _wasmLoading = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _engine = widget.engine ??
        FfmpegVideoEngine(
          // MEMFS font name on web (materialized by the wasm runner);
          // bundled TTF copied to a temp file on mobile.
          fontFileProvider:
              kIsWeb ? () async => 'ove-font.ttf' : ensureExportFont,
          onWasmLoadProgress:
              kIsWeb ? (p) => _wasmLoading.value = p < 1.0 : null,
        );
    _project = widget.initialProject ?? _project;
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
    _exportProgress.dispose();
    _wasmLoading.dispose();
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
    _history.push(_project);
    await _applyProject(project);
  }

  /// Replaces the project without touching undo history (undo/redo,
  /// project load).
  Future<void> _applyProject(TimelineProject project) async {
    _project = project;
    _thumbnails.invalidate();
    await _player.setProject(_project);
    if (mounted) setState(() {});
  }

  Future<void> _undo() async {
    final prev = _history.undo(_project);
    if (prev == null) return;
    await _applyProject(prev);
  }

  Future<void> _redo() async {
    final next = _history.redo(_project);
    if (next == null) return;
    await _applyProject(next);
  }

  /// Called on drag start; the first move of the gesture then pushes one
  /// undo snapshot, so a whole drag is a single undo step.
  void _beginDrag() => _dragNeedsPush = true;

  void _pushDragHistory() {
    if (_dragNeedsPush) {
      _dragNeedsPush = false;
      _history.push(_project);
    }
  }

  Future<void> _onAddMenu(String value) async {
    switch (value) {
      case 'video':
        await _pickAndAdd();
      case 'pip':
        await _pickAndAddVideoOverlay();
      case 'text':
        await _addTextOverlay();
      case 'audio':
        await _pickAndAddAudio();
      case 'sticker':
        await _pickAndAddSticker();
    }
  }

  Future<void> _onProjectMenu(String value) async {
    switch (value) {
      case 'save':
        await _saveProjectDialog();
      case 'open':
        await _openProjectDialog();
      case 'new':
        await _newProjectDialog();
    }
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _saveProjectDialog() async {
    if (kIsWeb) {
      _snack('Simpan proyek belum didukung di web');
      return;
    }
    final controller =
        TextEditingController(text: _projectName ?? 'Proyek tanpa judul');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Simpan proyek'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Nama proyek',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    try {
      final missing = await saveProject(name, _project);
      _projectName = name;
      setState(() {});
      _snack(missing.isEmpty
          ? 'Proyek "$name" tersimpan'
          : 'Tersimpan, tapi ${missing.length} file media hilang dan dilewati');
    } catch (e) {
      _snack('Gagal menyimpan: $e');
    }
  }

  Future<void> _openProjectDialog() async {
    if (kIsWeb) {
      _snack('Buka proyek belum didukung di web');
      return;
    }
    List<String> names;
    try {
      names = await listProjects();
    } catch (e) {
      _snack('Gagal membaca daftar proyek: $e');
      return;
    }
    if (names.isEmpty) {
      _snack('Belum ada proyek tersimpan');
      return;
    }
    if (!mounted) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Buka proyek'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final n in names)
                ListTile(
                  title: Text(n),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () async {
                      await deleteProject(n);
                      if (ctx.mounted) Navigator.pop(ctx, '__deleted__');
                    },
                  ),
                  onTap: () => Navigator.pop(ctx, n),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected == null) return;
    if (selected == '__deleted__') {
      // Refresh the list after a deletion.
      await _openProjectDialog();
      return;
    }
    try {
      final project = await loadProject(selected);
      _history.clear();
      _projectName = selected;
      _selectedClipId = null;
      _selectedAudioId = null;
      await _applyProject(project);
      _snack('Proyek "$selected" dibuka');
    } on ProjectLoadException catch (e) {
      _snack('Gagal membuka: $e');
    }
  }

  Future<void> _newProjectDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Proyek baru?'),
        content: const Text(
            'Proyek saat ini akan ditutup. Simpan dulu kalau belum.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Buat baru'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _history.clear();
    _projectName = null;
    _selectedClipId = null;
    _selectedAudioId = null;
    await _applyProject(const TimelineProject());
  }

  /// Copies the current project, replacing only the given parts.
  TimelineProject _with({
    List<VideoTrack>? tracks,
    List<TextOverlay>? overlays,
    List<AudioTrack>? audioTracks,
    List<StickerOverlay>? stickers,
    List<VideoOverlay>? videoOverlays,
  }) =>
      TimelineProject(
        tracks: tracks ?? _project.tracks,
        overlays: overlays ?? _project.overlays,
        audioTracks: audioTracks ?? _project.audioTracks,
        stickers: stickers ?? _project.stickers,
        videoOverlays: videoOverlays ?? _project.videoOverlays,
      );

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
      await _updateProject(_with(tracks: tracks));
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
    await _updateProject(_with(tracks: tracks));
  }

  Future<void> _trimClip(
      String clipId, TrimEdge edge, Duration newTimelinePos) async {    final found = _findClip(clipId);
    if (found == null) return;
    final (ti, ci, clip) = found;
    final updated = edge == TrimEdge.start
        ? trimClipStart(clip, newTimelinePos)
        : trimClipEnd(clip, newTimelinePos);
    await _replaceClip(ti, ci, updated);
  }

  Future<void> _trimAudio(
      String audioId, TrimEdge edge, Duration newTimelinePos) async {
    final tracks = List<AudioTrack>.from(_project.audioTracks);
    final idx = tracks.indexWhere((t) => t.id == audioId);
    if (idx < 0) return;
    tracks[idx] = edge == TrimEdge.start
        ? trimAudioStart(tracks[idx], newTimelinePos)
        : trimAudioEnd(tracks[idx], newTimelinePos);
    await _updateProject(_with(audioTracks: tracks));
  }

  Future<void> _deleteAudio(String audioId) async {
    if (_selectedAudioId == audioId) _selectedAudioId = null;
    await _updateProject(_with(
        audioTracks:
            _project.audioTracks.where((t) => t.id != audioId).toList()));
  }

  Widget _buildAudioToolbar() {
    final track = _project.audioTracks
        .where((t) => t.id == _selectedAudioId)
        .firstOrNull;
    if (track == null) return const SizedBox.shrink();
    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.volume_up, size: 18),
            label: const Text('Volume'),
            onPressed: () => _onAudioTap(track),
          ),
          TextButton.icon(
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Hapus'),
            onPressed: () => _deleteAudio(track.id),
          ),
        ],
      ),
    );
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
    await _updateProject(_with(tracks: tracks));
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
    await _updateProject(_with(tracks: tracks));
  }

  Future<void> _deleteSelected() async {
    final found = _selectedClipId == null ? null : _findClip(_selectedClipId!);
    if (found == null) return;
    final (ti, ci, _) = found;
    final tracks = List<VideoTrack>.from(_project.tracks);
    final clips = List<Clip>.from(tracks[ti].clips)..removeAt(ci);
    tracks[ti] = VideoTrack(id: tracks[ti].id, clips: clips);
    _selectedClipId = null;
    await _updateProject(_with(tracks: tracks));
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
    await _updateProject(_with(overlays: [..._project.overlays, overlay]));
  }

  Future<void> _onOverlayTap(TextOverlay overlay) async {
    final controller = TextEditingController(text: overlay.text);
    var fontSize = overlay.fontSize;
    final keyframes = [...overlay.keyframes]
      ..sort((a, b) => a.time.compareTo(b.time));
    String fmt(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Teks'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Teks',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
              Row(
                children: [
                  const Text('Ukuran'),
                  Expanded(
                    child: Slider(
                      value: fontSize,
                      min: 12,
                      max: 120,
                      divisions: 27,
                      label: '${fontSize.round()}',
                      onChanged: (v) =>
                          setDialogState(() => fontSize = v),
                    ),
                  ),
                ],
              ),
              if (keyframes.isNotEmpty)
                Wrap(
                  spacing: 6,
                  children: [
                    for (var i = 0; i < keyframes.length; i++)
                      InputChip(
                        label: Text(fmt(keyframes[i].time)),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () =>
                            setDialogState(() => keyframes.removeAt(i)),
                        onPressed: () => Navigator.pop(ctx, 'goto:$i'),
                      ),
                  ],
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Keyframe di playhead'),
                    onPressed: () {
                      final offset = _player.position - overlay.start;
                      if (offset < Duration.zero ||
                          offset > overlay.end - overlay.start) {
                        return;
                      }
                      setDialogState(() {
                        keyframes.removeWhere((k) =>
                            (k.time - offset).inMilliseconds.abs() < 150);
                        keyframes.add(TextKeyframe(
                          time: offset,
                          x: overlay.x,
                          y: overlay.y,
                          fontSize: fontSize,
                        ));
                        keyframes.sort(
                            (a, b) => a.time.compareTo(b.time));
                      });
                    },
                  ),
                ],
              ),
              const Text(
                'Geser teks di preview untuk memindah posisi.\n'
                'Ketuk keyframe untuk lompat ke sana, lalu geser\n'
                'untuk mengubah posisi keyframe itu.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: const Text('Hapus',
                    style: TextStyle(color: Colors.red)),
                onPressed: () => Navigator.pop(ctx, 'delete'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Simpan'),
            ),
          ],
        ),
      ),
    );
    final newText = controller.text.trim();
    controller.dispose();
    TextOverlay savedAs(TextOverlay o) => o.copyWith(
          text: newText.isEmpty ? o.text : newText,
          fontSize: fontSize,
          keyframes: keyframes,
        );
    if (action == 'delete') {
      await _updateProject(_with(
          overlays:
              _project.overlays.where((o) => o.id != overlay.id).toList()));
    } else if (action == 'save') {
      await _updateProject(_with(
          overlays: _project.overlays
              .map((o) => o.id == overlay.id ? savedAs(o) : o)
              .toList()));
    } else if (action != null && action.startsWith('goto:')) {
      // Save first (indices refer to the edited list), then jump the
      // playhead to the keyframe so dragging edits it.
      final i = int.parse(action.substring(5));
      await _updateProject(_with(
          overlays: _project.overlays
              .map((o) => o.id == overlay.id ? savedAs(o) : o)
              .toList()));
      final saved = _project.overlays.firstWhere((o) => o.id == overlay.id);
      final kfs = [...saved.keyframes]
        ..sort((a, b) => a.time.compareTo(b.time));
      if (i >= 0 && i < kfs.length) {
        await _player.seek(saved.start + kfs[i].time);
      }
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
    // Fade in/out and crossfade are mutually exclusive on the same edge.
    final current = isIn
        ? clip.transitionIn
        : (clip.transitionOut.type == TransitionType.fade
            ? clip.transitionOut
            : const ClipTransition());
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

  Future<void> _setClipSpeed(double speed) async {
    final found = _selectedClipId == null ? null : _findClip(_selectedClipId!);
    if (found == null) return;
    final (ti, ci, clip) = found;
    // Don't let a slower clip grow over its neighbour.
    final clips = _project.tracks[ti].clips;
    final maxEnd = ci + 1 < clips.length ? clips[ci + 1].timelineStart : null;
    await _replaceClip(ti, ci, setClipSpeed(clip, speed, maxEnd: maxEnd));
  }

  Future<Duration?> _probeAudioDuration(String path) async {
    final player = AudioPlayer();
    try {
      await player.setSource(audioSourceForPath(path));
      return await player.getDuration();
    } catch (e) {
      debugPrint('audio probe failed: $e');
      return null;
    } finally {
      await player.dispose();
    }
  }

  /// Picks an audio file and adds it as a background track starting at 0.
  Future<void> _pickAndAddAudio() async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      final picked = await _picker.pickAudio();
      if (picked == null) return;
      final sourceDuration = await _probeAudioDuration(picked.path);
      if (sourceDuration == null || sourceDuration == Duration.zero) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Gagal membaca file audio')),
          );
        }
        return;
      }
      final projectLen = _project.duration;
      final duration = projectLen > Duration.zero
          ? (sourceDuration < projectLen ? sourceDuration : projectLen)
          : sourceDuration;
      final track = AudioTrack(
        id: 'aud-${DateTime.now().millisecondsSinceEpoch}',
        path: picked.path,
        name: picked.name,
        timelineStart: Duration.zero,
        trimStart: Duration.zero,
        duration: duration,
        sourceDuration: sourceDuration,
      );
      await _updateProject(
          _with(audioTracks: [..._project.audioTracks, track]));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _onAudioTap(AudioTrack track) async {
    var volume = track.volume;
    var fadeIn = track.fadeIn > Duration.zero;
    var fadeOut = track.fadeOut > Duration.zero;
    const oneSec = Duration(seconds: 1);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(track.name,
              overflow: TextOverflow.ellipsis),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text('Volume'),
                  Expanded(
                    child: Slider(
                      value: volume,
                      min: 0,
                      max: 2,
                      divisions: 20,
                      label: '${(volume * 100).round()}%',
                      onChanged: (v) =>
                          setDialogState(() => volume = v),
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FilterChip(
                    label: const Text('Fade in'),
                    selected: fadeIn,
                    onSelected: (v) => setDialogState(() => fadeIn = v),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('Fade out'),
                    selected: fadeOut,
                    onSelected: (v) => setDialogState(() => fadeOut = v),
                  ),
                ],
              ),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: const Text('Hapus',
                    style: TextStyle(color: Colors.red)),
                onPressed: () => Navigator.pop(ctx, 'delete'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Simpan'),
            ),
          ],
        ),
      ),
    );
    if (action == 'delete') {
      await _deleteAudio(track.id);
    } else if (action == 'save') {
      await _updateProject(_with(
          audioTracks: _project.audioTracks
              .map((t) => t.id == track.id
                  ? t.copyWith(
                      volume: volume,
                      fadeIn: fadeIn ? oneSec : Duration.zero,
                      fadeOut: fadeOut ? oneSec : Duration.zero,
                    )
                  : t)
              .toList()));
    }
  }

  /// Picks an image and pins it as a sticker for 3s from the playhead.
  Future<void> _pickAndAddVideoOverlay() async {
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

      final start = _player.position;
      // Show at most 5s by default; the user can extend via the dialog later.
      final showFor = duration < const Duration(seconds: 5)
          ? duration
          : const Duration(seconds: 5);
      final pip = VideoOverlay(
        id: 'pip-${DateTime.now().millisecondsSinceEpoch}',
        path: picked.path,
        name: picked.name,
        start: start,
        end: start + showFor,
      );
      await _updateProject(
          _with(videoOverlays: [..._project.videoOverlays, pip]));
      _snack('Video overlay ditambahkan — geser di preview');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  List<VideoOverlay> _activePips() {
    final pos = _player.position;
    return _project.videoOverlays
        .where((p) => pos >= p.start && pos < p.end)
        .toList();
  }

  /// Moves a PiP overlay by a fractional delta of the video frame.
  Future<void> _movePip(String id, double dx, double dy) async {
    _pushDragHistory();
    final overlays = _project.videoOverlays.map((p) {
      if (p.id != id) return p;
      return p.copyWith(
        x: (p.x + dx).clamp(0.0, 1.0),
        y: (p.y + dy).clamp(0.0, 1.0),
      );
    }).toList();
    _project = _with(videoOverlays: overlays);
    // Lightweight update: don't rebuild audio players while dragging.
    setState(() {});
  }

  Future<void> _onPipTap(VideoOverlay pip) async {
    var scale = pip.scale;
    var volume = pip.volume;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(pip.name, overflow: TextOverflow.ellipsis),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text('Ukuran'),
                  Expanded(
                    child: Slider(
                      value: scale,
                      min: 0.1,
                      max: 1.0,
                      divisions: 18,
                      label: '${(scale * 100).round()}%',
                      onChanged: (v) =>
                          setDialogState(() => scale = v),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const Text('Volume'),
                  Expanded(
                    child: Slider(
                      value: volume,
                      min: 0.0,
                      max: 1.0,
                      divisions: 10,
                      label: volume == 0
                          ? 'Bisukan'
                          : '${(volume * 100).round()}%',
                      onChanged: (v) =>
                          setDialogState(() => volume = v),
                    ),
                  ),
                ],
              ),
              const Text(
                'Geser kotak di preview untuk memindah posisi.\n'
                'Video asli tampil di hasil export.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: const Text('Hapus',
                    style: TextStyle(color: Colors.red)),
                onPressed: () => Navigator.pop(ctx, 'delete'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Simpan'),
            ),
          ],
        ),
      ),
    );
    if (action == 'delete') {
      await _updateProject(_with(
          videoOverlays: _project.videoOverlays
              .where((p) => p.id != pip.id)
              .toList()));
    } else if (action == 'save') {
      await _updateProject(_with(
          videoOverlays: _project.videoOverlays
              .map((p) => p.id == pip.id
                  ? p.copyWith(scale: scale, volume: volume)
                  : p)
              .toList()));
    }
  }

  Future<void> _pickAndAddSticker() async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      final picked = await _picker.pickImage();
      if (picked == null) return;
      final start = _player.position;
      final sticker = StickerOverlay(
        id: 'stk-${DateTime.now().millisecondsSinceEpoch}',
        path: picked.path,
        name: picked.name,
        start: start,
        end: start + const Duration(seconds: 3),
      );
      await _updateProject(
          _with(stickers: [..._project.stickers, sticker]));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Stiker ditambahkan — geser di preview')),
        );
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _onStickerTap(StickerOverlay sticker) async {
    var scale = sticker.scale;
    final keyframes = [...sticker.keyframes]
      ..sort((a, b) => a.time.compareTo(b.time));
    String fmt(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(sticker.name,
              overflow: TextOverflow.ellipsis),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text('Ukuran'),
                  Expanded(
                    child: Slider(
                      value: scale,
                      min: 0.25,
                      max: 3,
                      divisions: 11,
                      label: '${scale.toStringAsFixed(2)}x',
                      onChanged: (v) =>
                          setDialogState(() => scale = v),
                    ),
                  ),
                ],
              ),
              if (keyframes.isNotEmpty)
                Wrap(
                  spacing: 6,
                  children: [
                    for (var i = 0; i < keyframes.length; i++)
                      InputChip(
                        label: Text(fmt(keyframes[i].time)),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () =>
                            setDialogState(() => keyframes.removeAt(i)),
                        onPressed: () => Navigator.pop(ctx, 'goto:$i'),
                      ),
                  ],
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Keyframe di playhead'),
                    onPressed: () {
                      final offset = _player.position - sticker.start;
                      if (offset < Duration.zero ||
                          offset > sticker.end - sticker.start) {
                        return;
                      }
                      setDialogState(() {
                        keyframes.removeWhere((k) =>
                            (k.time - offset).inMilliseconds.abs() < 150);
                        keyframes.add(StickerKeyframe(
                          time: offset,
                          x: sticker.x,
                          y: sticker.y,
                          scale: scale,
                        ));
                        keyframes.sort(
                            (a, b) => a.time.compareTo(b.time));
                      });
                    },
                  ),
                ],
              ),
              const Text(
                'Ketuk keyframe lalu geser stiker di preview untuk mengubahnya.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: const Text('Hapus',
                    style: TextStyle(color: Colors.red)),
                onPressed: () => Navigator.pop(ctx, 'delete'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Simpan'),
            ),
          ],
        ),
      ),
    );
    if (action == 'delete') {
      await _updateProject(_with(
          stickers:
              _project.stickers.where((s) => s.id != sticker.id).toList()));
    } else if (action == 'save') {
      await _updateProject(_with(
          stickers: _project.stickers
              .map((s) => s.id == sticker.id
                  ? s.copyWith(scale: scale, keyframes: keyframes)
                  : s)
              .toList()));
    } else if (action != null && action.startsWith('goto:')) {
      // Save first (indices refer to the edited list), then jump the
      // playhead to the keyframe so dragging edits it.
      final i = int.parse(action.substring(5));
      await _updateProject(_with(
          stickers: _project.stickers
              .map((s) => s.id == sticker.id
                  ? s.copyWith(scale: scale, keyframes: keyframes)
                  : s)
              .toList()));
      final saved = _project.stickers.firstWhere((s) => s.id == sticker.id);
      final kfs = [...saved.keyframes]
        ..sort((a, b) => a.time.compareTo(b.time));
      if (i >= 0 && i < kfs.length) {
        await _player.seek(saved.start + kfs[i].time);
      }
    }
  }

  /// Moves a text overlay by a fractional delta of the video frame.
  /// When the playhead sits within 150ms of a keyframe, the drag adjusts
  /// that keyframe; otherwise it moves the base pose (t=0).
  Future<void> _moveText(String id, double dx, double dy) async {
    _pushDragHistory();
    final pos = _player.position;
    final overlays = _project.overlays.map((o) {
      if (o.id != id) return o;
      final offset = pos - o.start;
      final ki = o.keyframes.indexWhere(
          (k) => (k.time - offset).inMilliseconds.abs() < 150);
      if (ki >= 0) {
        final kfs = [...o.keyframes];
        final k = kfs[ki];
        kfs[ki] = TextKeyframe(
          time: k.time,
          x: (k.x + dx).clamp(0.0, 1.0),
          y: (k.y + dy).clamp(0.0, 1.0),
          fontSize: k.fontSize,
        );
        return o.copyWith(keyframes: kfs);
      }
      return o.copyWith(
        x: (o.x + dx).clamp(0.0, 1.0),
        y: (o.y + dy).clamp(0.0, 1.0),
      );
    }).toList();
    _project = _with(overlays: overlays);
    // Lightweight update: don't rebuild audio players while dragging.
    setState(() {});
  }

  /// Moves a sticker by a fractional delta of the video frame.
  /// When the playhead sits within 150ms of a keyframe, the drag adjusts
  /// that keyframe; otherwise it moves the base pose (t=0).
  Future<void> _moveSticker(String id, double dx, double dy) async {
    _pushDragHistory();
    final pos = _player.position;
    final stickers = _project.stickers.map((s) {
      if (s.id != id) return s;
      final offset = pos - s.start;
      final ki = s.keyframes.indexWhere((k) =>
          (k.time - offset).inMilliseconds.abs() < 150);
      if (ki >= 0) {
        final kfs = [...s.keyframes];
        final k = kfs[ki];
        kfs[ki] = StickerKeyframe(
          time: k.time,
          x: (k.x + dx).clamp(0.0, 1.0),
          y: (k.y + dy).clamp(0.0, 1.0),
          scale: k.scale,
        );
        return s.copyWith(keyframes: kfs);
      }
      return s.copyWith(
        x: (s.x + dx).clamp(0.0, 1.0),
        y: (s.y + dy).clamp(0.0, 1.0),
      );
    }).toList();
    _project = _with(stickers: stickers);
    // Lightweight update: don't rebuild audio players while dragging.
    setState(() {});
  }

  List<StickerOverlay> _activeStickers() {
    final pos = _player.position;
    return _project.stickers
        .where((s) => pos >= s.start && pos < s.end)
        .toList();
  }

  Future<void> _export() async {
    if (_project.tracks.every((t) => t.clips.isEmpty)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Timeline kosong, belum ada yang diekspor')),
        );
      }
      return;
    }

    final fileName = 'ove_export_${DateTime.now().millisecondsSinceEpoch}.mp4';
    // Web has no filesystem: the wasm runner triggers a browser download,
    // so the "path" is just a filename.
    final String outPath;
    if (kIsWeb) {
      outPath = fileName;
    } else {
      final dir = await getTemporaryDirectory();
      outPath = '${dir.path}/$fileName';
    }
    final progress = _exportProgress;
    final wasmLoading = _wasmLoading;
    progress.value = 0;
    wasmLoading.value = false;
    if (!mounted) return;
    // ignore: use_build_context_synchronously
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Mengekspor video...'),
        content: ValueListenableBuilder<bool>(
          valueListenable: wasmLoading,
          builder: (_, loading, __) {
            if (loading) {
              return const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(),
                  SizedBox(height: 8),
                  Text('Menyiapkan ffmpeg.wasm (unduh sekali saja)...'),
                ],
              );
            }
            return ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (_, p, __) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: p),
                  const SizedBox(height: 8),
                  Text('${(p * 100).round()}%'),
                ],
              ),
            );
          },
        ),
      ),
    );
    try {
      await _engine.exportProject(
        _project,
        ExportConfig(outputPath: outPath),
        onProgress: (p) => progress.value = p,
      );
      if (mounted) {
        Navigator.of(context).pop(); // close progress dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(kIsWeb ? 'Video diunduh: $fileName' : 'Tersimpan: $outPath')),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export gagal: $e')),
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
  /// (Crossfades render as hard cuts in preview; only true fades ramp.)
  double _fadeOpacity(Clip? clip) {
    if (clip == null) return 1.0;
    var opacity = 1.0;
    final pos = _player.position;
    final tIn = clip.transitionIn;
    if (tIn.isEnabled && tIn.type == TransitionType.fade) {
      final elapsed = pos - clip.timelineStart;
      if (elapsed < tIn.duration) {
        opacity *= elapsed.inMilliseconds / tIn.duration.inMilliseconds;
      }
    }
    final tOut = clip.transitionOut;
    if (tOut.isEnabled && tOut.type == TransitionType.fade) {
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

  /// The video widget for a controller, with the clip's color filter.
  Widget _filteredVideo(VideoPlayerController controller, Clip? clip) {
    Widget video = AspectRatio(
      aspectRatio: controller.value.aspectRatio,
      child: VideoPlayer(controller),
    );
    if (clip != null && clip.filter != VideoFilter.none) {
      video = ColorFiltered(
        colorFilter: ColorFilter.matrix(clip.filter.matrix),
        child: video,
      );
    }
    return video;
  }

  Widget _buildPreview() {
    final controller = _player.controller;
    final clip = _player.activeClip;
    Widget? video;
    if (controller != null && controller.value.isInitialized) {
      video = _filteredVideo(controller, clip);
      final opacity = _fadeOpacity(clip);
      if (opacity < 1.0) {
        video = Opacity(opacity: opacity, child: video);
      }
      // True crossfade preview: the incoming clip dissolves in over the
      // outgoing one. (Wipe/slide kinds preview as a dissolve; export
      // renders the real effect.)
      final progress = _player.transitionProgress;
      final next = _player.nextController;
      final nextClip = _player.nextClip;
      if (progress >= 0 && next != null && next.value.isInitialized) {
        video = Stack(
          children: [
            video,
            Opacity(
              opacity: progress.clamp(0.0, 1.0),
              child: _filteredVideo(next, nextClip),
            ),
          ],
        );
      }
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // The rect the video actually occupies (aspect-fit, centered).
        var vw = constraints.maxWidth;
        var vh = constraints.maxHeight;
        var left = 0.0;
        var top = 0.0;
        if (controller != null && controller.value.isInitialized) {
          final ar = controller.value.aspectRatio;
          vw = constraints.maxWidth;
          vh = vw / ar;
          if (vh > constraints.maxHeight) {
            vh = constraints.maxHeight;
            vw = vh * ar;
          }
          left = (constraints.maxWidth - vw) / 2;
          top = (constraints.maxHeight - vh) / 2;
        }
        return Stack(
          children: [
            Align(alignment: Alignment.center, child: video),
            if (video == null)
              Center(
                child: Text(
                  _project.tracks.isEmpty
                      ? 'Ketuk + untuk menambahkan video'
                      : 'Preview @ ${_player.position.inSeconds}s',
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            for (final o in _activeOverlays())
              Builder(builder: (context) {
                // Animated pose at the playhead; dragging near a keyframe
                // edits that keyframe (see _moveText).
                final pose = textPoseAt(o, _player.position - o.start);
                final cx = left + pose.x * vw;
                final cy = top + pose.y * vh;
                return Positioned(
                  left: cx - vw / 2,
                  top: cy - 48,
                  width: vw,
                  height: 96,
                  child: GestureDetector(
                    onPanStart: (_) => _beginDrag(),
                    onPanUpdate: (d) =>
                        _moveText(o.id, d.delta.dx / vw, d.delta.dy / vh),
                    onTap: () => _onOverlayTap(o),
                    child: Align(
                      alignment: Alignment.center,
                      child: Text(
                        o.text,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: pose.fontSize,
                          color: Colors.white,
                          shadows: const [
                            Shadow(blurRadius: 8, color: Colors.black87),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            for (final s in _activeStickers())
              Builder(builder: (context) {
                // Animated pose at the playhead; dragging near a keyframe
                // edits that keyframe (see _moveSticker).
                final pose = stickerPoseAt(s, _player.position - s.start);
                final eff = s.keyframes.isEmpty
                    ? s
                    : s.copyWith(x: pose.x, y: pose.y, scale: pose.scale);
                return _DraggableSticker(
                  sticker: eff,
                  videoLeft: left,
                  videoTop: top,
                  videoWidth: vw,
                  videoHeight: vh,
                  onMove: (dx, dy) => _moveSticker(s.id, dx / vw, dy / vh),
                  onDragStart: _beginDrag,
                );
              }),
            for (final pip in _activePips())
              _DraggablePip(
                pip: pip,
                videoLeft: left,
                videoTop: top,
                videoWidth: vw,
                videoHeight: vh,
                onMove: (dx, dy) => _movePip(pip.id, dx / vw, dy / vh),
                onDragStart: _beginDrag,
                onTap: () => _onPipTap(pip),
              ),
          ],
        );
      },
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

  Widget _buildChromaRow() {
    final clip = _selectedClip;
    if (clip == null) return const SizedBox.shrink();
    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FilterChip(
            label: const Text('Green screen'),
            selected: clip.chromaKey.enabled,
            onSelected: (_) => _showChromaDialog(clip),
          ),
        ],
      ),
    );
  }

  Future<void> _showChromaDialog(Clip clip) async {
    var ck = clip.chromaKey;
    const keyColors = [0x00FF00, 0x0000FF, 0xFF0000, 0xFF00FF];
    const bgColors = [
      0x000000,
      0xFFFFFF,
      0x0000FF,
      0xFF0000,
      0x00FF00,
      0x1A1A2E,
    ];
    Widget swatches(List<int> colors, int selected, ValueChanged<int> onPick) {
      return Wrap(
        spacing: 8,
        children: [
          for (final c in colors)
            GestureDetector(
              onTap: () => onPick(c),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Color(0xFF000000 | c),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: c == selected ? Colors.white : Colors.grey.shade700,
                    width: c == selected ? 3 : 1,
                  ),
                ),
              ),
            ),
        ],
      );
    }

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Green screen'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  title: const Text('Aktif'),
                  value: ck.enabled,
                  onChanged: (v) =>
                      setDialogState(() => ck = ck.copyWith(enabled: v)),
                  contentPadding: EdgeInsets.zero,
                ),
                const Text('Warna kunci'),
                const SizedBox(height: 6),
                swatches(keyColors, ck.color,
                    (c) => setDialogState(() => ck = ck.copyWith(color: c))),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Sensitivitas'),
                    Expanded(
                      child: Slider(
                        value: ck.similarity,
                        min: 0.01,
                        max: 1.0,
                        label: ck.similarity.toStringAsFixed(2),
                        onChanged: (v) => setDialogState(
                            () => ck = ck.copyWith(similarity: v)),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Text('Lembut tepi'),
                    Expanded(
                      child: Slider(
                        value: ck.blend,
                        min: 0.0,
                        max: 1.0,
                        label: ck.blend.toStringAsFixed(2),
                        onChanged: (v) => setDialogState(
                            () => ck = ck.copyWith(blend: v)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('Warna latar pengganti'),
                const SizedBox(height: 6),
                swatches(bgColors, ck.bgColor,
                    (c) => setDialogState(() => ck = ck.copyWith(bgColor: c))),
                const SizedBox(height: 12),
                const Text(
                  'Efek hanya terlihat di hasil export,\nbelum di preview.',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Simpan'),
            ),
          ],
        ),
      ),
    );
    if (action == 'save') {
      final found = _selectedClipId == null ? null : _findClip(_selectedClipId!);
      if (found == null) return;
      final (ti, ci, _) = found;
      await _replaceClip(ti, ci, clip.copyWith(chromaKey: ck));
    }
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
    final crossfadeOut = clip.transitionOut.type == TransitionType.crossfade;
    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
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
                selected: clip.transitionOut.isEnabled &&
                    clip.transitionOut.type == TransitionType.fade,
                onSelected: (_) => _toggleFade(false),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('Crossfade'),
                selected: crossfadeOut,
                onSelected: _canCrossfade ? (_) => _toggleCrossfade() : null,
              ),
            ],
          ),
          if (crossfadeOut)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 6,
                children: [
                  for (final kind in XfadeKind.values)
                    ChoiceChip(
                      label: Text(kind.label),
                      selected: clip.transitionOut.xfadeKind == kind,
                      onSelected: (_) => _setXfadeKind(kind),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// True when the selected clip is immediately followed by another clip.
  bool get _canCrossfade {
    final found = _selectedClipId == null ? null : _findClip(_selectedClipId!);
    if (found == null) return false;
    final (ti, ci, clip) = found;
    final clips = _project.tracks[ti].clips;
    return ci + 1 < clips.length &&
        clips[ci + 1].timelineStart == clip.timelineEnd;
  }

  /// Toggles a 1s crossfade on the selected clip's out-transition.
  /// Mutually exclusive with fade-out.
  Future<void> _toggleCrossfade() async {
    final found = _selectedClipId == null ? null : _findClip(_selectedClipId!);
    if (found == null) return;
    final (ti, ci, clip) = found;
    final isCrossfade = clip.transitionOut.type == TransitionType.crossfade;
    await _replaceClip(
      ti,
      ci,
      clip.copyWith(
        transitionOut: isCrossfade
            ? const ClipTransition()
            : const ClipTransition(
                type: TransitionType.crossfade,
                duration: Duration(seconds: 1),
              ),
      ),
    );
  }

  /// Changes the visual style of the selected clip's crossfade.
  Future<void> _setXfadeKind(XfadeKind kind) async {
    final found = _selectedClipId == null ? null : _findClip(_selectedClipId!);
    if (found == null) return;
    final (ti, ci, clip) = found;
    if (clip.transitionOut.type != TransitionType.crossfade) return;
    await _replaceClip(
      ti,
      ci,
      clip.copyWith(
        transitionOut: clip.transitionOut.copyWith(xfadeKind: kind),
      ),
    );
  }

  Widget _buildSpeedRow() {
    final clip = _selectedClip;
    if (clip == null) return const SizedBox.shrink();
    const speeds = [0.5, 1.0, 1.5, 2.0];
    return Container(
      color: Colors.grey.shade900,
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 10),
            child: Text('Speed',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
          ),
          for (final s in speeds)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: ChoiceChip(
                label: Text('${s}x'),
                selected: clip.speed == s,
                onSelected: (_) => _setClipSpeed(s),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_projectName ?? 'Open Video Editor'),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Urungkan',
            onPressed: _history.canUndo ? _undo : null,
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            tooltip: 'Ulangi',
            onPressed: _history.canRedo ? _redo : null,
          ),
          PopupMenuButton<String>(
            icon: _adding
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add),
            tooltip: 'Tambah',
            onSelected: _onAddMenu,
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'video',
                child: ListTile(
                    leading: Icon(Icons.video_library),
                    title: Text('Video')),
              ),
              const PopupMenuItem(
                value: 'pip',
                child: ListTile(
                    leading: Icon(Icons.picture_in_picture_alt),
                    title: Text('Video overlay (PiP)')),
              ),
              const PopupMenuItem(
                value: 'text',
                child: ListTile(
                    leading: Icon(Icons.text_fields),
                    title: Text('Teks')),
              ),
              const PopupMenuItem(
                value: 'audio',
                child: ListTile(
                    leading: Icon(Icons.music_note),
                    title: Text('Musik')),
              ),
              const PopupMenuItem(
                value: 'sticker',
                child: ListTile(
                    leading: Icon(Icons.emoji_emotions_outlined),
                    title: Text('Stiker')),
              ),
            ],
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Proyek',
            onSelected: _onProjectMenu,
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                  value: 'save', child: Text('Simpan proyek')),
              PopupMenuItem(
                  value: 'open', child: Text('Buka proyek')),
              PopupMenuItem(value: 'new', child: Text('Proyek baru')),
            ],
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
          if (_selectedClipId != null) _buildSpeedRow(),
          if (_selectedClipId != null) _buildFilterRow(),
          if (_selectedClipId != null) _buildFadeRow(),
          if (_selectedClipId != null) _buildChromaRow(),
          if (_selectedAudioId != null) _buildAudioToolbar(),
          SizedBox(
            height: 260,
            child: TimelineView(
              project: _project,
              position: _player.position,
              selectedClipId: _selectedClipId,
              selectedAudioId: _selectedAudioId,
              thumbnails: _thumbnails,
              onSeek: _player.seek,
              onClipSelected: (id) => setState(() {
                _selectedClipId = id;
                if (id != null) _selectedAudioId = null;
              }),
              onAudioSelected: (id) => setState(() {
                _selectedAudioId = id;
                if (id != null) _selectedClipId = null;
              }),
              onOverlayTap: _onOverlayTap,
              onAudioTap: _onAudioTap,
              onStickerTap: _onStickerTap,
              onPipTap: _onPipTap,
              onTrim: _trimClip,
              onAudioTrim: _trimAudio,
            ),
          ),
        ],
      ),
    );
  }
}

/// A picture-in-picture video placeholder in the preview.
///
/// Shows a real thumbnail when the runner can extract one (desktop/mobile);
/// otherwise a labeled box (web). Draggable like a sticker; the actual
/// video is composited at export.
class _DraggablePip extends StatelessWidget {
  const _DraggablePip({
    required this.pip,
    required this.videoLeft,
    required this.videoTop,
    required this.videoWidth,
    required this.videoHeight,
    required this.onMove,
    this.onDragStart,
    this.onTap,
  });

  final VideoOverlay pip;
  final double videoLeft;
  final double videoTop;
  final double videoWidth;
  final double videoHeight;

  /// Pixel delta of the drag; converted to fractional by the caller.
  final void Function(double dx, double dy) onMove;
  final VoidCallback? onDragStart;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (videoWidth <= 0 || videoHeight <= 0) return const SizedBox.shrink();
    // Width matches the export scale (fraction of export width); height is
    // a 16:9 estimate — the export preserves the source aspect ratio.
    final w = videoWidth * pip.scale;
    final h = w * 9 / 16;
    final cx = videoLeft + pip.x * videoWidth;
    final cy = videoTop + pip.y * videoHeight;
    return Positioned(
      left: cx - w / 2,
      top: cy - h / 2,
      width: w,
      height: h,
      child: GestureDetector(
        onPanStart: (_) => onDragStart?.call(),
        onPanUpdate: (d) => onMove(d.delta.dx, d.delta.dy),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white70, width: 1.5),
            borderRadius: BorderRadius.circular(4),
            color: Colors.black54,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: FutureBuilder<Uint8List?>(
              future: createDefaultRunner().extractFrame(
                  pip.path,
                  pip.sourceStart + const Duration(milliseconds: 500)),
              builder: (ctx, snap) {
                if (snap.hasData && snap.data != null) {
                  return Image.memory(snap.data!, fit: BoxFit.cover);
                }
                return const Center(
                  child: Icon(Icons.picture_in_picture_alt,
                      color: Colors.white70),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// A sticker rendered over the preview video, draggable to reposition.
///
/// Position is the sticker's normalized (0..1) center on the video frame,
/// matching the export overlay math.
class _DraggableSticker extends StatelessWidget {
  const _DraggableSticker({
    required this.sticker,
    required this.videoLeft,
    required this.videoTop,
    required this.videoWidth,
    required this.videoHeight,
    required this.onMove,
    this.onDragStart,
  });

  final StickerOverlay sticker;
  final double videoLeft;
  final double videoTop;
  final double videoWidth;
  final double videoHeight;

  /// Pixel delta of the drag; converted to fractional by the caller.
  final void Function(double dx, double dy) onMove;

  final VoidCallback? onDragStart;

  @override
  Widget build(BuildContext context) {
    if (videoWidth <= 0 || videoHeight <= 0) return const SizedBox.shrink();
    // Base size = 25% of the video width, like the export overlay.
    final size = videoWidth * 0.25 * sticker.scale;
    final cx = videoLeft + sticker.x * videoWidth;
    final cy = videoTop + sticker.y * videoHeight;
    return Positioned(
      left: cx - size / 2,
      top: cy - size / 2,
      width: size,
      height: size,
      child: GestureDetector(
        onPanStart: (_) => onDragStart?.call(),
        onPanUpdate: (d) => onMove(d.delta.dx, d.delta.dy),
        child: buildStickerImage(sticker.path),
      ),
    );
  }
}
