// Fallback for platforms with neither dart:io nor dart:html.

import 'package:video_player/video_player.dart';

VideoPlayerController createController(String path) =>
    throw UnsupportedError('Video preview is not supported on this platform');
