import 'package:flutter/material.dart';

/// アニメーションタイプ
enum OnboardingAnimationType {
  /// フェードイン
  fadeIn,

  /// 下からスライドアップ
  slideUp,

  /// スケールイン（拡大）
  scaleIn,

  /// パルス（脈動）
  pulse,
}

/// オンボーディングスライドのデータモデル
class OnboardingSlideData {
  const OnboardingSlideData({
    required this.title,
    required this.description,
    required this.icon,
    this.iconColor,
    this.animationType = OnboardingAnimationType.fadeIn,
  });

  /// スライドタイトル
  final String title;

  /// スライド説明文
  final String description;

  /// 表示アイコン（プレースホルダー、後でLottieに差し替え可能）
  final IconData icon;

  /// アイコンの色（nullの場合はテーマカラー）
  final Color? iconColor;

  /// アニメーションタイプ
  final OnboardingAnimationType animationType;
}

/// オンボーディングスライドのコンテンツ定義
const List<OnboardingSlideData> onboardingSlides = [
  // スライド1: ようこそ
  OnboardingSlideData(
    title: 'ClipPixへようこそ',
    description: 'クリップボードから画像を自動保存し、\nタイル風グリッドで整理するアプリです',
    icon: Icons.auto_awesome,
    iconColor: Colors.amber,
    animationType: OnboardingAnimationType.scaleIn,
  ),

  // スライド2: フォルダ選択
  OnboardingSlideData(
    title: 'フォルダを選択',
    description: '最初に画像を保存するフォルダを選んでください。\nサブフォルダも自動で認識されます',
    icon: Icons.folder_open,
    iconColor: Colors.blue,
    animationType: OnboardingAnimationType.slideUp,
  ),

  // スライド3: クリップボード監視
  OnboardingSlideData(
    title: 'クリップボード監視',
    description: '画像をコピーすると自動的に保存されます。\nURL画像も自動ダウンロード！\nスイッチでON/OFFを切り替えられます',
    icon: Icons.content_paste,
    iconColor: Colors.green,
    animationType: OnboardingAnimationType.fadeIn,
  ),

  // スライド4: グリッド操作
  OnboardingSlideData(
    title: 'グリッド操作',
    description: '• カードの角をドラッグでリサイズ\n• マウスホイールでズームイン/アウト\n• 長押し→ドラッグで並び替え\n• 右クリックでメニュー表示',
    icon: Icons.grid_view,
    iconColor: Colors.purple,
    animationType: OnboardingAnimationType.pulse,
  ),

  // スライド5: プレビューウィンドウ
  OnboardingSlideData(
    title: 'プレビューウィンドウ',
    description: 'カードをダブルクリックで大きく表示。\n複数のプレビューを同時に開けます。\n常に最前面に固定もできます',
    icon: Icons.open_in_new,
    iconColor: Colors.orange,
    animationType: OnboardingAnimationType.fadeIn,
  ),

  // スライド6: 完了
  OnboardingSlideData(
    title: '準備完了！',
    description: '設定画面（⚙アイコン）から\nいつでもこのチュートリアルを\n再表示できます',
    icon: Icons.check_circle,
    iconColor: Colors.teal,
    animationType: OnboardingAnimationType.scaleIn,
  ),
];
