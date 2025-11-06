import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ltunes/services/improved_audio_handler.dart';
import 'package:rxdart/rxdart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ImprovedAudioHandler:', () {
    late ImprovedAudioHandler audioHandler;

    setUp(() {
      audioHandler = ImprovedAudioHandler();
    });

    tearDown(() async {
      await audioHandler.dispose();
    });

    test('Constructor sets correct default parameter values', () {
      final actual = audioHandler.playbackState.nvalue!;
      final expected = PlaybackState(updateTime: actual.updateTime);
      expect(actual, equals(expected));
      final timeNow = DateTime.now().millisecond;
      expect(actual.updateTime.millisecond, closeTo(timeNow, 1000));

      final queue = audioHandler.queue.nvalue;
      expect(queue, equals(<MediaItem>[]));

      final queueTitle = audioHandler.queueTitle.nvalue;
      expect(queueTitle, equals(''));

      final mediaItem = audioHandler.mediaItem.nvalue;
      expect(mediaItem, isNull);

      final androidPlaybackInfo = audioHandler.androidPlaybackInfo;
      expect(androidPlaybackInfo, isA<BehaviorSubject<AndroidPlaybackInfo>>());

      final ratingStyle = audioHandler.ratingStyle;
      expect(ratingStyle, isA<BehaviorSubject<RatingStyle>>());

      final customEvent = audioHandler.customEvent;
      expect(customEvent, isA<PublishSubject<dynamic>>());

      final customState = audioHandler.customState;
      expect(customState, isA<BehaviorSubject<dynamic>>());
    });

    test('click() default logic works', () async {
      // was paused, MediaButton.media clicked
      await audioHandler.click();
      expect(audioHandler.playbackState.nvalue!.playing, false);

      // MediaButton.next
      await audioHandler.click(MediaButton.next);
      // Should not crash and should handle empty queue gracefully

      // MediaButton.previous
      await audioHandler.click(MediaButton.previous);
      // Should not crash and should handle empty queue gracefully
    });

    test('stop() sets correct state', () async {
      await audioHandler.stop();
      expect(audioHandler.playbackState.nvalue!.processingState,
          AudioProcessingState.idle);
      expect(audioHandler.mediaItem.nvalue, isNull);
    });

    test('getChildren returns empty list by default', () async {
      final children = await audioHandler.getChildren('parentMediaId');
      expect(children, equals(<MediaItem>[]));
    });

    test('getMediaItem returns null for unknown mediaId', () async {
      final mediaItem = await audioHandler.getMediaItem('unknownId');
      expect(mediaItem, isNull);
    });

    test('search returns empty list by default', () async {
      final results = await audioHandler.search('query');
      expect(results, equals(<MediaItem>[]));
    });
  });

  group('QueueHandler functionality:', () {
    late ImprovedAudioHandler handler;

    setUp(() {
      handler = ImprovedAudioHandler();
    });

    tearDown(() async {
      await handler.dispose();
    });

    test('able to modify media items in queue', () async {
      // setup
      const mediaItem = MediaItem(id: '0', title: 'title');

      // add single item
      expect(handler.queue.nvalue?.length, equals(0));
      await handler.addQueueItem(mediaItem);
      expect(handler.queue.nvalue?.length, equals(1));

      // add multiple items
      await handler.addQueueItems([
        mediaItem.copyWith(id: '1'),
        mediaItem.copyWith(id: '2'),
      ]);
      expect(handler.queue.nvalue?.length, equals(3));

      // insert item
      await handler.insertQueueItem(1, mediaItem.copyWith(id: 'inserted'));
      expect(handler.queue.nvalue?.length, equals(4));
      expect(handler.queue.nvalue?[1].id, 'inserted');

      // update item
      expect(handler.queue.nvalue?[0].id, '0');
      expect(handler.queue.nvalue?[0].album, null);
      await handler.updateMediaItem(mediaItem.copyWith(album: 'abc'));
      expect(handler.queue.nvalue?.length, equals(4));
      expect(handler.queue.nvalue?[0].id, '0');
      expect(handler.queue.nvalue?[0].album, 'abc');

      // remove item
      await handler.removeQueueItemAt(0);
      expect(handler.queue.nvalue?.length, equals(3));

      // replace queue
      await handler.updateQueue([mediaItem]);
      expect(handler.queue.nvalue?.length, equals(1));
    });

    test('queue index updates correctly with queue modifications', () async {
      const mediaItem1 = MediaItem(id: '1', title: 'title1');
      const mediaItem2 = MediaItem(id: '2', title: 'title2');
      const mediaItem3 = MediaItem(id: '3', title: 'title3');
      
      await handler.addQueueItems([mediaItem1, mediaItem2, mediaItem3]);
      
      // Set current index to middle item
      await handler.skipToQueueItem(1);
      expect(handler.customAction('getCurrentQueueIndex'), completion(equals(1)));
      
      // Insert item before current index - should adjust current index
      await handler.insertQueueItem(0, const MediaItem(id: 'inserted', title: 'inserted'));
      expect(handler.customAction('getCurrentQueueIndex'), completion(equals(2)));
      
      // Remove item before current index - should adjust current index
      await handler.removeQueueItemAt(0);
      expect(handler.customAction('getCurrentQueueIndex'), completion(equals(1)));
    });

    test('skipToQueueItem handles invalid indices gracefully', () async {
      const mediaItem = MediaItem(id: '1', title: 'title1');
      await handler.addQueueItem(mediaItem);
      
      // Test negative index
      await handler.skipToQueueItem(-1);
      expect(handler.playbackState.nvalue!.processingState, AudioProcessingState.idle);
      
      // Test index beyond queue length
      await handler.skipToQueueItem(5);
      expect(handler.playbackState.nvalue!.processingState, AudioProcessingState.idle);
    });

    test('repeat mode affects queue navigation', () async {
      const mediaItem1 = MediaItem(id: '1', title: 'title1');
      const mediaItem2 = MediaItem(id: '2', title: 'title2');
      
      await handler.addQueueItems([mediaItem1, mediaItem2]);
      await handler.skipToQueueItem(1); // Go to last item
      
      // Test with repeat all
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      await handler.skipToNext(); // Should wrap to first item
      expect(handler.customAction('getCurrentQueueIndex'), completion(equals(0)));
      
      // Test with no repeat
      await handler.setRepeatMode(AudioServiceRepeatMode.none);
      await handler.skipToQueueItem(1); // Go back to last item
      await handler.skipToNext(); // Should still wrap (LTunes behavior)
      expect(handler.customAction('getCurrentQueueIndex'), completion(equals(0)));
    });

    test('shuffle mode state is tracked correctly', () async {
      expect(handler.playbackState.nvalue!.shuffleMode, AudioServiceShuffleMode.none);
      
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      expect(handler.playbackState.nvalue!.shuffleMode, AudioServiceShuffleMode.all);
      
      await handler.setShuffleMode(AudioServiceShuffleMode.none);
      expect(handler.playbackState.nvalue!.shuffleMode, AudioServiceShuffleMode.none);
    });
  });

  group('Playback State Management:', () {
    late ImprovedAudioHandler handler;

    setUp(() {
      handler = ImprovedAudioHandler();
    });

    tearDown(() async {
      await handler.dispose();
    });

    test('playback state updates correctly', () async {
      // Initial state should be idle
      expect(handler.playbackState.nvalue!.processingState, AudioProcessingState.idle);
      expect(handler.playbackState.nvalue!.playing, false);
      
      // Add a media item and prepare it
      const mediaItem = MediaItem(
        id: 'test://url',
        title: 'Test Song',
        artist: 'Test Artist',
      );
      
      await handler.addQueueItem(mediaItem);
      // Note: In a real test environment, we'd need to mock the audio player
      // For now, we just verify the queue was updated
      expect(handler.queue.nvalue?.length, 1);
    });

    test('custom actions work correctly', () async {
      // Test gapless mode
      await handler.customAction('setGaplessMode', {'enabled': false});
      final gaplessResult = await handler.customAction('getGaplessMode');
      expect(gaplessResult, {'gaplessMode': false});
      
      // Test queue inspection
      const mediaItem = MediaItem(id: 'test', title: 'Test');
      await handler.addQueueItem(mediaItem);
      
      final queueLength = await handler.customAction('getQueueLength');
      expect(queueLength, 1);
      
      final queueItem = await handler.customAction('getQueueItem', {'index': 0});
      expect(queueItem, isNotNull);
      expect(queueItem['id'], 'test');
      expect(queueItem['title'], 'Test');
    });

    test('playback state provides comprehensive information', () async {
      final stateResult = await handler.customAction('getPlaybackState');
      
      expect(stateResult, isA<Map<String, dynamic>>());
      expect(stateResult.containsKey('playing'), true);
      expect(stateResult.containsKey('processingState'), true);
      expect(stateResult.containsKey('position'), true);
      expect(stateResult.containsKey('queueIndex'), true);
      expect(stateResult.containsKey('repeatMode'), true);
      expect(stateResult.containsKey('shuffleMode'), true);
    });
  });

  group('Error Handling:', () {
    late ImprovedAudioHandler handler;

    setUp(() {
      handler = ImprovedAudioHandler();
    });

    tearDown(() async {
      await handler.dispose();
    });

    test('handles invalid media items gracefully', () async {
      // Test with invalid URI
      const invalidMediaItem = MediaItem(
        id: 'invalid://url',
        title: 'Invalid Song',
      );
      
      await handler.addQueueItem(invalidMediaItem);
      // Should not crash when trying to play invalid item
      await handler.play();
      
      // Should handle the error gracefully
      expect(handler.queue.nvalue?.length, 1);
    });

    test('audio session bug detection works', () async {
      final result = await handler.customAction('detectAndFixAudioSessionBug');
      
      expect(result, isA<Map<String, dynamic>>());
      expect(result.containsKey('bugDetected'), true);
      expect(result.containsKey('fixed'), true);
    });

    test('handles app lifecycle transitions', () async {
      // Test foreground transition
      final foregroundResult = await handler.customAction('handleAppForeground');
      expect(foregroundResult, {'handled': true});
      
      // Test background transition
      final backgroundResult = await handler.customAction('handleAppBackground');
      expect(backgroundResult, {'handled': true});
    });
  });

  group('Audio Effects Integration:', () {
    late ImprovedAudioHandler handler;

    setUp(() {
      handler = ImprovedAudioHandler();
    });

    tearDown(() async {
      await handler.dispose();
    });

    test('audio effects state can be retrieved', () async {
      final effectsState = await handler.customAction('getAudioEffectsState');
      
      expect(effectsState, isA<Map<String, dynamic>>());
      expect(effectsState.containsKey('isEnabled'), true);
      expect(effectsState.containsKey('bassBoost'), true);
      expect(effectsState.containsKey('reverb'), true);
      expect(effectsState.containsKey('is8DMode'), true);
      expect(effectsState.containsKey('equalizerBands'), true);
    });
  });

  group('Robustness Tests:', () {
    late ImprovedAudioHandler handler;

    setUp(() {
      handler = ImprovedAudioHandler();
    });

    tearDown(() async {
      await handler.dispose();
    });

    test('handles rapid queue modifications', () async {
      final mediaItems = List.generate(10, (i) => 
          MediaItem(id: 'item_$i', title: 'Item $i'));
      
      // Rapidly add items
      for (final item in mediaItems) {
        await handler.addQueueItem(item);
      }
      expect(handler.queue.nvalue?.length, 10);
      
      // Rapidly remove items
      for (int i = 9; i >= 0; i--) {
        await handler.removeQueueItemAt(i);
      }
      expect(handler.queue.nvalue?.length, 0);
    });

    test('maintains state consistency during complex operations', () async {
      const mediaItem1 = MediaItem(id: '1', title: 'Song 1');
      const mediaItem2 = MediaItem(id: '2', title: 'Song 2');
      const mediaItem3 = MediaItem(id: '3', title: 'Song 3');
      
      await handler.addQueueItems([mediaItem1, mediaItem2, mediaItem3]);
      await handler.skipToQueueItem(1);
      
      // Current index should be 1
      expect(handler.customAction('getCurrentQueueIndex'), completion(equals(1)));
      
      // Insert at beginning should adjust current index
      await handler.insertQueueItem(0, const MediaItem(id: 'inserted', title: 'Inserted'));
      expect(handler.customAction('getCurrentQueueIndex'), completion(equals(2)));
      
      // Queue length should be 4
      expect(handler.customAction('getQueueLength'), completion(equals(4)));
      
      // Current item should still be mediaItem2
      final currentItem = await handler.customAction('getQueueItem', {'index': 2});
      expect(currentItem['id'], '2');
    });

    test('dispose cleans up resources properly', () async {
      const mediaItem = MediaItem(id: 'test', title: 'Test');
      await handler.addQueueItem(mediaItem);
      
      // Ensure handler is working
      expect(handler.queue.nvalue?.length, 1);
      
      // Dispose should not throw
      await handler.dispose();
      
      // Further operations should be handled gracefully
      // Note: In a real implementation, disposed handlers might throw or ignore operations
    });
  });
}

/// Backwards compatible extensions on rxdart's ValueStream
extension _ValueStreamExtension<T> on ValueStream<T> {
  /// Backwards compatible version of valueOrNull.
  T? get nvalue => hasValue ? value : null;
}
