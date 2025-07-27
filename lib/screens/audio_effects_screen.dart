import 'package:flutter/material.dart';
import '../services/audio_effects_service.dart';

class AudioEffectsScreen extends StatefulWidget {
  const AudioEffectsScreen({super.key});

  @override
  State<AudioEffectsScreen> createState() => _AudioEffectsScreenState();
}

class _AudioEffectsScreenState extends State<AudioEffectsScreen> {
  final AudioEffectsService _audioEffectsService = AudioEffectsService();
  bool _isEnabled = false;
  double _bassBoost = 0.0;
  double _reverb = 0.0;
  List<double> _equalizerBands = List.filled(10, 0.0);
  String _currentPreset = 'Flat';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    await _audioEffectsService.loadSettings();
    setState(() {
      _isEnabled = _audioEffectsService.isEnabled;
      _bassBoost = _audioEffectsService.bassBoost;
      _reverb = _audioEffectsService.reverb;
      _equalizerBands = List.from(_audioEffectsService.equalizerBands);
      _currentPreset = _audioEffectsService.getCurrentPresetName();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audio Effects'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _resetToDefaults,
            tooltip: 'Reset to Defaults',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Master Enable Switch
          Card(
            child: ListTile(
              leading: const Icon(Icons.graphic_eq),
              title: const Text('Enable Audio Effects'),
              subtitle: const Text('Master switch for all audio effects'),
              trailing: Switch(
                value: _isEnabled,
                onChanged: (value) async {
                  await _audioEffectsService.setEnabled(value);
                  setState(() {
                    _isEnabled = value;
                  });
                },
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Equalizer Section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.equalizer),
                      const SizedBox(width: 8),
                      const Text(
                        'Equalizer',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _currentPreset,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  
                  // Preset Dropdown
                  DropdownButtonFormField<String>(
                    value: _currentPreset,
                    decoration: const InputDecoration(
                      labelText: 'Preset',
                      border: OutlineInputBorder(),
                    ),
                    items: _audioEffectsService.equalizerPresets.map((preset) {
                      return DropdownMenuItem<String>(
                        value: preset,
                        child: Text(preset),
                      );
                    }).toList(),
                    onChanged: (value) async {
                      if (value != null) {
                        await _audioEffectsService.setEqualizerPreset(value);
                        setState(() {
                          _equalizerBands = List.from(_audioEffectsService.equalizerBands);
                          _currentPreset = value;
                        });
                      }
                    },
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // Equalizer Bands
                  SizedBox(
                    height: 200,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: List.generate(10, (index) {
                        return Expanded(
                          child: Column(
                            children: [
                              // Frequency label
                              Text(
                                _formatFrequency(_audioEffectsService.frequencyBands[index]),
                                style: const TextStyle(fontSize: 10),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                              // Slider
                              Expanded(
                                child: RotatedBox(
                                  quarterTurns: 3,
                                  child: Slider(
                                    value: _equalizerBands[index],
                                    min: -12.0,
                                    max: 12.0,
                                    divisions: 24,
                                    onChanged: (value) async {
                                      await _audioEffectsService.setEqualizerBand(index, value);
                                      setState(() {
                                        _equalizerBands[index] = value;
                                        _currentPreset = _audioEffectsService.getCurrentPresetName();
                                      });
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              // Value label
                              Text(
                                '${_equalizerBands[index].toStringAsFixed(1)}dB',
                                style: const TextStyle(fontSize: 10),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        );
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Bass Boost Section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.volume_up),
                      const SizedBox(width: 8),
                      const Text(
                        'Bass Boost',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${_bassBoost.toStringAsFixed(1)}dB',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Slider(
                    value: _bassBoost,
                    min: -12.0,
                    max: 12.0,
                    divisions: 24,
                    label: '${_bassBoost.toStringAsFixed(1)}dB',
                    onChanged: (value) async {
                      await _audioEffectsService.setBassBoost(value);
                      setState(() {
                        _bassBoost = value;
                      });
                    },
                  ),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('-12dB', style: TextStyle(fontSize: 12)),
                      Text('0dB', style: TextStyle(fontSize: 12)),
                      Text('+12dB', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Reverb Section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.eco),
                      const SizedBox(width: 8),
                      const Text(
                        'Reverb',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${(_reverb * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Slider(
                    value: _reverb,
                    min: 0.0,
                    max: 1.0,
                    divisions: 20,
                    label: '${(_reverb * 100).toStringAsFixed(0)}%',
                    onChanged: (value) async {
                      await _audioEffectsService.setReverb(value);
                      setState(() {
                        _reverb = value;
                      });
                    },
                  ),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('0%', style: TextStyle(fontSize: 12)),
                      Text('50%', style: TextStyle(fontSize: 12)),
                      Text('100%', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Info Card
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'About Audio Effects',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Audio effects are applied in real-time to enhance your listening experience. '
                    'The equalizer allows you to adjust specific frequency bands, while bass boost '
                    'and reverb provide additional audio enhancement options.',
                    style: TextStyle(fontSize: 14),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatFrequency(double frequency) {
    if (frequency >= 1000) {
      return '${(frequency / 1000).toStringAsFixed(1)}k';
    }
    return frequency.toStringAsFixed(0);
  }

  Future<void> _resetToDefaults() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Reset Audio Effects?'),
          content: const Text('This will reset all audio effects to their default values. This action cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(
                'Reset',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      _audioEffectsService.resetToDefaults();
      await _loadSettings();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Audio effects reset to defaults')),
        );
      }
    }
  }
} 