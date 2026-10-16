import 'package:video_player/video_player.dart';

VideoPlayerController createController(String path) =>
    VideoPlayerController.networkUrl(Uri.parse(path));
