import 'package:flutter/material.dart';

class ImagePreviewWindow extends StatelessWidget {
  const ImagePreviewWindow({
    super.key,
    required this.imagePath,
    this.alwaysOnTop = false,
  });

  final String imagePath;
  final bool alwaysOnTop;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(imagePath),
      ),
      body: Center(
        child: Text('Preview for $imagePath (alwaysOnTop=$alwaysOnTop)'),
      ),
    );
  }
}
