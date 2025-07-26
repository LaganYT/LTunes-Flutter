import 'package:flutter/material.dart';
import 'dart:io';

class ErrorHandlerService {
  static final ErrorHandlerService _instance = ErrorHandlerService._internal();
  factory ErrorHandlerService() => _instance;
  ErrorHandlerService._internal();

  // Error types
  static const String networkError = 'network_error';
  static const String apiError = 'api_error';
  static const String fileError = 'file_error';
  static const String audioError = 'audio_error';
  static const String downloadError = 'download_error';
  static const String permissionError = 'permission_error';
  static const String unknownError = 'unknown_error';

  // Error messages
  static const Map<String, String> _errorMessages = {
    networkError: 'Connection failed. Please check your internet connection and try again.',
    fileError: 'Unable to access file. The file may be corrupted or missing.',
    audioError: 'Unable to play audio. Please try again.',
    downloadError: 'Download failed. Please check your connection and try again.',
    permissionError: 'Permission denied. Please grant the required permissions.',
    unknownError: 'An unexpected error occurred. Please try again.',
  };

  // Error actions
  static const Map<String, String> _errorActions = {
    networkError: 'Retry',
    fileError: 'OK',
    audioError: 'Retry',
    downloadError: 'Retry',
    permissionError: 'Settings',
    unknownError: 'OK',
  };

  // Get user-friendly error message
  String getErrorMessage(dynamic error, {String? context}) {
    if (error is SocketException) {
      return _errorMessages[networkError]!;
    } else if (error is FileSystemException) {
      return _errorMessages[fileError]!;
    } else if (error.toString().contains('permission')) {
      return _errorMessages[permissionError]!;
    } else if (error.toString().contains('download')) {
      return _errorMessages[downloadError]!;
    } else if (error.toString().contains('audio') || error.toString().contains('play')) {
      return _errorMessages[audioError]!;
    } else if (error.toString().contains('network') || error.toString().contains('connection')) {
      return _errorMessages[networkError]!;
    } else if (error.toString().contains('api') || error.toString().contains('server')) {
      return _errorMessages[apiError]!;
    }
    
    return _errorMessages[unknownError]!;
  }

  // Get error type
  String getErrorType(dynamic error) {
    if (error is SocketException) {
      return networkError;
    } else if (error is FileSystemException) {
      return fileError;
    } else if (error.toString().contains('permission')) {
      return permissionError;
    } else if (error.toString().contains('download')) {
      return downloadError;
    } else if (error.toString().contains('audio') || error.toString().contains('play')) {
      return audioError;
    } else if (error.toString().contains('network') || error.toString().contains('connection')) {
      return networkError;
    } else if (error.toString().contains('api') || error.toString().contains('server')) {
      return apiError;
    }
    
    return unknownError;
  }

  // Get action text for error
  String getErrorAction(dynamic error) {
    final errorType = getErrorType(error);
    return _errorActions[errorType]!;
  }

  // Show error snackbar
  void showErrorSnackBar(BuildContext context, dynamic error, {String? errorContext}) {
    final message = getErrorMessage(error, context: errorContext);
    final actionText = getErrorAction(error);
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
        action: SnackBarAction(
          label: actionText,
          textColor: Theme.of(context).colorScheme.onError,
          onPressed: () {
            // Handle retry or other actions
            if (actionText == 'Retry') {
              // Trigger retry logic - this would need to be passed as a callback
              debugPrint('Retry action triggered for error: $error');
            } else if (actionText == 'Settings') {
              // Open app settings
              _openAppSettings();
            }
          },
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // Show error dialog
  void showErrorDialog(BuildContext context, dynamic error, {
    String? title,
    VoidCallback? onRetry,
    VoidCallback? onDismiss,
  }) {
    final message = getErrorMessage(error);
    final actionText = getErrorAction(error);
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title ?? 'Error'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              const SizedBox(height: 8),
              if (error.toString().isNotEmpty)
                Text(
                  'Details: ${error.toString()}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
            ],
          ),
          actions: [
            if (actionText == 'Retry' && onRetry != null)
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  onRetry();
                },
                child: Text(actionText),
              ),
            if (actionText == 'Settings')
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _openAppSettings();
                },
                child: Text(actionText),
              ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                onDismiss?.call();
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  // Show error widget for FutureBuilder
  Widget buildErrorWidget(BuildContext context, dynamic error, {
    String? title,
    VoidCallback? onRetry,
    IconData? icon,
    String? customMessage,
  }) {
    final message = customMessage ?? getErrorMessage(error);
    final actionText = getErrorAction(error);
    
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon ?? Icons.error_outline,
              size: 64,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              title ?? 'Error',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 24),
            if (actionText == 'Retry' && onRetry != null)
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(actionText),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            if (actionText == 'Settings')
              ElevatedButton.icon(
                onPressed: _openAppSettings,
                icon: const Icon(Icons.settings),
                label: Text(actionText),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.secondary,
                  foregroundColor: Theme.of(context).colorScheme.onSecondary,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Show loading error widget
  Widget buildLoadingErrorWidget(BuildContext context, dynamic error, {
    String? title,
    VoidCallback? onRetry,
  }) {
    return buildErrorWidget(
      context,
      error,
      title: title ?? 'Failed to Load',
      onRetry: onRetry,
      icon: Icons.cloud_off,
    );
  }

  // Show network error widget
  Widget buildNetworkErrorWidget(BuildContext context, {
    VoidCallback? onRetry,
  }) {
    return buildErrorWidget(
      context,
      const SocketException('No internet connection'),
      title: 'No Internet Connection',
      onRetry: onRetry,
      icon: Icons.wifi_off,
      customMessage: 'Please check your internet connection and try again.',
    );
  }

  // Show empty state widget
  Widget buildEmptyStateWidget(BuildContext context, {
    required String title,
    required String message,
    IconData? icon,
    VoidCallback? onAction,
    String? actionText,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon ?? Icons.inbox_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            if (onAction != null && actionText != null) ...[
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.refresh),
                label: Text(actionText),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // Open app settings
  void _openAppSettings() {
    // This would typically open the app's settings page
    // For now, we'll just log it
    debugPrint('Opening app settings...');
  }

  // Log error for debugging
  void logError(dynamic error, {String? context, StackTrace? stackTrace}) {
    debugPrint('Error in $context: $error');
    if (stackTrace != null) {
      debugPrint('StackTrace: $stackTrace');
    }
  }

  // Handle error with retry mechanism
  Future<T?> handleWithRetry<T>({
    required Future<T> Function() operation,
    required BuildContext context,
    int maxRetries = 3,
    Duration delay = const Duration(seconds: 1),
    String? errorContext,
  }) async {
    int attempts = 0;
    
    while (attempts < maxRetries) {
      try {
        return await operation();
      } catch (error) {
        attempts++;
        logError(error, context: errorContext);
        
        if (attempts >= maxRetries) {
          if (context.mounted) {
            showErrorDialog(
              context,
              error,
              title: 'Operation Failed',
              onRetry: () {
                // This would restart the operation
                debugPrint('Retry requested for: $errorContext');
              },
            );
          }
          return null;
        }
        
        // Wait before retrying
        await Future.delayed(delay * attempts);
      }
    }
    
    return null;
  }
} 