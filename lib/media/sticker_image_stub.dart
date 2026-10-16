import 'package:flutter/widgets.dart';

/// Fallback for platforms with neither dart:io nor dart:html.
Widget createStickerImage(String path) =>
    throw UnsupportedError('Sticker images not supported on this platform');
