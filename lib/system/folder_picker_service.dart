import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:logging/logging.dart';

class FolderPickerService {
  FolderPickerService({Logger? logger})
      : _logger = logger ?? Logger('FolderPickerService');

  final Logger _logger;

  Future<Directory?> pickFolder({String? initialDirectory}) async {
    try {
      final path = await getDirectoryPath(initialDirectory: initialDirectory);
      if (path == null || path.isEmpty) {
        return null;
      }
      final directory = Directory(path);
      if (!await directory.exists()) {
        _logger.warning('Selected directory does not exist: $path');
        return null;
      }
      return directory;
    } catch (error, stackTrace) {
      _logger.severe('Failed to pick directory', error, stackTrace);
      return null;
    }
  }
}
