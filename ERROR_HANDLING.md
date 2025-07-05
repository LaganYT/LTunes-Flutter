# Error Handling System

This document explains how to use the centralized error handling system in LTunes.

## Overview

The error handling system provides consistent error messages and user-friendly error displays throughout the app. It includes:

- **ErrorHandlerService**: Central service for error handling
- **Error Widgets**: Reusable widgets for displaying errors
- **Error Logging**: Centralized error logging for debugging

## Error Types

The system recognizes several error types:

- `network_error`: Connection issues
- `api_error`: Server/API problems
- `file_error`: File access issues
- `audio_error`: Audio playback problems
- `download_error`: Download failures
- `permission_error`: Permission issues
- `unknown_error`: Unrecognized errors

## Usage Examples

### 1. Using ErrorHandlerService directly

```dart
import '../services/error_handler_service.dart';

class MyScreen extends StatefulWidget {
  final ErrorHandlerService _errorHandler = ErrorHandlerService();

  Future<void> _loadData() async {
    try {
      // Your async operation
      final data = await apiService.fetchData();
    } catch (e) {
      _errorHandler.logError(e, context: 'loadData');
      if (mounted) {
        _errorHandler.showErrorSnackBar(context, e, errorContext: 'loading data');
      }
    }
  }
}
```

### 2. Using Error Widgets in FutureBuilder

```dart
FutureBuilder<List<Song>>(
  future: _songsFuture,
  builder: (context, snapshot) {
    if (snapshot.hasError) {
      return _errorHandler.buildLoadingErrorWidget(
        context,
        snapshot.error!,
        title: 'Failed to Load Songs',
        onRetry: () {
          setState(() {
            _songsFuture = _getSongsFuture();
          });
        },
      );
    }
    // ... rest of your widget
  },
)
```

### 3. Using Reusable Error Widgets

```dart
import '../widgets/error_widget.dart';

// For loading errors
AppLoadingErrorWidget(
  error: error,
  title: 'Failed to Load Data',
  onRetry: () => _retry(),
)

// For network errors
AppNetworkErrorWidget(
  onRetry: () => _retry(),
)

// For empty states
AppEmptyStateWidget(
  title: 'No Songs Found',
  message: 'Try searching for something else.',
  icon: Icons.search_off,
  onAction: () => _search(),
  actionText: 'Search',
)
```

### 4. Error Dialog

```dart
_errorHandler.showErrorDialog(
  context,
  error,
  title: 'Operation Failed',
  onRetry: () {
    // Retry logic
  },
  onDismiss: () {
    // Dismiss logic
  },
);
```

### 5. Error with Retry Mechanism

```dart
final result = await _errorHandler.handleWithRetry(
  operation: () => apiService.fetchData(),
  context: context,
  maxRetries: 3,
  delay: Duration(seconds: 1),
  errorContext: 'fetching data',
);
```

## Error Widgets

### AppErrorWidget
General purpose error widget with customizable title, message, and retry action.

### AppLoadingErrorWidget
Specifically for loading errors in FutureBuilder scenarios.

### AppNetworkErrorWidget
For network connectivity issues.

### AppEmptyStateWidget
For when no data is available (not necessarily an error).

### AppErrorSnackBar
Widget that shows an error snackbar when created.

## Best Practices

1. **Always log errors**: Use `_errorHandler.logError()` for debugging
2. **Check mounted state**: Ensure widget is still mounted before showing UI
3. **Provide retry actions**: Give users a way to recover from errors
4. **Use appropriate error types**: Choose the right error widget for the situation
5. **Don't show errors for non-critical operations**: Like update checks

## Error Messages

The system provides user-friendly error messages:

- Network errors: "Connection failed. Please check your internet connection and try again."
- API errors: "Unable to fetch data from the server. Please try again later."
- File errors: "Unable to access file. The file may be corrupted or missing."
- Audio errors: "Unable to play audio. Please try again."
- Download errors: "Download failed. Please check your connection and try again."
- Permission errors: "Permission denied. Please grant the required permissions."

## Customization

You can customize error messages and actions by:

1. Modifying the `_errorMessages` and `_errorActions` maps in `ErrorHandlerService`
2. Using the `customMessage` parameter in error widgets
3. Creating custom error widgets that extend the base functionality

## Integration with Existing Code

The error handling system has been integrated into:

- Search Screen: Error handling for song and radio station loading
- Artist Screen: Error handling for artist data loading
- Song Detail Screen: Error handling for various operations
- API Service: Centralized error logging
- Current Song Provider: Error handling for audio operations

This provides a consistent error experience across the entire app. 