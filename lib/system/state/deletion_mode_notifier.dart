import 'package:logging/logging.dart';
import 'package:state_notifier/state_notifier.dart';

import 'deletion_mode_state.dart';

/// Notifier for bulk deletion mode state
///
/// Manages:
/// - Entering/exiting deletion mode
/// - Selecting/deselecting cards for deletion
/// - Tracking deletion operation progress
class DeletionModeNotifier extends StateNotifier<DeletionModeState> {
  DeletionModeNotifier({Logger? logger})
      : _logger = logger ?? Logger('DeletionModeNotifier'),
        super(const DeletionModeState());

  final Logger _logger;

  /// Enter deletion mode
  void enterDeletionMode() {
    if (state.isActive) {
      _logger.fine('Already in deletion mode');
      return;
    }

    _logger.info('Entering deletion mode');
    state = state.copyWith(isActive: true);
  }

  /// Exit deletion mode and clear selection
  void exitDeletionMode() {
    if (!state.isActive) {
      _logger.fine('Already exited deletion mode');
      return;
    }

    _logger.info(
        'Exiting deletion mode, clearing ${state.selectedCount} selections');
    state = const DeletionModeState(); // Reset to initial state
  }

  /// Toggle selection for a card
  ///
  /// If the card is currently selected, deselect it.
  /// If not selected, add it to the selection.
  void toggleSelection(String cardId) {
    if (!state.isActive) {
      _logger
          .warning('Attempted to toggle selection while not in deletion mode');
      return;
    }

    final newSelection = Set<String>.from(state.selectedCardIds);

    if (newSelection.contains(cardId)) {
      newSelection.remove(cardId);
      _logger.fine('Deselected card: $cardId');
    } else {
      newSelection.add(cardId);
      _logger.fine('Selected card: $cardId');
    }

    state = state.copyWith(selectedCardIds: newSelection);
    _logger.fine('Selection updated: ${newSelection.length} cards selected');
  }

  /// Clear all selected cards
  void clearSelection() {
    if (state.selectedCardIds.isEmpty) {
      _logger.fine('No selection to clear');
      return;
    }

    _logger.info('Clearing ${state.selectedCount} selections');
    state = state.copyWith(selectedCardIds: {});
  }

  /// Set the deleting flag
  ///
  /// Call with true when starting deletion operation,
  /// false when operation completes.
  void setDeleting(bool isDeleting) {
    if (state.isDeleting == isDeleting) {
      return;
    }

    _logger.fine('Setting isDeleting: $isDeleting');
    state = state.copyWith(isDeleting: isDeleting);
  }
}
