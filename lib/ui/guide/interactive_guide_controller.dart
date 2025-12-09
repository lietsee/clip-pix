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

  /// 現在のステップ番号（1-indexed、インタラクティブフェーズのみ）
  int get currentStepNumber {
    if (!isInteractivePhase) return 0;
    return _phase.index; // folderSelection=1, clipboardToggle=2, etc.
  }

  /// インタラクティブステップの総数
  int get totalInteractiveSteps => interactiveGuideSteps.length;

  /// 現在のステップ情報
  InteractiveGuideStep? get currentStep {
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
    debugPrint('[InteractiveGuide] Proceeding to showcase, phase: $_phase');
  }

  /// UIショーケース完了時に呼び出す
  void onShowcaseComplete() {
    if (_phase != GuidePhase.uiShowcase) return;
    _phase = GuidePhase.completed;
    notifyListeners();
    debugPrint('[InteractiveGuide] Guide completed');
  }

  /// ガイドをスキップ
  void skip() {
    _phase = GuidePhase.completed;
    _isSkipped = true;
    notifyListeners();
    debugPrint('[InteractiveGuide] Guide skipped');
  }

  /// ガイドをリセット
  void reset() {
    _phase = GuidePhase.notStarted;
    _isSkipped = false;
    notifyListeners();
    debugPrint('[InteractiveGuide] Guide reset');
  }
}
