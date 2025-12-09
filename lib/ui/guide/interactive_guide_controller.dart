import 'package:flutter/foundation.dart';

/// ガイドのフェーズ
enum GuidePhase {
  /// ガイド未開始
  notStarted,

  /// フォルダ選択待ち
  folderSelection,

  /// クリップボード監視ON待ち
  clipboardToggle,

  /// サンプル画像コピー待ち
  sampleImageCopy,

  /// 画像保存確認
  imageSaveConfirm,

  /// カードリサイズ体験
  cardResize,

  /// カードズーム体験
  cardZoom,

  /// カードパン体験
  cardPan,

  /// カードプレビュー体験
  cardPreview,

  /// ShowCaseView UIガイド
  uiShowcase,

  /// ガイド完了
  completed,
}

/// インタラクティブガイドのステップ情報
class InteractiveGuideStep {
  const InteractiveGuideStep({
    required this.phase,
    required this.title,
    required this.description,
    this.actionLabel,
  });

  final GuidePhase phase;
  final String title;
  final String description;
  final String? actionLabel;
}

/// インタラクティブガイドのステップ定義
const List<InteractiveGuideStep> interactiveGuideSteps = [
  InteractiveGuideStep(
    phase: GuidePhase.folderSelection,
    title: 'フォルダを選択',
    description: '画像を保存するフォルダを選択してください。\n右上のフォルダボタンまたは中央のボタンをクリック！',
    actionLabel: 'フォルダ選択',
  ),
  InteractiveGuideStep(
    phase: GuidePhase.clipboardToggle,
    title: 'クリップボード監視をON',
    description: 'クリップボード監視をONにすると、\n画像コピー時に自動で保存されます。',
    actionLabel: '監視ON',
  ),
  InteractiveGuideStep(
    phase: GuidePhase.sampleImageCopy,
    title: '画像をコピーしてみよう',
    description: '表示された画像をコピーしてください。\nCmd+C または右クリック→コピー',
    actionLabel: 'コピー',
  ),
  InteractiveGuideStep(
    phase: GuidePhase.imageSaveConfirm,
    title: '保存完了！',
    description: '画像が自動で保存されました！\nこれがClipPixの基本機能です。',
    actionLabel: '次へ',
  ),
  InteractiveGuideStep(
    phase: GuidePhase.cardResize,
    title: 'カードをリサイズ',
    description: 'カードの角をドラッグして\nサイズを変更してみましょう。',
  ),
  InteractiveGuideStep(
    phase: GuidePhase.cardZoom,
    title: 'ズームしてみよう',
    description: 'カード上で右クリック＋マウスホイールで\n拡大・縮小できます。',
  ),
  InteractiveGuideStep(
    phase: GuidePhase.cardPan,
    title: '画像を移動',
    description: 'ズーム中に右クリック＋ドラッグで\n画像の表示位置を移動できます。',
  ),
  InteractiveGuideStep(
    phase: GuidePhase.cardPreview,
    title: 'プレビュー表示',
    description: 'カードをダブルクリックすると\n大きなプレビューが開きます。',
  ),
  InteractiveGuideStep(
    phase: GuidePhase.completed,
    title: 'ガイド完了！',
    description: 'これでClipPixの基本操作は完了です。\n自由に画像を管理してください！',
    actionLabel: '完了',
  ),
];

/// インタラクティブガイドのコントローラー
class InteractiveGuideController extends ChangeNotifier {
  GuidePhase _phase = GuidePhase.notStarted;
  bool _isSkipped = false;

  /// 現在のフェーズ
  GuidePhase get phase => _phase;

  /// ガイドがスキップされたか
  bool get isSkipped => _isSkipped;

  /// ガイドがアクティブか（notStartedとcompleted以外）
  bool get isActive =>
      _phase != GuidePhase.notStarted && _phase != GuidePhase.completed;

  /// インタラクティブフェーズか（uiShowcase以前）
  bool get isInteractivePhase =>
      _phase.index > GuidePhase.notStarted.index &&
      _phase.index < GuidePhase.uiShowcase.index;

  /// ガイドカードを表示すべきか（インタラクティブフェーズまたはcompleted）
  bool get shouldShowGuideCard =>
      isInteractivePhase || _phase == GuidePhase.completed;

  /// 現在のステップ番号（1-indexed、インタラクティブフェーズのみ）
  int get currentStepNumber {
    if (!isInteractivePhase) return 0;
    return _phase.index; // folderSelection=1, clipboardToggle=2, etc.
  }

  /// インタラクティブステップの総数
  int get totalInteractiveSteps => interactiveGuideSteps.length;

  /// 現在のステップ情報
  InteractiveGuideStep? get currentStep {
    // completedフェーズ専用処理
    if (_phase == GuidePhase.completed) {
      return interactiveGuideSteps.last;
    }
    if (!isInteractivePhase) return null;
    final index = _phase.index - 1; // GuidePhase.folderSelection.index == 1
    if (index < 0 || index >= interactiveGuideSteps.length) return null;
    return interactiveGuideSteps[index];
  }

  /// ガイドを開始
  /// [hasFolderSelected] フォルダが既に選択されているか
  /// [isClipboardRunning] クリップボード監視が既にONか
  void start({
    required bool hasFolderSelected,
    required bool isClipboardRunning,
  }) {
    if (_phase != GuidePhase.notStarted) return;
    _isSkipped = false;

    // 条件に応じて開始フェーズを決定
    if (!hasFolderSelected) {
      _phase = GuidePhase.folderSelection;
    } else if (!isClipboardRunning) {
      _phase = GuidePhase.clipboardToggle;
    } else {
      // 両方満たしている → サンプル画像コピーから
      _phase = GuidePhase.sampleImageCopy;
    }

    notifyListeners();
    debugPrint('[InteractiveGuide] Started, phase: $_phase (folder=$hasFolderSelected, clipboard=$isClipboardRunning)');
  }

  /// フォルダ選択完了時に呼び出す
  void onFolderSelected() {
    if (_phase != GuidePhase.folderSelection) return;
    _phase = GuidePhase.clipboardToggle;
    notifyListeners();
    debugPrint('[InteractiveGuide] Folder selected, phase: $_phase');
  }

  /// クリップボード監視ON時に呼び出す
  void onClipboardEnabled() {
    if (_phase != GuidePhase.clipboardToggle) return;
    _phase = GuidePhase.sampleImageCopy;
    notifyListeners();
    debugPrint('[InteractiveGuide] Clipboard enabled, phase: $_phase');
  }

  /// 画像保存完了時に呼び出す
  void onImageSaved() {
    if (_phase != GuidePhase.sampleImageCopy) return;
    _phase = GuidePhase.imageSaveConfirm;
    notifyListeners();
    debugPrint('[InteractiveGuide] Image saved, phase: $_phase');
  }

  /// 保存確認後、UIショーケースへ進む
  void proceedToShowcase() {
    if (_phase != GuidePhase.imageSaveConfirm) return;
    _phase = GuidePhase.uiShowcase;
    notifyListeners();
    debugPrint('[InteractiveGuide] Proceeding to UI showcase, phase: $_phase');
  }

  /// カードリサイズ完了時に呼び出す
  void onCardResized() {
    if (_phase != GuidePhase.cardResize) return;
    _phase = GuidePhase.cardZoom;
    notifyListeners();
    debugPrint('[InteractiveGuide] Card resized, phase: $_phase');
  }

  /// カードズーム完了時に呼び出す
  void onCardZoomed() {
    if (_phase != GuidePhase.cardZoom) return;
    _phase = GuidePhase.cardPan;
    notifyListeners();
    debugPrint('[InteractiveGuide] Card zoomed, phase: $_phase');
  }

  /// カードパン完了時に呼び出す
  void onCardPanned() {
    if (_phase != GuidePhase.cardPan) return;
    _phase = GuidePhase.cardPreview;
    notifyListeners();
    debugPrint('[InteractiveGuide] Card panned, phase: $_phase');
  }

  /// プレビュー表示時に呼び出す
  void onPreviewOpened() {
    if (_phase != GuidePhase.cardPreview) return;
    _phase = GuidePhase.completed;
    notifyListeners();
    debugPrint('[InteractiveGuide] Preview opened, guide completed');
  }

  /// UIショーケース完了時に呼び出す（カード操作ガイドへ進む）
  void onShowcaseComplete() {
    if (_phase != GuidePhase.uiShowcase) return;
    _phase = GuidePhase.cardResize;
    notifyListeners();
    debugPrint('[InteractiveGuide] Showcase complete, proceeding to card operations, phase: $_phase');
  }

  /// ガイドをスキップ
  void skip() {
    _phase = GuidePhase.completed;
    _isSkipped = true;
    notifyListeners();
    debugPrint('[InteractiveGuide] Guide skipped');
  }

  /// ガイド完了を確認してリセット
  void confirmComplete() {
    if (_phase != GuidePhase.completed) return;
    reset();
    debugPrint('[InteractiveGuide] Guide confirmed complete');
  }

  /// ガイドをリセット
  void reset() {
    _phase = GuidePhase.notStarted;
    _isSkipped = false;
    notifyListeners();
    debugPrint('[InteractiveGuide] Guide reset');
  }
}
