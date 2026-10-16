// Conditional factory: builds a VideoPlayerController for a picked video
// without importing dart:io on web.

import 'package:video_player/video_player.dart';

import 'player_controller_factory_stub.dart'
    if (dart.library.io) 'player_controller_factory_io.dart'
    if (dart.library.html) 'player_controller_factory_web.dart';

/// Creates a controller for [path] (file path on mobile, blob URL on web).
VideoPlayerController createPlayerController(String path) =>
    createController(path);
