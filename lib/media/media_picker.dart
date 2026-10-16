// System media picking, wrapped so the UI never touches the plugin directly.

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

/// A video chosen by the user.
class PickedVideo {
  const PickedVideo({required this.path, required this.name});

  /// File path on mobile, blob URL on web.
  final String path;
  final String name;
}

/// An audio file chosen by the user.
class PickedAudio {
  const PickedAudio({required this.path, required this.name});

  /// File path on mobile, blob URL on web.
  final String path;
  final String name;
}

/// An image chosen by the user (for stickers).
class PickedImage {
  const PickedImage({required this.path, required this.name});

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

  /// Opens the system gallery to pick an image (used for stickers).
  /// Returns null when the user cancels.
  Future<PickedImage?> pickImage() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return null;
    return PickedImage(path: file.path, name: file.name);
  }

  /// Opens a file picker for audio files.
  /// Returns null when the user cancels.
  Future<PickedAudio?> pickAudio() async {
    final file = await FilePicker.pickFile(type: FileType.audio);
    if (file == null) return null;
    // On web file.uri is a blob URL; on mobile file.path is a local path.
    final path = file.path ?? file.uri.toString();
    return PickedAudio(path: path, name: file.name);
  }
}
