// UI-layer preview playback for a [TimelineProject].
//
// Plays the clip under the playhead with package:video_player and advances
// across contiguous clips, keeping the timeline playhead in sync.
// This is the preview path for milestone 2; the native [VideoEngine]
// (FFmpeg) remains the path for export rendering.

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart' hide VideoTrack;

import '../engine/video_engine.dart';
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

  Duration get position => _position;
  bool get playing => _playing;
  VideoPlayerController? get controller => _controller;

  Future<void> setProject(TimelineProject project) async {
    _project = project;
    if (_position > _project.duration) {
      _position = _project.duration;
    }
    await _refreshActiveClip();
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
    if (clip?.id == _activeClip?.id) return;
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
      await c.seekTo(_offsetInClip(clip, _position));
      if (_playing) await c.play();
    }
    notifyListeners();
  }

  Duration _offsetInClip(Clip clip, Duration timelinePos) {
    final offset = timelinePos - clip.timelineStart + clip.sourceStart;
    return _clampDuration(offset, clip.sourceStart, clip.sourceStart + clip.duration);
  }

  void _onTick() {
    final c = _controller;
    final clip = _activeClip;
    if (c == null || clip == null || !c.value.isInitialized) return;
    final timelinePos =
        clip.timelineStart + (c.value.position - clip.sourceStart);
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
    notifyListeners();
  }

  Future<void> pause() async {
    _playing = false;
    await _controller?.pause();
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
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }
}
