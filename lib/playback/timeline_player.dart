// UI-layer preview playback for a [TimelineProject].
//
// Plays the clip under the playhead with package:video_player and advances
// across contiguous clips, keeping the timeline playhead in sync.
// Per-clip speed is applied via VideoPlayerController.setPlaybackSpeed and
// the playhead math accounts for it. Background audio tracks play through
// package:audioplayers, offset to the playhead position.
// This is the preview path for milestone 2; the native [VideoEngine]
// (FFmpeg) remains the path for export rendering.

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart' hide VideoTrack;

import '../engine/video_engine.dart';
import 'audio_source.dart';
import 'player_controller_factory.dart';

/// Clamp [value] into [min]..[max] (Duration has no clamp method).
Duration _clampDuration(Duration value, Duration min, Duration max) =>
    value < min ? min : (value > max ? max : value);

class TimelinePlayer extends ChangeNotifier {
  TimelinePlayer();

  TimelineProject _project = const TimelineProject();
  VideoPlayerController? _controller;
  Clip? _activeClip;
  Duration _position = Duration.zero;
  bool _playing = false;
  bool _disposed = false;

  /// Incoming clip's controller while a crossfade window is active.
  /// Initialized just before the window so the dissolve starts on time;
  /// adopted as [_controller] when the boundary is crossed.
  VideoPlayerController? _nextController;
  Clip? _nextClip;

  /// 0..1 while the playhead is inside a crossfade window, -1 otherwise.
  double _transitionProgress = -1;

  /// Background audio players keyed by track id.
  final Map<String, AudioPlayer> _audioPlayers = {};

  Duration get position => _position;
  bool get playing => _playing;
  VideoPlayerController? get controller => _controller;

  /// The clip currently under the playhead (null in gaps).
  Clip? get activeClip => _activeClip;

  /// The incoming clip's controller during a crossfade window, else null.
  VideoPlayerController? get nextController => _nextController;

  /// The incoming clip during a crossfade window, else null.
  Clip? get nextClip => _nextClip;

  /// Dissolve progress 0..1 inside a crossfade window, -1 outside it.
  double get transitionProgress => _transitionProgress;

  Future<void> setProject(TimelineProject project) async {
    _project = project;
    if (_position > _project.duration) {
      _position = _project.duration;
    }
    await _syncAudioTracks();
    await _refreshActiveClip();
  }

  /// Rebuilds background audio players to match the project's tracks.
  Future<void> _syncAudioTracks() async {
    final wanted = {for (final t in _project.audioTracks) t.id};
    for (final id in _audioPlayers.keys.toList()) {
      if (!wanted.contains(id)) {
        await _audioPlayers.remove(id)?.dispose();
      }
    }
    for (final track in _project.audioTracks) {
      if (_audioPlayers.containsKey(track.id)) continue;
      final player = AudioPlayer();
      try {
        await player.setSource(audioSourceForPath(track.path));
        await player.setVolume(track.volume);
      } catch (e) {
        debugPrint('audio preview source failed: $e');
        await player.dispose();
        continue;
      }
      if (_disposed) {
        await player.dispose();
        return;
      }
      _audioPlayers[track.id] = player;
    }
    if (_playing) await _startAudio(_position);
  }

  /// Offset inside the audio file for timeline position [pos].
  Duration _audioOffset(AudioTrack track, Duration pos) =>
      track.trimStart + (pos - track.timelineStart);

  bool _audioAudible(AudioTrack track, Duration pos) =>
      pos >= track.timelineStart && pos < track.timelineEnd;

  Future<void> _startAudio(Duration pos) async {
    for (final track in _project.audioTracks) {
      final player = _audioPlayers[track.id];
      if (player == null) continue;
      if (_audioAudible(track, pos)) {
        try {
          await player.seek(_audioOffset(track, pos));
          await player.setVolume(track.volume);
          await player.resume();
        } catch (e) {
          debugPrint('audio preview play failed: $e');
        }
      } else {
        await player.pause();
      }
    }
  }

  Future<void> _pauseAudio() async {
    for (final player in _audioPlayers.values) {
      await player.pause();
    }
  }

  Future<void> _seekAudio(Duration pos) async {
    for (final track in _project.audioTracks) {
      final player = _audioPlayers[track.id];
      if (player == null) continue;
      if (_audioAudible(track, pos)) {
        try {
          await player.seek(_audioOffset(track, pos));
          if (_playing) await player.resume();
        } catch (e) {
          debugPrint('audio preview seek failed: $e');
        }
      } else {
        await player.pause();
      }
    }
  }

  /// First video track's clip containing [position], or null.
  Clip? _clipAt(Duration position) {
    if (_project.tracks.isEmpty) return null;
    for (final clip in _project.tracks.first.clips) {
      if (position >= clip.timelineStart && position < clip.timelineEnd) {
        return clip;
      }
    }
    return null;
  }

  Future<void> _refreshActiveClip() async {
    final clip = _clipAt(_position);
    final cur = _activeClip;
    // Compare geometry as well as id: trim/split/merge replace the clip
    // object while keeping the id, so an id-only check would keep a stale
    // reference and the preview would play the wrong segment.
    if (clip?.id == cur?.id &&
        clip?.timelineStart == cur?.timelineStart &&
        clip?.duration == cur?.duration &&
        clip?.sourceStart == cur?.sourceStart &&
        clip?.speed == cur?.speed) {
      return;
    }
    await _swapController(clip);
  }

  Future<void> _swapController(Clip? clip) async {
    final old = _controller;
    _controller = null;
    _activeClip = clip;
    await _clearTransition();
    if (old != null) {
      old.removeListener(_onTick);
      await old.pause();
      await old.dispose();
    }
    if (clip != null && !_disposed) {
      final c = createPlayerController(clip.source.path);
      _controller = c;
      c.addListener(_onTick);
      try {
        await c.initialize();
      } catch (e) {
        debugPrint('preview init failed: $e');
        return;
      }
      if (_disposed) return;
      await c.setPlaybackSpeed(clip.speed);
      await c.seekTo(_offsetInClip(clip, _position));
      if (_playing) await c.play();
    }
    notifyListeners();
  }

  /// Drops any in-progress crossfade preview state.
  Future<void> _clearTransition() async {
    _transitionProgress = -1;
    final n = _nextController;
    _nextController = null;
    _nextClip = null;
    if (n != null) {
      await n.pause();
      await n.dispose();
    }
  }

  /// The (next clip, effective crossfade duration) when [clip] dissolves
  /// into its successor, or null. Mirrors the export's contiguity rule.
  (Clip, Duration)? _crossfadeInto(Clip clip) {
    final t = clip.transitionOut;
    if (t.type != TransitionType.crossfade || t.duration <= Duration.zero) {
      return null;
    }
    if (_project.tracks.isEmpty) return null;
    final clips = _project.tracks.first.clips;
    final i = clips.indexWhere((c) => c.id == clip.id);
    if (i < 0 || i + 1 >= clips.length) return null;
    final next = clips[i + 1];
    if (next.timelineStart != clip.timelineEnd) return null;
    var d = t.duration;
    if (d > clip.duration) d = clip.duration;
    if (d > next.duration) d = next.duration;
    return (next, d);
  }

  /// Pre-initializes the incoming clip's controller shortly before its
  /// crossfade window so the dissolve can start on time.
  Future<void> _ensureTransitionController(
      Clip next, Duration windowStart) async {
    if (_nextClip?.id == next.id && _nextController != null) return;
    await _clearTransition();
    if (_disposed) return;
    final c = createPlayerController(next.source.path);
    _nextController = c;
    _nextClip = next;
    try {
      await c.initialize();
    } catch (e) {
      debugPrint('transition preview init failed: $e');
      await _clearTransition();
      return;
    }
    if (_disposed || _nextController != c) {
      await c.dispose();
      return;
    }
    await c.setPlaybackSpeed(next.speed);
    await c.seekTo(next.sourceStart);
  }

  Duration _offsetInClip(Clip clip, Duration timelinePos) {
    final mediaOffset = Duration(
        milliseconds:
            ((timelinePos - clip.timelineStart).inMilliseconds * clip.speed)
                .round());
    final offset = clip.sourceStart + mediaOffset;
    return _clampDuration(
        offset, clip.sourceStart, clip.sourceStart + clip.sourceDuration);
  }

  void _onTick() {
    final c = _controller;
    final clip = _activeClip;
    if (c == null || clip == null || !c.value.isInitialized) return;
    // Controller position is media time; divide by speed for timeline time.
    final mediaMs = (c.value.position - clip.sourceStart).inMilliseconds;
    final timelinePos = clip.timelineStart +
        Duration(milliseconds: (mediaMs / clip.speed).round());
    if (timelinePos >= clip.timelineEnd) {
      _advancePast(clip);
      return;
    }
    _position = timelinePos;
    _updateTransition(clip, timelinePos);
    notifyListeners();
  }

  /// Drives the crossfade preview: pre-initializes the incoming clip just
  /// before its window, plays it inside the window, and reports progress.
  void _updateTransition(Clip clip, Duration timelinePos) {
    final xf = _crossfadeInto(clip);
    if (xf == null) {
      if (_transitionProgress >= 0) {
        _clearTransition();
      }
      return;
    }
    final (next, d) = xf;
    final windowStart = clip.timelineEnd - d;
    if (timelinePos < windowStart - const Duration(milliseconds: 750)) {
      if (_transitionProgress >= 0) _clearTransition();
      return;
    }
    // ignore: discarded_futures
    _ensureTransitionController(next, windowStart);
    if (timelinePos >= windowStart) {
      final n = _nextController;
      if (n != null &&
          n.value.isInitialized &&
          !n.value.isPlaying &&
          _playing) {
        // ignore: discarded_futures
        n.play();
      }
      final elapsed = timelinePos - windowStart;
      _transitionProgress =
          (elapsed.inMilliseconds / d.inMilliseconds).clamp(0.0, 1.0);
    } else if (_transitionProgress >= 0) {
      _transitionProgress = -1;
    }
  }

  Future<void> _advancePast(Clip clip) async {
    _position = clip.timelineEnd;
    if (_position >= _project.duration) {
      await pause();
      return;
    }
    // Seamless handoff: the incoming clip's controller is already playing
    // from inside the crossfade window — adopt it instead of rebuilding.
    final n = _nextController;
    final next = _nextClip;
    if (n != null && next != null && n.value.isInitialized) {
      final old = _controller;
      _controller = n;
      _activeClip = next;
      _nextController = null;
      _nextClip = null;
      _transitionProgress = -1;
      n.addListener(_onTick);
      if (old != null) {
        old.removeListener(_onTick);
        await old.pause();
        await old.dispose();
      }
      if (_playing) await n.play();
      notifyListeners();
      return;
    }
    await _clearTransition();
    await _refreshActiveClip();
    if (_playing) await _controller?.play();
  }

  Future<void> play() async {
    if (_project.tracks.isEmpty) return;
    if (_position >= _project.duration) {
      _position = Duration.zero;
    }
    _playing = true;
    await _refreshActiveClip();
    await _controller?.play();
    await _startAudio(_position);
    notifyListeners();
  }

  Future<void> pause() async {
    _playing = false;
    await _controller?.pause();
    await _nextController?.pause();
    await _pauseAudio();
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    _position = _clampDuration(position, Duration.zero, _project.duration);
    // Scrubbing breaks the dissolve illusion; resume with a hard cut and
    // let _onTick rebuild the transition if playback continues into one.
    await _clearTransition();
    await _refreshActiveClip();
    final clip = _activeClip;
    final c = _controller;
    if (clip != null && c != null && c.value.isInitialized) {
      await c.seekTo(_offsetInClip(clip, _position));
    }
    await _seekAudio(_position);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    _controller = null;
    _nextController?.dispose();
    _nextController = null;
    _nextClip = null;
    for (final player in _audioPlayers.values) {
      player.dispose();
    }
    _audioPlayers.clear();
    super.dispose();
  }
}
