import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clip_pix/data/models/image_item.dart';
import 'package:clip_pix/ui/image_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File imageFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('image_card_test');
    imageFile = File('${tempDir.path}/sample.png');
    const pixel =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQImWNgYGBgAAAABQABDQottAAAAABJRU5ErkJggg==';
    await imageFile.writeAsBytes(base64Decode(pixel));
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('ImageCard clamps and applies horizontal resize', (tester) async {
    final sizeNotifier = ValueNotifier(const Size(200, 220));
    final scaleNotifier = ValueNotifier(1.0);

    addTearDown(() {
      sizeNotifier.dispose();
      scaleNotifier.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              child: ImageCard(
                item: ImageItem(id: '1', filePath: imageFile.path),
                sizeNotifier: sizeNotifier,
                scaleNotifier: scaleNotifier,
                onResize: (_, __) {},
                onZoom: (_, __) {},
                onRetry: (_) {},
                onOpenPreview: (_) {},
                onCopyImage: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    Size cardSize() => tester.getSize(find.byType(Card));

    expect(cardSize().width, closeTo(200, 0.5));

    sizeNotifier.value = const Size(140, 220);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(cardSize().width, closeTo(140, 0.5));

    sizeNotifier.value = const Size(500, 220);
    await tester.pump();
    await tester.pump();

    expect(cardSize().width, closeTo(360, 0.5));
    expect(sizeNotifier.value.width, closeTo(360, 0.5));
  });
}
