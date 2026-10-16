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

  /// Background audio players keyed by track id.
  final Map<String, AudioPlayer> _audioPlayers = {};

  Duration get position => _position;
  bool get playing => _playing;
  VideoPlayerController? get controller => _controller;

  /// The clip currently under the playhead (null in gaps).
  Clip? get activeClip => _activeClip;

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
    notifyListeners();
  }

  Future<void> _advancePast(Clip clip) async {
    _position = clip.timelineEnd;
    if (_position >= _project.duration) {
      await pause();
      return;
    }
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
    await _pauseAudio();
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    _position = _clampDuration(position, Duration.zero, _project.duration);
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
    for (final player in _audioPlayers.values) {
      player.dispose();
    }
    _audioPlayers.clear();
    super.dispose();
  }
}
