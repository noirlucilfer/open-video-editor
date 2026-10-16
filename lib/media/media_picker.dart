// System media picking, wrapped so the UI never touches the plugin directly.

import 'package:image_picker/image_picker.dart';

/// A video chosen by the user.
class PickedVideo {
  const PickedVideo({required this.path, required this.name});

  /// File path on mobile, blob URL on web.
  final String path;
  final String name;
}

class MediaPicker {
  MediaPicker({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  /// Opens the system gallery to pick a video.
  /// Returns null when the user cancels.
  Future<PickedVideo?> pickVideo() async {
    final file = await _picker.pickVideo(source: ImageSource.gallery);
    if (file == null) return null;
    return PickedVideo(path: file.path, name: file.name);
  }
}
