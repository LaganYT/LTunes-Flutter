import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async'; // Added for Timer

class AudioEffectsService {
  static final AudioEffectsService _instance = AudioEffectsService._internal();
  factory AudioEffectsService() => _instance;
  AudioEffectsService._internal();

  AudioPlayer? _audioPlayer;
  bool _isEnabled = false;
  double _bassBoost = 0.0;
  double _reverb = 0.0;
  bool _is8DMode = false;
  double _eightDIntensity = 0.5;
  List<double> _equalizerBands = List.filled(10, 0.0);
  String _currentPresetName = 'Flat';

  // Improved state management
  bool _isInitialized = false;
  double _baseVolume = 1.0;
  Timer? _debounceTimer;
  static const Duration _debounceDelay = Duration(milliseconds: 100);

  final List<String> _equalizerPresets = [
    'Flat',
    'Bass Boost',
    'Treble Boost',
    'Vocal Boost',
    'Rock',
    'Jazz',
    'Classical',
    'Pop',
    'Electronic',
    'Custom'
  ];

  // Getters
  bool get isEnabled => _isEnabled;
  double get bassBoost => _bassBoost;
  double get reverb => _reverb;
  bool get is8DMode => _is8DMode;
  double get eightDIntensity => _eightDIntensity;
  List<double> get equalizerBands => List.unmodifiable(_equalizerBands);
  List<String> get equalizerPresets => List.unmodifiable(_equalizerPresets);
  String get currentPresetName => _currentPresetName;
  bool get isInitialized => _isInitialized;

  void setAudioPlayer(AudioPlayer audioPlayer) {
    _audioPlayer = audioPlayer;
    _isInitialized = true;
    _applyEffects();
  }

  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isEnabled = prefs.getBool('audio_effects_enabled') ?? false;
      _bassBoost = prefs.getDouble('audio_effects_bass_boost') ?? 0.0;
      _reverb = prefs.getDouble('audio_effects_reverb') ?? 0.0;
      _is8DMode = prefs.getBool('audio_effects_8d_mode') ?? false;
      _eightDIntensity = prefs.getDouble('audio_effects_8d_intensity') ?? 0.5;
      _currentPresetName =
          prefs.getString('audio_effects_current_preset') ?? 'Flat';

      final equalizerBandsJson =
          prefs.getString('audio_effects_equalizer_bands');
      if (equalizerBandsJson != null) {
        try {
          final List<dynamic> bands = jsonDecode(equalizerBandsJson);
          _equalizerBands = bands.map((e) => (e as num).toDouble()).toList();
        } catch (e) {
          _equalizerBands = List.filled(10, 0.0);
        }
      }

      _applyEffects();
    } catch (e) {
      // Reset to defaults if loading fails
      resetToDefaults();
    }
  }

  Future<void> saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('audio_effects_enabled', _isEnabled);
      await prefs.setDouble('audio_effects_bass_boost', _bassBoost);
      await prefs.setDouble('audio_effects_reverb', _reverb);
      await prefs.setBool('audio_effects_8d_mode', _is8DMode);
      await prefs.setDouble('audio_effects_8d_intensity', _eightDIntensity);
      await prefs.setString('audio_effects_current_preset', _currentPresetName);
      await prefs.setString(
          'audio_effects_equalizer_bands', jsonEncode(_equalizerBands));
    } catch (e) {
      // Log error but don't throw to prevent app crashes
    }
  }

  Future<void> setEnabled(bool enabled) async {
    _isEnabled = enabled;
    await saveSettings();
    _applyEffects();
  }

  Future<void> setBassBoost(double value) async {
    _bassBoost = value.clamp(-12.0, 12.0);
    await saveSettings();
    _debouncedApplyEffects();
  }

  Future<void> setReverb(double value) async {
    _reverb = value.clamp(0.0, 1.0);
    await saveSettings();
    _debouncedApplyEffects();
  }

  Future<void> set8DMode(bool enabled) async {
    _is8DMode = enabled;
    await saveSettings();
    _debouncedApplyEffects();
  }

  Future<void> set8DIntensity(double value) async {
    _eightDIntensity = value.clamp(0.1, 1.0);
    await saveSettings();
    _debouncedApplyEffects();
  }

  Future<void> setEqualizerBand(int band, double value) async {
    if (band >= 0 && band < _equalizerBands.length) {
      _equalizerBands[band] = value.clamp(-12.0, 12.0);
      if (_currentPresetName != 'Custom') {
        _currentPresetName = 'Custom';
      }
      await saveSettings();
      _debouncedApplyEffects();
    }
  }

  Future<void> setEqualizerPreset(String presetName) async {
    if (!_equalizerPresets.contains(presetName)) return;

    _currentPresetName = presetName;

    switch (presetName) {
      case 'Flat':
        _equalizerBands = List.filled(10, 0.0);
        break;
      case 'Bass Boost':
        _equalizerBands = [6.0, 4.0, 2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
        break;
      case 'Treble Boost':
        _equalizerBands = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 4.0, 6.0, 8.0];
        break;
      case 'Vocal Boost':
        _equalizerBands = [
          -2.0,
          -1.0,
          0.0,
          2.0,
          4.0,
          4.0,
          2.0,
          0.0,
          -1.0,
          -2.0
        ];
        break;
      case 'Rock':
        _equalizerBands = [4.0, 2.0, 0.0, -1.0, -2.0, 0.0, 2.0, 4.0, 6.0, 8.0];
        break;
      case 'Jazz':
        _equalizerBands = [2.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 3.0, 4.0];
        break;
      case 'Classical':
        _equalizerBands = [
          0.0,
          0.0,
          0.0,
          0.0,
          0.0,
          0.0,
          -1.0,
          -2.0,
          -2.0,
          -3.0
        ];
        break;
      case 'Pop':
        _equalizerBands = [3.0, 2.0, 1.0, 0.0, 0.0, 0.0, 1.0, 2.0, 3.0, 4.0];
        break;
      case 'Electronic':
        _equalizerBands = [6.0, 4.0, 2.0, 0.0, -1.0, 0.0, 2.0, 4.0, 6.0, 8.0];
        break;
      case 'Custom':
        // Keep current values
        break;
    }
    await saveSettings();
    _debouncedApplyEffects();
  }

  void reapplyEffects() {
    _applyEffects();
  }

  void _debouncedApplyEffects() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () {
      _applyEffects();
    });
  }

  void _applyEffects() {
    if (_audioPlayer == null || !_isInitialized) return;

    try {
      if (!_isEnabled) {
        // Reset to base volume when disabled
        _audioPlayer?.setVolume(_baseVolume);
        return;
      }

      // Calculate combined effect multiplier
      double volumeMultiplier = _baseVolume;

      // Apply bass boost effect
      if (_bassBoost != 0.0) {
        volumeMultiplier += _calculateBassBoostEffect();
      }

      // Apply reverb effect
      if (_reverb > 0.0) {
        volumeMultiplier += _calculateReverbEffect();
      }

      // Apply 8D mode effect
      if (_is8DMode) {
        volumeMultiplier += _calculate8DEffect();
      }

      // Apply equalizer effect
      final eqEffect = _calculateEqualizerEffect();
      if (eqEffect != 0.0) {
        volumeMultiplier += eqEffect;
      }

      // Clamp volume multiplier to safe range
      volumeMultiplier = volumeMultiplier.clamp(0.1, 2.0);

      _audioPlayer?.setVolume(volumeMultiplier);
    } catch (e) {
      // Fallback to base volume if effects fail
      _audioPlayer?.setVolume(_baseVolume);
    }
  }

  double _calculateBassBoostEffect() {
    // Improved bass boost calculation
    if (_bassBoost > 0) {
      // Positive bass boost: increase low frequencies
      return (_bassBoost / 12.0) * 0.25; // Max 25% volume increase
    } else {
      // Negative bass boost: decrease low frequencies
      return (_bassBoost / 12.0) * 0.15; // Max 15% volume decrease
    }
  }

  double _calculateReverbEffect() {
    // Improved reverb simulation
    if (_reverb > 0.0) {
      // Reverb effect: slight volume increase to simulate spatial effect
      return _reverb * 0.08; // Max 8% volume increase
    }
    return 0.0;
  }

  double _calculate8DEffect() {
    // Improved 8D spatial audio effect
    if (_is8DMode && _eightDIntensity > 0.0) {
      // 8D effect: creates spatial feeling through volume modulation
      double spatialEffect = _eightDIntensity * 0.12; // Base spatial effect
      spatialEffect += _eightDIntensity * 0.08; // Additional enhancement
      return spatialEffect;
    }
    return 0.0;
  }

  double _calculateEqualizerEffect() {
    // Improved equalizer calculation
    if (_equalizerBands.isEmpty) return 0.0;

    // Calculate weighted average based on frequency importance
    double weightedSum = 0.0;
    double totalWeight = 0.0;

    for (int i = 0; i < _equalizerBands.length; i++) {
      double weight = _getFrequencyWeight(i);
      weightedSum += _equalizerBands[i] * weight;
      totalWeight += weight;
    }

    if (totalWeight == 0.0) return 0.0;

    double averageEq = weightedSum / totalWeight;

    if (averageEq > 0) {
      return (averageEq / 12.0) * 0.18; // Max 18% volume increase
    } else if (averageEq < 0) {
      return (averageEq / 12.0) * 0.12; // Max 12% volume decrease
    }

    return 0.0;
  }

  double _getFrequencyWeight(int bandIndex) {
    // Weight frequencies based on human hearing sensitivity
    // Lower frequencies (bass) and mid-high frequencies are more important
    switch (bandIndex) {
      case 0:
        return 1.2; // 32 Hz - bass
      case 1:
        return 1.1; // 64 Hz - bass
      case 2:
        return 1.0; // 125 Hz - bass
      case 3:
        return 0.9; // 250 Hz - low mid
      case 4:
        return 0.8; // 500 Hz - mid
      case 5:
        return 1.0; // 1 kHz - mid
      case 6:
        return 1.1; // 2 kHz - high mid
      case 7:
        return 1.2; // 4 kHz - high
      case 8:
        return 1.1; // 8 kHz - high
      case 9:
        return 0.9; // 16 kHz - very high
      default:
        return 1.0;
    }
  }

  void resetToDefaults() {
    _isEnabled = false;
    _bassBoost = 0.0;
    _reverb = 0.0;
    _is8DMode = false;
    _eightDIntensity = 0.5;
    _equalizerBands = List.filled(10, 0.0);
    _currentPresetName = 'Flat';

    _debounceTimer?.cancel();
    saveSettings();
    _applyEffects();
  }

  String getCurrentPresetName() {
    return _currentPresetName;
  }

  // Frequency bands for the 10-band equalizer (typical values)
  List<double> get frequencyBands => [
        32.0, // 32 Hz
        64.0, // 64 Hz
        125.0, // 125 Hz
        250.0, // 250 Hz
        500.0, // 500 Hz
        1000.0, // 1 kHz
        2000.0, // 2 kHz
        4000.0, // 4 kHz
        8000.0, // 8 kHz
        16000.0, // 16 kHz
      ];

  // Dispose method for cleanup
  void dispose() {
    _debounceTimer?.cancel();
    _audioPlayer = null;
    _isInitialized = false;
  }
}
