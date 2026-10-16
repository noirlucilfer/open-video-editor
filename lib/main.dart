import 'package:flutter/material.dart';

import 'ui/editor_screen.dart';

void main() {
  runApp(const OpenVideoEditorApp());
}

class OpenVideoEditorApp extends StatelessWidget {
  const OpenVideoEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Open Video Editor',
      theme: ThemeData.dark(useMaterial3: true),
      home: const EditorScreen(),
    );
  }
}
