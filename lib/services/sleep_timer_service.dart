import 'dart:async';
import 'package:flutter/material.dart';
import '../providers/current_song_provider.dart';

class SleepTimerService {
  static final SleepTimerService _instance = SleepTimerService._internal();
  factory SleepTimerService() => _instance;
  SleepTimerService._internal();

  Timer? _sleepTimer;
  DateTime? _sleepTimerEndTime;
  int? _sleepTimerMinutes;
  CurrentSongProvider? _currentSongProvider;
  VoidCallback? _onTimerUpdate;
  VoidCallback? _onTimerExpired;

  // Getters
  DateTime? get sleepTimerEndTime => _sleepTimerEndTime;
  int? get sleepTimerMinutes => _sleepTimerMinutes;
  bool get isTimerActive => _sleepTimer != null && _sleepTimer!.isActive;
  bool get isInitialized => _currentSongProvider != null;

  // Initialize the service with the provider
  void initialize(CurrentSongProvider provider) {
    _currentSongProvider = provider;
  }

  // Set callbacks for UI updates
  void setCallbacks({
    VoidCallback? onTimerUpdate,
    VoidCallback? onTimerExpired,
  }) {
    _onTimerUpdate = onTimerUpdate;
    _onTimerExpired = onTimerExpired;
  }

  // Start the sleep timer
  void startTimer(int minutes) {
    _cancelTimer();
    
    _sleepTimerMinutes = minutes;
    _sleepTimerEndTime = DateTime.now().add(Duration(minutes: minutes));
    
    debugPrint('SleepTimerService: Timer started for $minutes minutes, ends at ${getEndTimeString()}');
    
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      debugPrint('SleepTimerService: Timer expired, stopping playback');
      _onTimerExpired?.call();
      _expireTimer();
    });
    
    _onTimerUpdate?.call();
  }

  // Cancel the sleep timer
  void cancelTimer() {
    debugPrint('SleepTimerService: Timer cancelled');
    _cancelTimer();
    _onTimerUpdate?.call();
  }

  void _cancelTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerMinutes = null;
    _sleepTimerEndTime = null;
  }

  void _expireTimer() {
    // Stop playback when timer expires
    _currentSongProvider?.stopSong();
    
    _cancelTimer();
    _onTimerUpdate?.call();
  }

  // Get remaining time as a string
  String getRemainingTimeString() {
    if (_sleepTimerEndTime == null) return '';
    
    final now = DateTime.now();
    final remaining = _sleepTimerEndTime!.difference(now);
    
    if (remaining.isNegative) return '';
    
    final hours = remaining.inHours;
    final minutes = remaining.inMinutes % 60;
    
    if (hours > 0) {
      return '${hours}h ${minutes}m remaining';
    } else {
      return '${minutes}m remaining';
    }
  }

  // Get end time as a string
  String getEndTimeString() {
    if (_sleepTimerEndTime == null) return '';
    
    return '${_sleepTimerEndTime!.hour.toString().padLeft(2, '0')}:${_sleepTimerEndTime!.minute.toString().padLeft(2, '0')}';
  }

  // Check if the timer is still valid (not expired)
  bool isTimerValid() {
    if (_sleepTimerEndTime == null || _sleepTimer == null) return false;
    
    final now = DateTime.now();
    final remaining = _sleepTimerEndTime!.difference(now);
    
    // If timer has expired, clear it
    if (remaining.isNegative) {
      debugPrint('SleepTimerService: Timer expired, clearing');
      _cancelTimer();
      return false;
    }
    
    debugPrint('SleepTimerService: Timer is valid, ${remaining.inMinutes}m remaining');
    return true;
  }

  // Dispose the service
  void dispose() {
    _cancelTimer();
    _currentSongProvider = null;
    _onTimerUpdate = null;
    _onTimerExpired = null;
  }

  // Clear only the callbacks (for when settings screen is disposed)
  void clearCallbacks() {
    _onTimerUpdate = null;
    _onTimerExpired = null;
  }
} 