import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:haptic_feedback/haptic_feedback.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HapticService {
  static final HapticService _instance = HapticService._internal();
  factory HapticService() => _instance;
  HapticService._internal();

  static const String _hapticsEnabledKey = 'haptics_enabled';
  bool _hapticsEnabled = true; // Default to enabled
  bool _initialized = false;

  /// Initialize the haptic service by loading settings
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      _hapticsEnabled = prefs.getBool(_hapticsEnabledKey) ?? true;
      _initialized = true;
      debugPrint(
          'HapticService: Initialized with haptics ${_hapticsEnabled ? 'enabled' : 'disabled'}');
    } catch (e) {
      debugPrint('HapticService: Failed to initialize: $e');
      _hapticsEnabled = true; // Default to enabled on error
      _initialized = true;
    }
  }

  /// Check if haptics are enabled
  bool get hapticsEnabled => _hapticsEnabled;

  /// Set haptics enabled/disabled
  Future<void> setHapticsEnabled(bool enabled) async {
    _hapticsEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_hapticsEnabledKey, enabled);
      debugPrint('HapticService: Haptics ${enabled ? 'enabled' : 'disabled'}');
    } catch (e) {
      debugPrint('HapticService: Failed to save haptic setting: $e');
    }
  }

  /// Perform light haptic feedback (for button presses, etc.)
  Future<void> lightImpact() async {
    if (!_hapticsEnabled) return;

    try {
      await HapticFeedback.lightImpact();
    } catch (e) {
      // Haptics not supported on this device/platform
      debugPrint('HapticService: Light impact not supported: $e');
    }
  }

  /// Perform medium haptic feedback (for more significant actions)
  Future<void> mediumImpact() async {
    if (!_hapticsEnabled) return;

    try {
      await HapticFeedback.mediumImpact();
    } catch (e) {
      // Haptics not supported on this device/platform
      debugPrint('HapticService: Medium impact not supported: $e');
    }
  }

  /// Perform heavy haptic feedback (for important actions)
  Future<void> heavyImpact() async {
    if (!_hapticsEnabled) return;

    try {
      await HapticFeedback.heavyImpact();
    } catch (e) {
      // Haptics not supported on this device/platform
      debugPrint('HapticService: Heavy impact not supported: $e');
    }
  }

  /// Perform selection haptic feedback (for confirmations)
  Future<void> selection() async {
    if (!_hapticsEnabled) return;

    try {
      await HapticFeedback.selectionClick();
    } catch (e) {
      // Haptics not supported on this device/platform
      debugPrint('HapticService: Selection haptic not supported: $e');
    }
  }
}
