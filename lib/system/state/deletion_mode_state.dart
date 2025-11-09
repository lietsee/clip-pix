/// State for bulk deletion mode
///
/// Tracks whether deletion mode is active, which cards are selected,
/// and whether a delete operation is in progress.
class DeletionModeState {
  const DeletionModeState({
    this.isActive = false,
    this.selectedCardIds = const {},
    this.isDeleting = false,
  });

  /// Whether deletion mode is currently active
  final bool isActive;

  /// IDs of cards selected for deletion (absolute file paths)
  final Set<String> selectedCardIds;

  /// Whether a delete operation is currently in progress
  final bool isDeleting;

  /// Whether any cards are selected
  bool get hasSelection => selectedCardIds.isNotEmpty;

  /// Number of selected cards
  int get selectedCount => selectedCardIds.length;

  /// Check if a specific card is selected
  bool isSelected(String cardId) => selectedCardIds.contains(cardId);

  DeletionModeState copyWith({
    bool? isActive,
    Set<String>? selectedCardIds,
    bool? isDeleting,
  }) {
    return DeletionModeState(
      isActive: isActive ?? this.isActive,
      selectedCardIds: selectedCardIds ?? this.selectedCardIds,
      isDeleting: isDeleting ?? this.isDeleting,
    );
  }

  @override
  String toString() {
    return 'DeletionModeState(isActive: $isActive, selectedCount: $selectedCount, isDeleting: $isDeleting)';
  }
}
