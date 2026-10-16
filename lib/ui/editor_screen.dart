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
import '../engine/timeline_ops.dart';
import '../engine/video_engine.dart';
import '../media/media_picker.dart';
import '../media/sticker_image.dart';
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
  TimelineProject _project = const TimelineProject();
  String? _selectedClipId;
  bool _adding = false;
  final _exportProgress = ValueNotifier<double>(0);

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
    _project = project;
    await _player.setProject(_project);
  }

  /// Copies the current project, replacing only the given parts.
  TimelineProject _with({
    List<VideoTrack>? tracks,
    List<TextOverlay>? overlays,
    List<AudioTrack>? audioTracks,
    List<StickerOverlay>? stickers,
  }) =>
      TimelineProject(
        tracks: tracks ?? _project.tracks,
        overlays: overlays ?? _project.overlays,
        audioTracks: audioTracks ?? _project.audioTracks,
        stickers: stickers ?? _project.stickers,
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
      await _updateProject(_with(
          overlays:
              _project.overlays.where((o) => o.id != overlay.id).toList()));
    } else if (action == 'edit') {
      final text = await _showTextDialog(initial: overlay.text);
      if (text == null || text.trim().isEmpty) return;
      await _updateProject(_with(
          overlays: _project.overlays
              .map((o) =>
                  o.id == overlay.id ? o.copyWith(text: text.trim()) : o)
              .toList()));
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
          audioTracks: _project.audioTracks
              .where((t) => t.id != track.id)
              .toList()));
    } else if (action == 'save') {
      await _updateProject(_with(
          audioTracks: _project.audioTracks
              .map((t) => t.id == track.id ? t.copyWith(volume: volume) : t)
              .toList()));
    }
  }

  /// Picks an image and pins it as a sticker for 3s from the playhead.
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
              .map((s) => s.id == sticker.id ? s.copyWith(scale: scale) : s)
              .toList()));
    }
  }

  /// Moves a sticker by a fractional delta of the video frame.
  Future<void> _moveSticker(String id, double dx, double dy) async {
    final stickers = _project.stickers
        .map((s) => s.id == id
            ? s.copyWith(
                x: (s.x + dx).clamp(0.0, 1.0),
                y: (s.y + dy).clamp(0.0, 1.0),
              )
            : s)
        .toList();
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
            for (final s in _activeStickers())
              _DraggableSticker(
                sticker: s,
                videoLeft: left,
                videoTop: top,
                videoWidth: vw,
                videoHeight: vh,
                onMove: (dx, dy) => _moveSticker(s.id, dx / vw, dy / vh),
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
        title: const Text('Open Video Editor'),
        actions: [
          IconButton(
            icon: const Icon(Icons.text_fields),
            tooltip: 'Tambah teks',
            onPressed: _addTextOverlay,
          ),
          IconButton(
            icon: const Icon(Icons.music_note),
            tooltip: 'Tambah musik',
            onPressed: _pickAndAddAudio,
          ),
          IconButton(
            icon: const Icon(Icons.emoji_emotions_outlined),
            tooltip: 'Tambah stiker',
            onPressed: _pickAndAddSticker,
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
          if (_selectedClipId != null) _buildSpeedRow(),
          if (_selectedClipId != null) _buildFilterRow(),
          if (_selectedClipId != null) _buildFadeRow(),
          SizedBox(
            height: 260,
            child: TimelineView(
              project: _project,
              position: _player.position,
              selectedClipId: _selectedClipId,
              onSeek: _player.seek,
              onClipSelected: (id) => setState(() => _selectedClipId = id),
              onOverlayTap: _onOverlayTap,
              onAudioTap: _onAudioTap,
              onStickerTap: _onStickerTap,
              onTrim: _trimClip,
            ),
          ),
        ],
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
  });

  final StickerOverlay sticker;
  final double videoLeft;
  final double videoTop;
  final double videoWidth;
  final double videoHeight;

  /// Pixel delta of the drag; converted to fractional by the caller.
  final void Function(double dx, double dy) onMove;

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
        onPanUpdate: (d) => onMove(d.delta.dx, d.delta.dy),
        child: buildStickerImage(sticker.path),
      ),
    );
  }
}
