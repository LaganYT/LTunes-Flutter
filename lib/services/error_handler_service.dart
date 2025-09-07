import 'package:flutter/material.dart';
import 'dart:io';
import 'bug_report_service.dart';

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
  static const String storageError = 'storage_error';
  static const String unknownError = 'unknown_error';

  // Error messages with more specific descriptions
  static const Map<String, String> _errorMessages = {
    networkError:
        'Connection failed. Please check your internet connection and try again.',
    apiError: 'Server error. Please try again later.',
    fileError: 'Unable to access file. The file may be corrupted or missing.',
    audioError: 'Unable to play audio. Please try again.',
    downloadError:
        'Download failed. Please check your connection and try again.',
    permissionError:
        'Permission denied. Please grant the required permissions.',
    storageError: 'Storage error. Please check available space and try again.',
    unknownError: 'An unexpected error occurred. Please try again.',
  };

  // Error actions with recovery strategies
  static const Map<String, String> _errorActions = {
    networkError: 'Retry',
    apiError: 'Retry',
    fileError: 'OK',
    audioError: 'Retry',
    downloadError: 'Retry',
    permissionError: 'Settings',
    storageError: 'OK',
    unknownError: 'OK',
  };

  // Error recovery strategies
  static const Map<String, List<String>> _recoveryStrategies = {
    networkError: ['retry', 'check_connection', 'wait'],
    apiError: ['retry', 'wait', 'check_server'],
    fileError: ['redownload', 'check_storage', 'clear_cache'],
    audioError: ['retry', 'check_audio_session', 'restart_app'],
    downloadError: ['retry', 'check_connection', 'check_storage'],
    permissionError: ['request_permission', 'open_settings'],
    storageError: ['clear_cache', 'free_space', 'check_storage'],
    unknownError: ['retry', 'restart_app'],
  };

  // Get user-friendly error message
  String getErrorMessage(dynamic error, {String? context}) {
    final errorType = getErrorType(error);
    String message = _errorMessages[errorType] ?? _errorMessages[unknownError]!;

    // Add context-specific information
    if (context != null) {
      message = '[$context] $message';
    }

    return message;
  }

  // Get error type with improved detection
  String getErrorType(dynamic error) {
    if (error == null) return unknownError;

    final errorString = error.toString().toLowerCase();

    // Network errors
    if (error is SocketException ||
        errorString.contains('socket') ||
        errorString.contains('connection') ||
        errorString.contains('timeout') ||
        errorString.contains('network')) {
      return networkError;
    }

    // File system errors
    if (error is FileSystemException ||
        errorString.contains('file') ||
        errorString.contains('directory') ||
        errorString.contains('path') ||
        errorString.contains('not found')) {
      return fileError;
    }

    // Permission errors
    if (errorString.contains('permission') ||
        errorString.contains('denied') ||
        errorString.contains('unauthorized')) {
      return permissionError;
    }

    // Download errors
    if (errorString.contains('download') ||
        errorString.contains('download failed') ||
        errorString.contains('download error')) {
      return downloadError;
    }

    // Audio errors
    if (errorString.contains('audio') ||
        errorString.contains('play') ||
        errorString.contains('media') ||
        errorString.contains('codec')) {
      return audioError;
    }

    // Storage errors
    if (errorString.contains('storage') ||
        errorString.contains('space') ||
        errorString.contains('disk') ||
        errorString.contains('memory')) {
      return storageError;
    }

    // API errors
    if (errorString.contains('api') ||
        errorString.contains('server') ||
        errorString.contains('http') ||
        errorString.contains('status')) {
      return apiError;
    }

    return unknownError;
  }

  // Get action text for error
  String getErrorAction(dynamic error) {
    final errorType = getErrorType(error);
    return _errorActions[errorType] ?? _errorActions[unknownError]!;
  }

  // Get recovery strategies for error
  List<String> getRecoveryStrategies(dynamic error) {
    final errorType = getErrorType(error);
    return _recoveryStrategies[errorType] ?? _recoveryStrategies[unknownError]!;
  }

  // Show error snackbar with improved UX
  void showErrorSnackBar(BuildContext context, dynamic error,
      {String? errorContext}) {
    final message = getErrorMessage(error, context: errorContext);
    final action = getErrorAction(error);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: action,
          onPressed: () => _handleErrorAction(context, error, action),
        ),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(8),
      ),
    );
  }

  // Show error dialog with recovery options
  void showErrorDialog(BuildContext context, dynamic error,
      {String? errorContext}) {
    final message = getErrorMessage(error, context: errorContext);
    final strategies = getRecoveryStrategies(error);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Error'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              const SizedBox(height: 16),
              if (strategies.isNotEmpty) ...[
                const Text('Recovery options:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ...strategies.map((strategy) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text('• ${_formatRecoveryStrategy(strategy)}'),
                    )),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
            if (strategies.contains('retry'))
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _handleErrorAction(context, error, 'Retry');
                },
                child: const Text('Retry'),
              ),
          ],
        );
      },
    );
  }

  // Show error widget for FutureBuilder
  Widget buildErrorWidget(
    BuildContext context,
    dynamic error, {
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
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.7),
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
  Widget buildLoadingErrorWidget(
    BuildContext context,
    dynamic error, {
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
  Widget buildNetworkErrorWidget(
    BuildContext context, {
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
  Widget buildEmptyStateWidget(
    BuildContext context, {
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
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.7),
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6),
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

  // Handle error actions
  void _handleErrorAction(BuildContext context, dynamic error, String action) {
    switch (action.toLowerCase()) {
      case 'retry':
        // Trigger retry logic - this would be implemented by the calling code
        break;
      case 'settings':
        // Open app settings
        _openAppSettings();
        break;
      case 'ok':
        // Do nothing, just dismiss
        break;
    }
  }

  // Open app settings
  void _openAppSettings() {
    // This would typically use a package like app_settings
    // For now, we'll just log the action
    debugPrint('Opening app settings...');
  }

  // Format recovery strategy for display
  String _formatRecoveryStrategy(String strategy) {
    switch (strategy) {
      case 'retry':
        return 'Try again';
      case 'check_connection':
        return 'Check your internet connection';
      case 'wait':
        return 'Wait a moment and try again';
      case 'check_server':
        return 'Check if the service is available';
      case 'redownload':
        return 'Download the file again';
      case 'check_storage':
        return 'Check available storage space';
      case 'clear_cache':
        return 'Clear app cache';
      case 'check_audio_session':
        return 'Check audio settings';
      case 'restart_app':
        return 'Restart the app';
      case 'request_permission':
        return 'Grant required permissions';
      case 'free_space':
        return 'Free up storage space';
      default:
        return strategy.replaceAll('_', ' ');
    }
  }

  // Log error for debugging
  void logError(dynamic error, {String? context, StackTrace? stackTrace}) {
    final errorType = getErrorType(error);
    final message = getErrorMessage(error, context: context);

    debugPrint('ErrorHandler: [$errorType] $message');
    if (stackTrace != null) {
      debugPrint('ErrorHandler: Stack trace: $stackTrace');
    }

    // Log to bug report service
    BugReportService()
        .logError(error, context: context, stackTrace: stackTrace);
  }

  // Check if error is recoverable
  bool isRecoverable(dynamic error) {
    final errorType = getErrorType(error);
    return errorType == networkError ||
        errorType == apiError ||
        errorType == downloadError ||
        errorType == audioError;
  }

  // Get error severity level
  String getErrorSeverity(dynamic error) {
    final errorType = getErrorType(error);

    switch (errorType) {
      case networkError:
      case apiError:
        return 'low'; // Temporary issues
      case fileError:
      case storageError:
        return 'medium'; // Data issues
      case permissionError:
        return 'high'; // User action required
      case audioError:
      case downloadError:
        return 'medium'; // Feature issues
      default:
        return 'unknown';
    }
  }

  // Suggest user action based on error
  String suggestUserAction(dynamic error) {
    final errorType = getErrorType(error);

    switch (errorType) {
      case networkError:
        return 'Check your internet connection and try again';
      case apiError:
        return 'The service may be temporarily unavailable. Please try again later';
      case fileError:
        return 'The file may be corrupted. Try downloading it again';
      case audioError:
        return 'Try restarting the app or check your audio settings';
      case downloadError:
        return 'Check your connection and available storage space';
      case permissionError:
        return 'Please grant the required permissions in app settings';
      case storageError:
        return 'Free up some storage space and try again';
      default:
        return 'Please try again or restart the app';
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
              errorContext: errorContext,
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
