// Bundled typeface for drawtext overlays during export.
//
// ffmpeg-kit ships fontconfig/freetype but mobile OSes have no configured
// system fonts, so drawtext needs an explicit fontfile. This copies the
// bundled DejaVu Sans (permissive Bitstream Vera license) to a temp file
// on first use and returns its path.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Returns a filesystem path to a TTF usable as drawtext's fontfile.
/// Returns null on platforms where this is unnecessary/unsupported (web).
Future<String?> ensureExportFont() async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/ove_DejaVuSans.ttf');
  if (!await file.exists()) {
    final data = await rootBundle.load('assets/fonts/DejaVuSans.ttf');
    await file.writeAsBytes(data.buffer.asUint8List());
  }
  return file.path;
}
