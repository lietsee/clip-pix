import 'dart:io';

import 'package:flutter/material.dart';

import '../data/models/image_item.dart';

class ImageCard extends StatelessWidget {
  const ImageCard({
    super.key,
    required this.item,
    this.onCopy,
    this.onOpenPreview,
  });

  final ImageItem item;
  final VoidCallback? onCopy;
  final VoidCallback? onOpenPreview;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpenPreview,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: Image.file(
                File(item.filePath),
                fit: BoxFit.cover,
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  color: Colors.white,
                  splashRadius: 20,
                  tooltip: 'コピー',
                  onPressed: onCopy,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(8),
                color: Colors.black45,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      File(item.filePath).uri.pathSegments.last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    if (item.source != null && item.source!.isNotEmpty)
                      Text(
                        item.source!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 10),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
