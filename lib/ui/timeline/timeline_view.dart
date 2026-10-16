// Timeline UI: renders project tracks as horizontal lanes with clip blocks
// and a draggable playhead. Pure Flutter — no engine dependency.

import 'package:flutter/material.dart';

import '../../engine/video_engine.dart';

/// Horizontal multi-track timeline view.
///
/// Calls [onSeek] when the user taps/drags on the ruler area.
class TimelineView extends StatefulWidget {
  const TimelineView({
    super.key,
    required this.project,
    required this.position,
    this.onSeek,
    this.pixelsPerSecond = 24.0,
  });

  final TimelineProject project;
  final Duration position;
  final ValueChanged<Duration>? onSeek;
  final double pixelsPerSecond;

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView> {
  void _seekAt(Offset local, double maxWidth) {
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
      onTapDown: (d) => _seekAt(d.localPosition, width),
      onHorizontalDragUpdate: (d) => _seekAt(d.localPosition, width),
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
                    ),
                  if (widget.project.tracks.isEmpty)
                    const _EmptyTimelineHint(),
                ],
              ),
              // Playhead
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
  const _TrackLane({required this.track, required this.pixelsPerSecond});

  final VideoTrack track;
  final double pixelsPerSecond;

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
            Positioned(
              left: clip.timelineStart.inMilliseconds / 1000 * pixelsPerSecond,
              width: clip.duration.inMilliseconds / 1000 * pixelsPerSecond,
              top: 4,
              bottom: 4,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: Colors.indigo.shade400,
                  borderRadius: BorderRadius.circular(4),
                ),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  clip.source.id,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
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
