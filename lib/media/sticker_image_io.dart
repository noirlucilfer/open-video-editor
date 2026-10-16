import 'dart:io';

import 'package:flutter/widgets.dart';

Widget createStickerImage(String path) => Image.file(File(path));
