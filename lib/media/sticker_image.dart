// Renders a picked image (file path on mobile, blob URL on web)
// without importing dart:io on web.

import 'package:flutter/widgets.dart';

import 'sticker_image_stub.dart'
    if (dart.library.io) 'sticker_image_io.dart'
    if (dart.library.html) 'sticker_image_web.dart';

/// Builds an [Image] widget for a picked sticker [path].
Widget buildStickerImage(String path) => createStickerImage(path);
