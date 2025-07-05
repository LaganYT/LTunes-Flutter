import 'package:flutter/material.dart';
import '../services/error_handler_service.dart';

class AppErrorWidget extends StatelessWidget {
  final dynamic error;
  final String? title;
  final VoidCallback? onRetry;
  final IconData? icon;
  final String? customMessage;
  final bool showDetails;

  const AppErrorWidget({
    super.key,
    required this.error,
    this.title,
    this.onRetry,
    this.icon,
    this.customMessage,
    this.showDetails = false,
  });

  @override
  Widget build(BuildContext context) {
    return ErrorHandlerService().buildErrorWidget(
      context,
      error,
      title: title,
      onRetry: onRetry,
      icon: icon,
      customMessage: customMessage,
    );
  }
}

class AppLoadingErrorWidget extends StatelessWidget {
  final dynamic error;
  final String? title;
  final VoidCallback? onRetry;

  const AppLoadingErrorWidget({
    super.key,
    required this.error,
    this.title,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return ErrorHandlerService().buildLoadingErrorWidget(
      context,
      error,
      title: title,
      onRetry: onRetry,
    );
  }
}

class AppNetworkErrorWidget extends StatelessWidget {
  final VoidCallback? onRetry;

  const AppNetworkErrorWidget({
    super.key,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return ErrorHandlerService().buildNetworkErrorWidget(
      context,
      onRetry: onRetry,
    );
  }
}

class AppEmptyStateWidget extends StatelessWidget {
  final String title;
  final String message;
  final IconData? icon;
  final VoidCallback? onAction;
  final String? actionText;

  const AppEmptyStateWidget({
    super.key,
    required this.title,
    required this.message,
    this.icon,
    this.onAction,
    this.actionText,
  });

  @override
  Widget build(BuildContext context) {
    return ErrorHandlerService().buildEmptyStateWidget(
      context,
      title: title,
      message: message,
      icon: icon,
      onAction: onAction,
      actionText: actionText,
    );
  }
}

class AppErrorSnackBar extends StatelessWidget {
  final dynamic error;
  final String? errorContext;
  final VoidCallback? onRetry;

  const AppErrorSnackBar({
    super.key,
    required this.error,
    this.errorContext,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    // This widget doesn't actually build anything visible
    // It's used to show a snackbar when the widget is created
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ErrorHandlerService().showErrorSnackBar(
        context,
        error,
        errorContext: errorContext,
      );
    });
    return const SizedBox.shrink();
  }
} 