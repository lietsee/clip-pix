import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clip_pix/data/models/image_item.dart';
import 'package:clip_pix/ui/image_card.dart';

double _spanWidth(int span, double columnWidth, double gap) =>
    columnWidth * span + gap * (span - 1);

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

  testWidgets('ImageCard snaps width to nearest column span', (tester) async {
    const columnWidth = 120.0;
    const columnGap = 3.0;
    const columnCount = 4;

    final sizeNotifier = ValueNotifier(
      Size(_spanWidth(2, columnWidth, columnGap), 220),
    );
    final scaleNotifier = ValueNotifier(1.0);
    final recordedSpans = <int>[];

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
              width: 600,
              child: ImageCard(
                item: ImageItem(id: '1', filePath: imageFile.path),
                sizeNotifier: sizeNotifier,
                scaleNotifier: scaleNotifier,
                onResize: (_, __) {},
                onSpanChange: (_, span) => recordedSpans.add(span),
                onZoom: (_, __) {},
                onRetry: (_) {},
                onOpenPreview: (_) {},
                onCopyImage: (_) {},
                columnWidth: columnWidth,
                columnCount: columnCount,
                columnGap: columnGap,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(
      sizeNotifier.value.width,
      closeTo(_spanWidth(2, columnWidth, columnGap), 0.5),
    );

    sizeNotifier.value = Size(
      _spanWidth(3, columnWidth, columnGap),
      260,
    );
    await tester.pump();

    expect(
      sizeNotifier.value.width,
      closeTo(_spanWidth(3, columnWidth, columnGap), 0.5),
    );
    expect(recordedSpans.contains(3), isFalse);
  });

  testWidgets('ImageCard suppresses scroll while zooming', (tester) async {
    final sizeNotifier = ValueNotifier(const Size(200, 220));
    final scaleNotifier = ValueNotifier(1.0);
    final scrollController = ScrollController();
    const columnWidth = 150.0;
    const columnGap = 3.0;
    const columnCount = 4;

    addTearDown(() {
      sizeNotifier.dispose();
      scaleNotifier.dispose();
      scrollController.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scrollController,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 400),
              child: ImageCard(
                item: ImageItem(id: '1', filePath: imageFile.path),
                sizeNotifier: sizeNotifier,
                scaleNotifier: scaleNotifier,
                onResize: (_, __) {},
                onSpanChange: (_, __) {},
                onZoom: (_, __) {},
                onRetry: (_) {},
                onOpenPreview: (_) {},
                onCopyImage: (_) {},
                columnWidth: columnWidth,
                columnCount: columnCount,
                columnGap: columnGap,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    final center = tester.getCenter(find.byType(ImageCard));

    await tester.sendEventToBinding(
      PointerDownEvent(
        pointer: 1,
        position: center,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      ),
    );

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: center,
        kind: PointerDeviceKind.mouse,
        scrollDelta: const Offset(0, -40),
      ),
    );

    await tester.pump();

    expect(scrollController.offset, closeTo(0, 0.01));

    await tester.sendEventToBinding(
      const PointerUpEvent(
        pointer: 1,
        kind: PointerDeviceKind.mouse,
      ),
    );
  });

  group('clampPanOffset', () {
    test('returns zero when scale is <= 1', () {
      const offset = Offset(50, -30);
      const size = Size(200, 220);

      final result = clampPanOffset(offset: offset, size: size, scale: 1.0);

      expect(result, Offset.zero);
    });

    test('clamps offset within horizontal and vertical bounds', () {
      const size = Size(300, 180);
      final result = clampPanOffset(
        offset: const Offset(-500, -400),
        size: size,
        scale: 2.0,
      );

      final minDx = size.width - size.width * 2.0; // -300
      final minDy = size.height - size.height * 2.0; // -180

      expect(result.dx, closeTo(minDx, 0.001));
      expect(result.dy, closeTo(minDy, 0.001));
    });

    test('handles non-finite scale gracefully', () {
      const size = Size(200, 200);
      final result = clampPanOffset(
        offset: const Offset(-20, -20),
        size: size,
        scale: double.nan,
      );

      expect(result, Offset.zero);
    });
  });
}
