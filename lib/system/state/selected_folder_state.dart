import 'dart:io';

import 'package:collection/collection.dart';

import 'folder_view_mode.dart';

class SelectedFolderState {
  const SelectedFolderState({
    required this.current,
    required this.history,
    required this.viewMode,
    required this.currentTab,
    required this.rootScrollOffset,
    required this.isValid,
  });

  factory SelectedFolderState.initial() => SelectedFolderState(
        current: null,
        history: const <Directory>[],
        viewMode: FolderViewMode.root,
        currentTab: null,
        rootScrollOffset: 0,
        isValid: false,
      );

  final Directory? current;
  final List<Directory> history;
  final FolderViewMode viewMode;
  final String? currentTab;
  final double rootScrollOffset;
  final bool isValid;

  SelectedFolderState copyWith({
    Directory? current,
    List<Directory>? history,
    FolderViewMode? viewMode,
    String? currentTab,
    double? rootScrollOffset,
    bool? isValid,
  }) {
    return SelectedFolderState(
      current: current ?? this.current,
      history: history ?? this.history,
      viewMode: viewMode ?? this.viewMode,
      currentTab: currentTab ?? this.currentTab,
      rootScrollOffset: rootScrollOffset ?? this.rootScrollOffset,
      isValid: isValid ?? this.isValid,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'current': current?.path,
      'history': history.map((dir) => dir.path).toList(growable: false),
      'viewMode': viewMode.name,
      'currentTab': currentTab,
      'rootScrollOffset': rootScrollOffset,
      'isValid': isValid,
    };
  }

  static SelectedFolderState fromJson(Map<String, dynamic> json) {
    final currentPath = json['current'] as String?;
    final historyPaths = (json['history'] as List?)
            ?.whereType<String>()
            .map((path) => Directory(path))
            .toList(growable: false) ??
        const <Directory>[];
    final viewModeName = json['viewMode'] as String? ?? 'root';
    final viewMode = FolderViewMode.values.firstWhere(
      (mode) => mode.name == viewModeName,
      orElse: () => FolderViewMode.root,
    );
    return SelectedFolderState(
      current: currentPath != null ? Directory(currentPath) : null,
      history: historyPaths,
      viewMode: viewMode,
      currentTab: json['currentTab'] as String?,
      rootScrollOffset: (json['rootScrollOffset'] as num?)?.toDouble() ?? 0,
      isValid: json['isValid'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SelectedFolderState &&
        other.current?.path == current?.path &&
        const ListEquality<String>().equals(
          other.history.map((e) => e.path).toList(),
          history.map((e) => e.path).toList(),
        ) &&
        other.viewMode == viewMode &&
        other.currentTab == currentTab &&
        other.rootScrollOffset == rootScrollOffset &&
        other.isValid == isValid;
  }

  @override
  int get hashCode => Object.hash(
        current?.path,
        Object.hashAll(history.map((e) => e.path)),
        viewMode,
        currentTab,
        rootScrollOffset,
        isValid,
      );
}
