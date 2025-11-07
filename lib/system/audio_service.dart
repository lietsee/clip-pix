import 'package:audioplayers/audioplayers.dart';
import 'package:logging/logging.dart';

/// Service for playing audio notifications
///
/// Plays sound effects for app events (e.g., successful image saves).
/// Sound playback can be enabled/disabled via [soundEnabled] property.
///
/// Error handling: Audio errors are logged but do not interrupt app functionality.
class AudioService {
  AudioService({Logger? logger})
      : _logger = logger ?? Logger('AudioService');

  final Logger _logger;
  final AudioPlayer _player = AudioPlayer();
  bool _soundEnabled = true; // Default ON

  /// Whether sound effects are currently enabled
  bool get soundEnabled => _soundEnabled;

  /// Enable or disable sound effects
  void setSoundEnabled(bool enabled) {
    _soundEnabled = enabled;
    _logger.fine('Sound effects ${enabled ? 'enabled' : 'disabled'}');
  }

  /// Play the save success notification sound
  ///
  /// Does nothing if [soundEnabled] is false.
  /// Logs errors silently without interrupting app flow.
  Future<void> playSaveSuccess() async {
    if (!_soundEnabled) {
      return;
    }

    try {
      await _player.play(AssetSource('sounds/save_success.mp3'));
      _logger.finest('Played save success sound');
    } catch (error, stackTrace) {
      // Silent failure - audio errors should not break functionality
      _logger.fine('Failed to play save sound', error, stackTrace);
    }
  }

  /// Release audio player resources
  void dispose() {
    _player.dispose();
    _logger.fine('AudioService disposed');
  }
}
