# ProGuard rules for just_audio 10.x and audio_service
# These rules ensure that audio playback functionality is preserved during code obfuscation

# Keep just_audio classes and methods
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.just_audio.** { *; }

# Keep audio session classes
-keep class androidx.media.** { *; }
-keep class android.media.** { *; }

# Keep MediaBrowserService and related classes
-keep class android.service.media.MediaBrowserService { *; }
-keep class android.media.browse.MediaBrowser { *; }
-keep class android.media.session.MediaSession { *; }

# Keep notification classes used by audio_service
-keep class androidx.core.app.NotificationCompat** { *; }
-keep class android.app.Notification** { *; }

# Keep reflection-based access to audio classes
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# Keep native method names
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep parcelable classes
-keep class * extends android.os.Parcelable {
    public static final android.os.Parcelable$Creator *;
}

# Keep service classes
-keep class * extends android.app.Service
-keep class * extends androidx.media.MediaBrowserServiceCompat

# Keep MediaMetadata and MediaDescription classes
-keep class android.media.MediaMetadata { *; }
-keep class android.media.MediaDescription { *; }

# Keep audio focus and session callback classes
-keep class android.media.AudioManager** { *; }
-keep class android.media.AudioAttributes** { *; }

# Prevent obfuscation of audio-related enums and constants
-keep class com.ryanheise.just_audio.AudioLoadConfiguration { *; }
-keep class com.ryanheise.just_audio.AudioPipeline { *; }
-keep class com.ryanheise.just_audio.AudioSource { *; }

# Keep ExoPlayer classes (used internally by just_audio)
-keep class com.google.android.exoplayer2.** { *; }
-dontwarn com.google.android.exoplayer2.**

# Keep Kotlin coroutine classes used by just_audio
-keep class kotlin.coroutines.Continuation
-keep class kotlinx.coroutines.** { *; }

# Keep HTTP client classes for streaming
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-dontwarn okhttp3.**
-dontwarn okio.**



