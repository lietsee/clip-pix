import 'dart:convert';
import 'dart:io';

import 'package:clip_pix/data/models/grid_card_pref.dart';
import 'package:clip_pix/data/models/grid_layout_settings.dart';
import 'package:clip_pix/data/models/image_item.dart';
import 'package:clip_pix/system/clipboard_monitor.dart';
import 'package:clip_pix/system/clipboard_copy_service.dart';
import 'package:clip_pix/system/state/grid_layout_mutation_controller.dart';
import 'package:clip_pix/system/state/grid_resize_controller.dart';
import 'package:clip_pix/system/state/grid_layout_store.dart';
import 'package:clip_pix/system/state/grid_resize_store_binding.dart';
import 'package:clip_pix/system/state/image_library_notifier.dart';
import 'package:clip_pix/system/state/image_library_state.dart';
import 'package:clip_pix/system/state/selected_folder_state.dart';
import 'package:clip_pix/ui/grid_view_module.dart';
import 'package:clip_pix/ui/image_card.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:clip_pix/data/grid_card_preferences_repository.dart';
import 'package:clip_pix/data/grid_layout_settings_repository.dart';
import 'package:clip_pix/data/grid_order_repository.dart';
import 'package:clip_pix/data/image_repository.dart';
import 'package:clip_pix/system/state/folder_view_mode.dart';

class InMemoryGridCardPreferencesRepository
    implements GridCardPreferencesRepository {
  final Map<String, GridCardPreference> _storage =
      <String, GridCardPreference>{};

  @override
  GridCardPreference? get(String id) => _storage[id];

  @override
  GridCardPreference getOrCreate(String id) {
    return _storage.putIfAbsent(
      id,
      () => GridCardPreference(
        id: id,
        width: GridCardPreferencesRepository.defaultWidth,
        height: GridCardPreferencesRepository.defaultHeight,
        scale: GridCardPreferencesRepository.defaultScale,
        columnSpan: GridCardPreferencesRepository.defaultColumnSpan,
        customHeight: null,
      ),
    );
  }

  @override
  Future<void> saveSize(String id, Size size) async {
    final current = getOrCreate(id);
    _storage[id] = current.copyWith(
      width: size.width,
      height: size.height,
      customHeight: size.height,
      overrideCustomHeight: true,
    );
  }

  @override
  Future<void> saveScale(String id, double scale) async {
    final current = getOrCreate(id);
    _storage[id] = current.copyWith(scale: scale);
  }

  @override
  Future<void> saveColumnSpan(String id, int span) async {
    final current = getOrCreate(id);
    _storage[id] = current.copyWith(columnSpan: span);
  }

  @override
  Future<void> saveCustomHeight(String id, double? height) async {
    final current = getOrCreate(id);
    _storage[id] = current.copyWith(
      customHeight: height,
      overrideCustomHeight: true,
    );
  }

  @override
  Future<void> savePreference(GridCardPreference preference) async {
    _storage[preference.id] = preference;
  }

  @override
  Future<void> saveAll(Iterable<GridCardPreference> preferences) async {
    for (final preference in preferences) {
      _storage[preference.id] = preference;
    }
  }

  @override
  Future<void> clear() async {
    _storage.clear();
  }

  @override
  Future<void> remove(String id) async {
    _storage.remove(id);
  }
}

class _TestGridLayoutPersistence implements GridLayoutPersistence {
  _TestGridLayoutPersistence(this._repository);

  final GridCardPreferencesRepository _repository;

  @override
  GridLayoutPreferenceRecord read(String id) {
    final pref = _repository.getOrCreate(id);
    return GridLayoutPreferenceRecord(
      id: pref.id,
      width: pref.width,
      height: pref.height,
      scale: pref.scale,
      columnSpan: pref.columnSpan,
      customHeight: pref.customHeight,
    );
  }

  @override
  Future<void> saveBatch(List<GridLayoutPreferenceRecord> mutations) async {
    for (final mutation in mutations) {
      await _repository.savePreference(
        GridCardPreference(
          id: mutation.id,
          width: mutation.width,
          height: mutation.height,
          scale: mutation.scale,
          columnSpan: mutation.columnSpan,
          customHeight: mutation.customHeight,
        ),
      );
    }
  }
}

class _TestRatioResolver implements GridIntrinsicRatioResolver {
  @override
  Future<double?> resolve(String id, ImageItem? item) async => 1.0;
}

class TestGridLayoutSettingsRepository extends ChangeNotifier
    implements GridLayoutSettingsRepository {
  TestGridLayoutSettingsRepository(this._value);

  GridLayoutSettings _value;

  @override
  GridLayoutSettings get value => _value;

  @override
  Future<void> update(GridLayoutSettings settings) async {
    _value = settings;
    notifyListeners();
  }
}

class TestGridOrderRepository extends ChangeNotifier
    implements GridOrderRepository {
  final Map<String, List<String>> _orders = <String, List<String>>{};

  @override
  List<String> getOrder(String path) {
    return List<String>.from(_orders[path] ?? const <String>[]);
  }

  @override
  List<String> sync(String path, List<String> currentIds) {
    final cleaned = List<String>.from(currentIds);
    _orders[path] = cleaned;
    return cleaned;
  }

  @override
  Future<void> save(String path, List<String> order) async {
    _orders[path] = List<String>.from(order);
    notifyListeners();
  }

  @override
  Future<void> remove(String path) async {
    _orders.remove(path);
    notifyListeners();
  }
}

class TestClipboardCopyService implements ClipboardCopyService {
  @override
  Future<void> copyImage(ImageItem item) async {}

  @override
  void registerMonitor(ClipboardMonitorGuard guard) {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestImageLibraryNotifier extends ImageLibraryNotifier {
  TestImageLibraryNotifier() : super(ImageRepository());

  void seed(ImageLibraryState state) {
    this.state = state;
  }

  @override
  Future<void> refresh() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File imageFile;
  late InMemoryGridCardPreferencesRepository preferences;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('grid_view_module_test');
    imageFile = File('${tempDir.path}/sample.png');
    const pixel =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQImWNgYGBgAAAABQABDQottAAAAABJRU5ErkJggg==';
    await imageFile.writeAsBytes(base64Decode(pixel));
    preferences = InMemoryGridCardPreferencesRepository();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('resizing card does not trigger parent data errors',
      (tester) async {
    final layoutRepo = TestGridLayoutSettingsRepository(
      GridLayoutSettings(
        preferredColumns: 3,
        maxColumns: 3,
        background: GridBackgroundTone.white,
        bulkSpan: 1,
      ),
    );
    final orderRepo = TestGridOrderRepository();
    final clipboardService = TestClipboardCopyService();
    final resizeController = GridResizeController();
    final layoutStore = GridLayoutStore(
      persistence: _TestGridLayoutPersistence(preferences),
      ratioResolver: _TestRatioResolver(),
    );
    addTearDown(layoutStore.dispose);
    final mutationController = GridLayoutMutationController();
    addTearDown(mutationController.dispose);
    final storeBinding = GridResizeStoreBinding(
      controller: resizeController,
      store: layoutStore,
      mutationController: mutationController,
    );
    addTearDown(storeBinding.dispose);
    final imageNotifier = TestImageLibraryNotifier();
    imageNotifier.seed(
      ImageLibraryState(
        activeDirectory: tempDir,
        images: <ImageItem>[
          ImageItem(id: 'item1', filePath: imageFile.path),
        ],
        isLoading: false,
        error: null,
      ),
    );

    final selectedState = SelectedFolderState(
      current: tempDir,
      history: const <Directory>[],
      viewMode: FolderViewMode.root,
      currentTab: null,
      rootScrollOffset: 0,
      isValid: true,
      viewDirectory: tempDir,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            Provider<GridCardPreferencesRepository>.value(value: preferences),
            ChangeNotifierProvider<GridLayoutSettingsRepository>.value(
              value: layoutRepo,
            ),
            ChangeNotifierProvider<GridOrderRepository>.value(
              value: orderRepo,
            ),
            ChangeNotifierProvider<GridLayoutStore>.value(
              value: layoutStore,
            ),
            ChangeNotifierProvider<GridLayoutMutationController>.value(
              value: mutationController,
            ),
            Provider<ClipboardCopyService>.value(value: clipboardService),
            ChangeNotifierProvider<GridResizeController>.value(
              value: resizeController,
            ),
            Provider<GridResizeStoreBinding>.value(value: storeBinding),
            Provider<ImageLibraryNotifier>.value(value: imageNotifier),
            Provider<SelectedFolderState>.value(value: selectedState),
          ],
          child: Scaffold(
            body: SizedBox(
              width: 900,
              height: 600,
              child: GridViewModule(
                state: imageNotifier.state,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);

    final cardFinder = find.byType(ImageCard);
    final cardRect = tester.getRect(cardFinder);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(cardRect.center);
    await tester.pump(const Duration(milliseconds: 150));

    final handlePosition = cardRect.bottomRight - const Offset(12, 12);
    final gestureDrag = await tester.startGesture(
      handlePosition,
      kind: PointerDeviceKind.mouse,
    );
    await gestureDrag.moveBy(const Offset(260, 140));
    await gestureDrag.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);

    final pref = preferences.getOrCreate('item1');
    expect(pref.columnSpan, greaterThanOrEqualTo(2));
  });
}
