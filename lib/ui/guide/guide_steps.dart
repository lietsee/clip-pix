import 'package:flutter/material.dart';

/// ガイドステップの定義
class GuideStep {
  const GuideStep({
    required this.id,
    required this.title,
    required this.description,
  });

  /// ステップID（GlobalKeyとの対応用）
  final String id;

  /// タイトル
  final String title;

  /// 説明文
  final String description;
}

/// 初回ガイドのステップ定義
const List<GuideStep> firstGuideSteps = [
  GuideStep(
    id: 'folder_btn',
    title: 'フォルダ選択',
    description: '画像を保存するフォルダを選択・変更できます。\nサブフォルダも自動で認識されます。',
  ),
  GuideStep(
    id: 'clipboard_toggle',
    title: 'クリップボード監視',
    description: 'ONにすると画像コピー時に自動保存します。\n画像のURLをコピーしても自動ダウンロード！',
  ),
  GuideStep(
    id: 'new_text_btn',
    title: '新規テキスト',
    description: 'テキストカードを新規作成します。\nメモや説明を追加できます。',
  ),
  GuideStep(
    id: 'minimap_btn',
    title: 'ミニマップ',
    description: 'グリッド全体を俯瞰できます。\nCtrl+Mでも切り替え可能。',
  ),
  GuideStep(
    id: 'settings_btn',
    title: '設定',
    description: '列数、背景色、効果音などを\nカスタマイズできます。',
  ),
  GuideStep(
    id: 'grid_area',
    title: 'グリッドエリア',
    description: 'ここにフォルダに保存されたカードが表示されます。\n• カードの角をドラッグでリサイズ\n• マウスホイールでズーム\n• ダブルクリックでプレビュー',
  ),
];

/// ガイドのGlobalKeyを管理するクラス
class GuideKeys {
  GuideKeys._();

  static final Map<String, GlobalKey> _keys = {};

  /// ステップIDに対応するGlobalKeyを取得（なければ作成）
  static GlobalKey getKey(String id) {
    return _keys.putIfAbsent(id, () => GlobalKey());
  }

  /// 全てのキーをリセット
  static void reset() {
    _keys.clear();
  }

  /// ガイドに使用するキーのリストを取得
  static List<GlobalKey> getGuideKeyList() {
    return firstGuideSteps.map((step) => getKey(step.id)).toList();
  }
}

/// インタラクティブガイドのハイライト用GlobalKey
/// Showcaseのkeyとは別に、子ウィジェットに直接アタッチするキー
class InteractiveGuideKeys {
  InteractiveGuideKeys._();

  static final folderButton = GlobalKey(debugLabel: 'folderButton');
  static final centerFolderButton = GlobalKey(debugLabel: 'centerFolderButton');
  static final clipboardToggle = GlobalKey(debugLabel: 'clipboardToggle');
}
