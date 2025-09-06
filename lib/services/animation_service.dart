import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AnimationType {
  pageTransitions,
  equalizerAnimations,
  songChangeAnimations,
  uiAnimations,
  lyricsAnimations,
  all,
}

class AnimationService extends ChangeNotifier {
  static AnimationService? _instance;
  static AnimationService get instance => _instance ??= AnimationService._();

  final Map<AnimationType, bool> _animationSettings = {
    AnimationType.pageTransitions: true,
    AnimationType.equalizerAnimations: true,
    AnimationType.songChangeAnimations: true,
    AnimationType.uiAnimations: true,
    AnimationType.lyricsAnimations: true,
  };

  AnimationService._() {
    _loadAnimationSettings();
  }

  Future<void> _loadAnimationSettings() async {
    final prefs = await SharedPreferences.getInstance();

    // Load individual settings
    for (AnimationType type in AnimationType.values) {
      if (type != AnimationType.all) {
        _animationSettings[type] =
            prefs.getBool('animation_${type.name}') ?? true;
      }
    }

    notifyListeners();
  }

  Future<void> setAnimationEnabled(AnimationType type, bool enabled) async {
    if (type == AnimationType.all) {
      // Set all animations to the same value
      for (AnimationType animType in AnimationType.values) {
        if (animType != AnimationType.all) {
          _animationSettings[animType] = enabled;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('animation_${animType.name}', enabled);
        }
      }
    } else {
      _animationSettings[type] = enabled;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('animation_${type.name}', enabled);
    }

    notifyListeners();
  }

  bool isAnimationEnabled(AnimationType type) {
    if (type == AnimationType.all) {
      return _animationSettings.values.every((enabled) => enabled);
    }
    return _animationSettings[type] ?? true;
  }

  // Legacy method for backward compatibility
  bool get animationsEnabled => isAnimationEnabled(AnimationType.all);

  // Helper method to get animation duration based on setting
  Duration getAnimationDuration(Duration defaultDuration,
      {AnimationType? type}) {
    final animationType = type ?? AnimationType.uiAnimations;
    return isAnimationEnabled(animationType) ? defaultDuration : Duration.zero;
  }

  // Helper method to get animation curve based on setting
  Curve getAnimationCurve(Curve defaultCurve, {AnimationType? type}) {
    final animationType = type ?? AnimationType.uiAnimations;
    return isAnimationEnabled(animationType) ? defaultCurve : Curves.linear;
  }

  // Helper method to check if animations should be enabled for a specific widget
  bool shouldAnimate({AnimationType? type}) {
    final animationType = type ?? AnimationType.uiAnimations;
    return isAnimationEnabled(animationType);
  }

  // Helper method to get a zero duration for disabled animations
  Duration get zeroDuration => Duration.zero;

  // Helper method to get a linear curve for disabled animations
  Curve get linearCurve => Curves.linear;

  // Get all animation settings for the UI
  Map<AnimationType, bool> get animationSettings =>
      Map.unmodifiable(_animationSettings);

  // Reset all settings to default
  Future<void> resetToDefaults() async {
    for (AnimationType type in AnimationType.values) {
      if (type != AnimationType.all) {
        _animationSettings[type] = true;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('animation_${type.name}', true);
      }
    }
    notifyListeners();
  }
}
