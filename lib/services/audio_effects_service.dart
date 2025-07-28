import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

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
  List<double> _equalizerBands = List.filled(10, 0.0); // 10-band equalizer
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

  void setAudioPlayer(AudioPlayer audioPlayer) {
    _audioPlayer = audioPlayer;
    _applyEffects();
  }

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool('audio_effects_enabled') ?? false;
    _bassBoost = prefs.getDouble('audio_effects_bass_boost') ?? 0.0;
    _reverb = prefs.getDouble('audio_effects_reverb') ?? 0.0;
    _is8DMode = prefs.getBool('audio_effects_8d_mode') ?? false;
    _eightDIntensity = prefs.getDouble('audio_effects_8d_intensity') ?? 0.5;
    
    final equalizerBandsJson = prefs.getString('audio_effects_equalizer_bands');
    if (equalizerBandsJson != null) {
      try {
        final List<dynamic> bands = jsonDecode(equalizerBandsJson);
        _equalizerBands = bands.map((e) => (e as num).toDouble()).toList();
      } catch (e) {
        _equalizerBands = List.filled(10, 0.0);
      }
    }
    
    _applyEffects();
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('audio_effects_enabled', _isEnabled);
    await prefs.setDouble('audio_effects_bass_boost', _bassBoost);
    await prefs.setDouble('audio_effects_reverb', _reverb);
    await prefs.setBool('audio_effects_8d_mode', _is8DMode);
    await prefs.setDouble('audio_effects_8d_intensity', _eightDIntensity);
    await prefs.setString('audio_effects_equalizer_bands', jsonEncode(_equalizerBands));
  }

  Future<void> setEnabled(bool enabled) async {
    _isEnabled = enabled;
    await saveSettings();
    _applyEffects();
  }

  Future<void> setBassBoost(double value) async {
    _bassBoost = value.clamp(-12.0, 12.0);
    await saveSettings();
    _applyEffects();
  }

  Future<void> setReverb(double value) async {
    _reverb = value.clamp(0.0, 1.0);
    await saveSettings();
    _applyEffects();
  }

  Future<void> set8DMode(bool enabled) async {
    _is8DMode = enabled;
    await saveSettings();
    _applyEffects();
  }

  Future<void> set8DIntensity(double value) async {
    _eightDIntensity = value.clamp(0.1, 1.0);
    await saveSettings();
    _applyEffects();
  }

  Future<void> setEqualizerBand(int band, double value) async {
    if (band >= 0 && band < _equalizerBands.length) {
      _equalizerBands[band] = value.clamp(-12.0, 12.0);
      await saveSettings();
      _applyEffects();
    }
  }

  Future<void> setEqualizerPreset(String presetName) async {
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
        _equalizerBands = [-2.0, -1.0, 0.0, 2.0, 4.0, 4.0, 2.0, 0.0, -1.0, -2.0];
        break;
      case 'Rock':
        _equalizerBands = [4.0, 2.0, 0.0, -1.0, -2.0, 0.0, 2.0, 4.0, 6.0, 8.0];
        break;
      case 'Jazz':
        _equalizerBands = [2.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 3.0, 4.0];
        break;
      case 'Classical':
        _equalizerBands = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -1.0, -2.0, -2.0, -3.0];
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
    _applyEffects();
  }

  void reapplyEffects() {
    _applyEffects();
  }

  void _applyEffects() {
    if (_audioPlayer == null || !_isEnabled) {
      // Reset to default if disabled
      _audioPlayer?.setVolume(1.0);
      return;
    }

    // Apply bass boost (simplified implementation)
    double volumeMultiplier = 1.0;
    if (_bassBoost > 0) {
      volumeMultiplier += (_bassBoost / 12.0) * 0.3; // Max 30% volume increase
    } else if (_bassBoost < 0) {
      volumeMultiplier += (_bassBoost / 12.0) * 0.2; // Max 20% volume decrease
    }

    // Apply reverb effect (simplified - just volume adjustment)
    if (_reverb > 0) {
      volumeMultiplier += _reverb * 0.1; // Max 10% volume increase for reverb
    }

    // Apply 8D mode effect (spatial audio simulation)
    if (_is8DMode) {
      // 8D effect increases overall volume and adds a slight boost to create spatial feeling
      volumeMultiplier += _eightDIntensity * 0.15; // Max 15% volume increase for 8D effect
      
      // Additional boost to simulate spatial audio enhancement
      volumeMultiplier += _eightDIntensity * 0.1; // Extra 10% for spatial effect
    }

    // Apply equalizer (simplified - overall volume adjustment based on average)
    double averageEq = _equalizerBands.reduce((a, b) => a + b) / _equalizerBands.length;
    if (averageEq > 0) {
      volumeMultiplier += (averageEq / 12.0) * 0.2; // Max 20% volume increase
    } else if (averageEq < 0) {
      volumeMultiplier += (averageEq / 12.0) * 0.15; // Max 15% volume decrease
    }

    // Clamp volume multiplier
    volumeMultiplier = volumeMultiplier.clamp(0.1, 2.0);
    
    _audioPlayer?.setVolume(volumeMultiplier);
  }

  void resetToDefaults() {
    _isEnabled = false;
    _bassBoost = 0.0;
    _reverb = 0.0;
    _is8DMode = false;
    _eightDIntensity = 0.5;
    _equalizerBands = List.filled(10, 0.0);
    saveSettings();
    _applyEffects();
  }

  String getCurrentPresetName() {
    // Check if current settings match any preset
    if (_equalizerBands.every((band) => band == 0.0)) return 'Flat';
    
    // Simple preset detection (could be improved)
    if (_equalizerBands[0] > 3.0 && _equalizerBands[1] > 2.0) return 'Bass Boost';
    if (_equalizerBands[8] > 3.0 && _equalizerBands[9] > 5.0) return 'Treble Boost';
    if (_equalizerBands[3] > 2.0 && _equalizerBands[4] > 3.0) return 'Vocal Boost';
    
    return 'Custom';
  }

  // Frequency bands for the 10-band equalizer (typical values)
  List<double> get frequencyBands => [
    32.0,    // 32 Hz
    64.0,    // 64 Hz
    125.0,   // 125 Hz
    250.0,   // 250 Hz
    500.0,   // 500 Hz
    1000.0,  // 1 kHz
    2000.0,  // 2 kHz
    4000.0,  // 4 kHz
    8000.0,  // 8 kHz
    16000.0, // 16 kHz
  ];
} 