import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../data/file_info_manager.dart';
import '../data/grid_card_preferences_repository.dart';

/// Result of a delete operation
class DeleteResult {
  const DeleteResult({
    required this.successfulPaths,
    required this.failedPaths,
    this.errors = const {},
  });

  /// File paths that were successfully deleted
  final List<String> successfulPaths;

  /// File paths that failed to delete
  final List<String> failedPaths;

  /// Error messages keyed by file path
  final Map<String, String> errors;

  bool get hasFailures => failedPaths.isNotEmpty;
  bool get isFullSuccess => failedPaths.isEmpty;
  int get successCount => successfulPaths.length;
  int get failureCount => failedPaths.length;
}

/// Service for deleting images and text files
///
/// Moves files to a `.trash` folder instead of permanent deletion.
/// Also removes associated metadata from FileInfoManager and GridCardPreferencesRepository.
class DeleteService {
  DeleteService({
    FileInfoManager? fileInfoManager,
    GridCardPreferencesRepository? preferencesRepository,
    Logger? logger,
  })  : _fileInfoManager = fileInfoManager,
        _preferencesRepository = preferencesRepository,
        _logger = logger ?? Logger('DeleteService');

  final FileInfoManager? _fileInfoManager;
  final GridCardPreferencesRepository? _preferencesRepository;
  final Logger _logger;

  static const _trashFolderName = '.trash';

  /// Delete multiple items by moving them to .trash folder
  ///
  /// For each item:
  /// 1. Move file to .trash subfolder
  /// 2. Remove metadata from .fileInfo.json
  /// 3. Remove card preferences from Hive
  ///
  /// Returns [DeleteResult] with successful and failed paths.
  Future<DeleteResult> deleteItems(List<String> itemPaths) async {
    if (itemPaths.isEmpty) {
      _logger.warning('deleteItems called with empty list');
      return const DeleteResult(successfulPaths: [], failedPaths: []);
    }

    _logger.info('Deleting ${itemPaths.length} items');

    final successfulPaths = <String>[];
    final failedPaths = <String>[];
    final errors = <String, String>{};

    for (final itemPath in itemPaths) {
      try {
        await _deleteItem(itemPath);
        successfulPaths.add(itemPath);
        _logger.fine('Successfully deleted: $itemPath');
      } catch (error, stackTrace) {
        failedPaths.add(itemPath);
        errors[itemPath] = error.toString();
        _logger.warning(
          'Failed to delete: $itemPath',
          error,
          stackTrace,
        );
      }
    }

    _logger.info(
      'Delete completed: ${successfulPaths.length} succeeded, ${failedPaths.length} failed',
    );

    return DeleteResult(
      successfulPaths: successfulPaths,
      failedPaths: failedPaths,
      errors: errors,
    );
  }

  /// Delete a single item
  Future<void> _deleteItem(String itemPath) async {
    final file = File(itemPath);
    if (!await file.exists()) {
      throw Exception('File does not exist: $itemPath');
    }

    final parentDirectory = file.parent;
    final trashDirectory =
        Directory(p.join(parentDirectory.path, _trashFolderName));

    // Ensure .trash folder exists
    if (!await trashDirectory.exists()) {
      await trashDirectory.create();
      _logger.fine('Created trash directory: ${trashDirectory.path}');
    }

    // Move file to .trash
    final fileName = p.basename(itemPath);
    final trashFilePath = p.join(trashDirectory.path, fileName);
    await file.rename(trashFilePath);
    _logger.fine('Moved to trash: $itemPath -> $trashFilePath');

    // Remove metadata from .fileInfo.json
    if (_fileInfoManager != null) {
      try {
        await _fileInfoManager!.removeMetadata(itemPath);
        _logger.fine('Removed metadata: $itemPath');
      } catch (error, stackTrace) {
        _logger.warning(
          'Failed to remove metadata for $itemPath',
          error,
          stackTrace,
        );
        // Continue - metadata removal failure shouldn't block deletion
      }
    }

    // Remove card preferences from Hive
    if (_preferencesRepository != null) {
      try {
        await _preferencesRepository!.remove(itemPath);
        _logger.fine('Removed card preferences: $itemPath');
      } catch (error, stackTrace) {
        _logger.warning(
          'Failed to remove card preferences for $itemPath',
          error,
          stackTrace,
        );
        // Continue - preferences removal failure shouldn't block deletion
      }
    }
  }

  /// Empty the .trash folder for a given directory
  ///
  /// Permanently deletes all files in the .trash subfolder.
  Future<void> emptyTrash(Directory parentDirectory) async {
    final trashDirectory =
        Directory(p.join(parentDirectory.path, _trashFolderName));

    if (!await trashDirectory.exists()) {
      _logger.fine('Trash folder does not exist: ${trashDirectory.path}');
      return;
    }

    try {
      await trashDirectory.delete(recursive: true);
      _logger.info('Trash folder emptied: ${trashDirectory.path}');
    } catch (error, stackTrace) {
      _logger.severe(
        'Failed to empty trash: ${trashDirectory.path}',
        error,
        stackTrace,
      );
      rethrow;
    }
  }
}
