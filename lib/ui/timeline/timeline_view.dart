// Timeline UI: renders project tracks as horizontal lanes with clip blocks
// and a draggable playhead. Pure Flutter — no engine dependency.
//
// Milestone 3: clips are selectable (tap) and the selected clip exposes
// draggable trim handles on its start/end edges.

import 'package:flutter/material.dart';

import '../../engine/video_engine.dart';

/// Which edge of a clip is being trimmed.
enum TrimEdge { start, end }

/// Horizontal multi-track timeline view.
///
/// Calls [onSeek] when the user taps/drags on empty timeline area,
/// [onClipSelected] when a clip is tapped (null = deselect),
/// and [onTrim] while a trim handle is dragged.
class TimelineView extends StatefulWidget {
  const TimelineView({
    super.key,
    required this.project,
    required this.position,
    this.selectedClipId,
    this.onSeek,
    this.onClipSelected,
    this.onOverlayTap,
    this.onAudioTap,
    this.onStickerTap,
    this.onTrim,
    this.pixelsPerSecond = 24.0,
  });

  final TimelineProject project;
  final Duration position;
  final String? selectedClipId;
  final ValueChanged<Duration>? onSeek;
  final ValueChanged<String?>? onClipSelected;
  final ValueChanged<TextOverlay>? onOverlayTap;
  final ValueChanged<AudioTrack>? onAudioTap;
  final ValueChanged<StickerOverlay>? onStickerTap;
  final void Function(String clipId, TrimEdge edge, Duration newTimelinePos)?
      onTrim;
  final double pixelsPerSecond;

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView> {
  void _seekAt(Offset local) {
    final seconds = (local.dx / widget.pixelsPerSecond)
        .clamp(0.0, widget.project.duration.inMilliseconds / 1000.0);
    widget.onSeek?.call(Duration(milliseconds: (seconds * 1000).round()));
  }

  @override
  Widget build(BuildContext context) {
    final totalWidth =
        widget.project.duration.inMilliseconds / 1000 * widget.pixelsPerSecond;
    final width = totalWidth.clamp(200.0, double.infinity).toDouble();
    final playheadX =
        widget.position.inMilliseconds / 1000 * widget.pixelsPerSecond;

    return GestureDetector(
      onTapDown: (d) {
        widget.onClipSelected?.call(null);
        _seekAt(d.localPosition);
      },
      onHorizontalDragUpdate: (d) => _seekAt(d.localPosition),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Ruler(
                    duration: widget.project.duration,
                    pixelsPerSecond: widget.pixelsPerSecond,
                  ),
                  for (final track in widget.project.tracks)
                    _TrackLane(
                      track: track,
                      pixelsPerSecond: widget.pixelsPerSecond,
                      selectedClipId: widget.selectedClipId,
                      onClipSelected: widget.onClipSelected,
                      onTrim: widget.onTrim,
                    ),
                  if (widget.project.overlays.isNotEmpty)
                    _OverlayLane(
                      overlays: widget.project.overlays,
                      pixelsPerSecond: widget.pixelsPerSecond,
                      onOverlayTap: widget.onOverlayTap,
                    ),
                  if (widget.project.audioTracks.isNotEmpty)
                    _AudioLane(
                      tracks: widget.project.audioTracks,
                      pixelsPerSecond: widget.pixelsPerSecond,
                      onAudioTap: widget.onAudioTap,
                    ),
                  if (widget.project.stickers.isNotEmpty)
                    _StickerLane(
                      stickers: widget.project.stickers,
                      pixelsPerSecond: widget.pixelsPerSecond,
                      onStickerTap: widget.onStickerTap,
                    ),
                  if (widget.project.tracks.isEmpty)
                    const _EmptyTimelineHint(),
                ],
              ),
              Positioned(
                left: playheadX.clamp(0.0, width),
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: Colors.redAccent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Ruler extends StatelessWidget {
  const _Ruler({required this.duration, required this.pixelsPerSecond});

  final Duration duration;
  final double pixelsPerSecond;

  @override
  Widget build(BuildContext context) {
    final seconds = duration.inSeconds;
    return SizedBox(
      height: 24,
      child: CustomPaint(
        painter: _RulerPainter(
          seconds: seconds,
          pixelsPerSecond: pixelsPerSecond,
        ),
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({required this.seconds, required this.pixelsPerSecond});

  final int seconds;
  final double pixelsPerSecond;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.grey.shade600;
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    for (var s = 0; s <= seconds; s++) {
      final x = s * pixelsPerSecond;
      final major = s % 5 == 0;
      canvas.drawLine(
        Offset(x, major ? 8 : 16),
        Offset(x, 24),
        paint,
      );
      if (major) {
        textPainter.text = TextSpan(
          text: '${s}s',
          style: const TextStyle(color: Colors.grey, fontSize: 10),
        );
        textPainter.layout();
        textPainter.paint(canvas, Offset(x + 2, 2));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RulerPainter old) =>
      old.seconds != seconds || old.pixelsPerSecond != pixelsPerSecond;
}

class _TrackLane extends StatelessWidget {
  const _TrackLane({
    required this.track,
    required this.pixelsPerSecond,
    this.selectedClipId,
    this.onClipSelected,
    this.onTrim,
  });

  final VideoTrack track;
  final double pixelsPerSecond;
  final String? selectedClipId;
  final ValueChanged<String?>? onClipSelected;
  final void Function(String clipId, TrimEdge edge, Duration newTimelinePos)?
      onTrim;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Stack(
        children: [
          for (final clip in track.clips)
            _ClipBlock(
              clip: clip,
              pixelsPerSecond: pixelsPerSecond,
              selected: clip.id == selectedClipId,
              onTap: () => onClipSelected?.call(clip.id),
              onTrim: onTrim == null
                  ? null
                  : (edge, pos) => onTrim!(clip.id, edge, pos),
            ),
        ],
      ),
    );
  }
}

class _ClipBlock extends StatelessWidget {
  const _ClipBlock({
    required this.clip,
    required this.pixelsPerSecond,
    required this.selected,
    this.onTap,
    this.onTrim,
  });

  final Clip clip;
  final double pixelsPerSecond;
  final bool selected;
  final VoidCallback? onTap;
  final void Function(TrimEdge edge, Duration newTimelinePos)? onTrim;

  @override
  Widget build(BuildContext context) {
    final left = clip.timelineStart.inMilliseconds / 1000 * pixelsPerSecond;
    final width = clip.duration.inMilliseconds / 1000 * pixelsPerSecond;
    return Positioned(
      left: left,
      width: width.clamp(8.0, double.infinity),
      top: 4,
      bottom: 4,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: selected ? Colors.indigo.shade300 : Colors.indigo.shade400,
            borderRadius: BorderRadius.circular(4),
            border: selected
                ? Border.all(color: Colors.white, width: 2)
                : null,
          ),
          child: Stack(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Text(
                    clip.source.id,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (selected && onTrim != null) ...[
                _TrimHandle(
                  edge: TrimEdge.start,
                  pixelsPerSecond: pixelsPerSecond,
                  anchor: clip.timelineStart,
                  onTrim: (pos) => onTrim!(TrimEdge.start, pos),
                ),
                _TrimHandle(
                  edge: TrimEdge.end,
                  pixelsPerSecond: pixelsPerSecond,
                  anchor: clip.timelineEnd,
                  onTrim: (pos) => onTrim!(TrimEdge.end, pos),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Draggable edge handle for trimming the selected clip.
class _TrimHandle extends StatefulWidget {
  const _TrimHandle({
    required this.edge,
    required this.pixelsPerSecond,
    required this.anchor,
    required this.onTrim,
  });

  final TrimEdge edge;
  final double pixelsPerSecond;
  final Duration anchor;
  final ValueChanged<Duration> onTrim;

  @override
  State<_TrimHandle> createState() => _TrimHandleState();
}

class _TrimHandleState extends State<_TrimHandle> {
  double _dx = 0;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.edge == TrimEdge.start ? 0 : null,
      right: widget.edge == TrimEdge.end ? 0 : null,
      top: 0,
      bottom: 0,
      width: 14,
      child: GestureDetector(
        onHorizontalDragStart: (_) => _dx = 0,
        onHorizontalDragUpdate: (d) {
          _dx += d.delta.dx;
          final shiftedMs =
              (_dx / widget.pixelsPerSecond * 1000).round();
          widget.onTrim(widget.anchor + Duration(milliseconds: shiftedMs));
        },
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.35),
            borderRadius: BorderRadius.horizontal(
              left: widget.edge == TrimEdge.start
                  ? const Radius.circular(4)
                  : Radius.zero,
              right: widget.edge == TrimEdge.end
                  ? const Radius.circular(4)
                  : Radius.zero,
            ),
          ),
          child: const Center(
            child: Icon(Icons.drag_indicator, size: 12, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Lane showing text overlays as blocks. Tapping one opens edit/delete.
class _OverlayLane extends StatelessWidget {
  const _OverlayLane({
    required this.overlays,
    required this.pixelsPerSecond,
    this.onOverlayTap,
  });

  final List<TextOverlay> overlays;
  final double pixelsPerSecond;
  final ValueChanged<TextOverlay>? onOverlayTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Stack(
        children: [
          for (final overlay in overlays)
            Positioned(
              left: overlay.start.inMilliseconds / 1000 * pixelsPerSecond,
              width: (overlay.end - overlay.start).inMilliseconds /
                  1000 *
                  pixelsPerSecond,
              top: 4,
              bottom: 4,
              child: GestureDetector(
                onTap: () => onOverlayTap?.call(overlay),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade700,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    overlay.text,
                    style:
                        const TextStyle(color: Colors.black, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Lane showing background audio tracks as blocks. Tapping one opens
/// volume/delete options.
class _AudioLane extends StatelessWidget {
  const _AudioLane({
    required this.tracks,
    required this.pixelsPerSecond,
    this.onAudioTap,
  });

  final List<AudioTrack> tracks;
  final double pixelsPerSecond;
  final ValueChanged<AudioTrack>? onAudioTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Stack(
        children: [
          for (final track in tracks)
            Positioned(
              left: track.timelineStart.inMilliseconds / 1000 * pixelsPerSecond,
              width: (track.timelineEnd - track.timelineStart).inMilliseconds /
                  1000 *
                  pixelsPerSecond,
              top: 4,
              bottom: 4,
              child: GestureDetector(
                onTap: () => onAudioTap?.call(track),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  decoration: BoxDecoration(
                    color: Colors.green.shade700,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.music_note,
                          size: 12, color: Colors.black),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Text(
                          track.name,
                          style: const TextStyle(
                              color: Colors.black, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Lane showing sticker overlays as blocks. Tapping one opens edit/delete.
class _StickerLane extends StatelessWidget {
  const _StickerLane({
    required this.stickers,
    required this.pixelsPerSecond,
    this.onStickerTap,
  });

  final List<StickerOverlay> stickers;
  final double pixelsPerSecond;
  final ValueChanged<StickerOverlay>? onStickerTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Stack(
        children: [
          for (final sticker in stickers)
            Positioned(
              left: sticker.start.inMilliseconds / 1000 * pixelsPerSecond,
              width: (sticker.end - sticker.start).inMilliseconds /
                  1000 *
                  pixelsPerSecond,
              top: 4,
              bottom: 4,
              child: GestureDetector(
                onTap: () => onStickerTap?.call(sticker),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  decoration: BoxDecoration(
                    color: Colors.purple.shade300,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    '🖼 ${sticker.name}',
                    style:
                        const TextStyle(color: Colors.black, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyTimelineHint extends StatelessWidget {
  const _EmptyTimelineHint();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 120,
      child: Center(
        child: Text(
          'Timeline kosong — tambahkan klip untuk mulai mengedit',
          style: TextStyle(color: Colors.grey),
        ),
      ),
    );
  }
}
