import 'package:flutter/material.dart';
import '../services/bug_report_service.dart';

class BugReportDialog extends StatefulWidget {
  const BugReportDialog({super.key});

  @override
  State<BugReportDialog> createState() => _BugReportDialogState();
}

class _BugReportDialogState extends State<BugReportDialog> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  final _emailController = TextEditingController();
  bool _isLoading = false;
  bool _includeLogs = true;
  bool _includeDeviceInfo = true;

  @override
  void dispose() {
    _descriptionController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.bug_report,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 8),
          const Text('Report a Bug'),
        ],
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Help us improve LTunes by reporting bugs and issues.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.7),
                    ),
              ),
              const SizedBox(height: 16),

              // Description field
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Describe the bug (optional)',
                  hintText: 'What happened? What did you expect to happen?',
                  border: OutlineInputBorder(),
                ),
                maxLines: 4,
                maxLength: 2000,
                validator: (value) {
                  if (value != null &&
                      value.trim().isNotEmpty &&
                      value.trim().length < 10) {
                    return 'Please provide more details (at least 10 characters)';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Email field (optional)
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Your email (optional)',
                  hintText: 'We can contact you for more details',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.emailAddress,
                validator: (value) {
                  if (value != null && value.isNotEmpty) {
                    if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$')
                        .hasMatch(value)) {
                      return 'Please enter a valid email address';
                    }
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Options
              Text(
                'Include in report:',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),

              CheckboxListTile(
                title: const Text('App logs'),
                subtitle: const Text('Recent app activity and errors'),
                value: _includeLogs,
                onChanged: (value) {
                  setState(() {
                    _includeLogs = value ?? true;
                  });
                },
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),

              CheckboxListTile(
                title: const Text('Device information'),
                subtitle: const Text('App version, OS, device details'),
                value: _includeDeviceInfo,
                onChanged: (value) {
                  setState(() {
                    _includeDeviceInfo = value ?? true;
                  });
                },
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),

              const SizedBox(height: 16),

              // Privacy notice
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceVariant
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.privacy_tip_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Your report will be sent to our development team. No personal data is collected.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          onPressed: _isLoading ? null : _submitBugReport,
          icon: _isLoading
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                )
              : const Icon(Icons.send),
          label: Text(_isLoading ? 'Sending...' : 'Send Report'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
          ),
        ),
      ],
    );
  }

  Future<void> _submitBugReport() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // Log the bug report attempt
      BugReportService().logUserAction('Bug report submitted', data: {
        'has_email': _emailController.text.isNotEmpty,
        'include_logs': _includeLogs,
        'include_device_info': _includeDeviceInfo,
        'description_length': _descriptionController.text.length,
      });

      // Prepare additional data
      final additionalData = <String, dynamic>{
        'include_logs': _includeLogs,
        'include_device_info': _includeDeviceInfo,
        'submitted_at': DateTime.now().toIso8601String(),
      };

      // Send the bug report
      final success = await BugReportService().sendBugReport(
        userDescription: _descriptionController.text.trim(),
        userEmail: _emailController.text.trim().isNotEmpty
            ? _emailController.text.trim()
            : null,
        additionalData: additionalData,
      );

      if (mounted) {
        Navigator.of(context).pop();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  success ? Icons.check_circle : Icons.error,
                  color: success
                      ? Colors.green
                      : Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    success
                        ? 'Bug report sent successfully! Thank you for your feedback.'
                        : 'Failed to send bug report. Please try again later.',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
              ],
            ),
            backgroundColor: success
                ? Colors.green.withValues(alpha: 0.1)
                : Theme.of(context).colorScheme.errorContainer,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  Icons.error,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                const Text('An error occurred while sending the report.'),
              ],
            ),
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: 'Retry',
              onPressed: _submitBugReport,
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }
}

/// Show bug report dialog
Future<void> showBugReportDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (context) => const BugReportDialog(),
  );
}
