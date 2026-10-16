// Builds an audioplayers [Source] from a picked path
// (file path on mobile, blob URL on web).

import 'package:audioplayers/audioplayers.dart';

Source audioSourceForPath(String path) =>
    path.startsWith('blob:') ? UrlSource(path) : DeviceFileSource(path);
