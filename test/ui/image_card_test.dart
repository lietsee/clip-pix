import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clip_pix/data/models/image_item.dart';
import 'package:clip_pix/system/state/grid_layout_store.dart';
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

    final recordedSpans = <int>[];
    var viewState = GridCardViewState(
      id: '1',
      width: _spanWidth(2, columnWidth, columnGap),
      height: 220,
      scale: 1.0,
      columnSpan: 2,
      customHeight: 220,
    );
    late StateSetter setState;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, innerSetState) {
              setState = innerSetState;
              return Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 600,
                  child: ImageCard(
                    item: ImageItem(id: '1', filePath: imageFile.path),
                    viewState: viewState,
                    onResize: (_, __) {},
                    onSpanChange: (_, span) => recordedSpans.add(span),
                    onZoom: (_, __) {},
                    onPan: (_, __) {},
                    onRetry: (_) {},
                    onOpenPreview: (_) {},
                    onCopyImage: (_) {},
                    onEditMemo: (_, __) {},
                    onFavoriteToggle: (_, __) {},
                    columnWidth: columnWidth,
                    columnCount: columnCount,
                    columnGap: columnGap,
                    backgroundColor: const Color(0xFFB0B0B0),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.pump();

    setState(() {
      viewState = GridCardViewState(
        id: '1',
        width: _spanWidth(3, columnWidth, columnGap),
        height: 260,
        scale: 1.0,
        columnSpan: 3,
        customHeight: 260,
      );
    });

    await tester.pump();

    expect(recordedSpans, isEmpty);
  });

  testWidgets('ImageCard suppresses scroll while zooming', (tester) async {
    final scrollController = ScrollController();
    const columnWidth = 150.0;
    const columnGap = 3.0;
    const columnCount = 4;

    addTearDown(() {
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
                viewState: GridCardViewState(
                  id: '1',
                  width: 200,
                  height: 220,
                  scale: 1.0,
                  columnSpan: 1,
                  customHeight: 220,
                ),
                onResize: (_, __) {},
                onSpanChange: (_, __) {},
                onZoom: (_, __) {},
                onPan: (_, __) {},
                onRetry: (_) {},
                onOpenPreview: (_) {},
                onCopyImage: (_) {},
                onEditMemo: (_, __) {},
                onFavoriteToggle: (_, __) {},
                columnWidth: columnWidth,
                columnCount: columnCount,
                columnGap: columnGap,
                backgroundColor: const Color(0xFFB0B0B0),
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

    await tester.pump(const Duration(milliseconds: 200));

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

      final maxDx = (size.width * (2.0 - 1)) / 2; // 150
      final maxDy = (size.height * (2.0 - 1)) / 2; // 90

      expect(result.dx, closeTo(-maxDx, 0.001));
      expect(result.dy, closeTo(-maxDy, 0.001));
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
