import 'package:flutter/material.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Privacy Policy'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Privacy Policy for LTunes',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Last updated: July 2025',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 24),
            
            _buildSection(
              context,
              'Introduction',
              'LTunes ("we," "our," or "us") is committed to protecting your privacy. This Privacy Policy explains our approach to privacy: we do not collect any data from you. All information is stored locally on your device.',
            ),
            
            _buildSection(
              context,
              'Information We Collect',
              'We do not collect any personal information or data from you. All data is stored locally on your device.',
            ),
            
            _buildSubsection(
              context,
              'No Data Collection',
              [
                'We do not collect any personal information',
                'We do not collect device identifiers',
                'We do not collect usage statistics',
                'We do not collect any analytics data',
              ],
            ),
            
            _buildSubsection(
              context,
              'Local Data Storage',
              [
                'Search Queries: Your music search queries are processed locally and not stored',
                'Playlist Data: Playlists you create are stored locally on your device only',
                'Downloaded Music: Music files you download are stored locally on your device only',
                'Settings: All app settings are stored locally on your device',
              ],
            ),
            
            _buildSubsection(
              context,
              'No Personal Data Collection',
              [
                'Personal identification information (name, email, phone number)',
                'Location data',
                'Contact information',
                'Payment information',
              ],
              isNegative: true,
            ),
            
            _buildSection(
              context,
              'How We Use Your Information',
              'Since we do not collect any data, there is no information to use. All app functionality operates locally on your device.',
            ),
            
            _buildSubsection(
              context,
              'Local App Functionality',
              [
                'Provide music search and playback services',
                'Enable playlist creation and management',
                'Support offline music downloads',
                'All processing happens locally on your device',
              ],
            ),
            
            _buildSection(
              context,
              'Data Storage and Security',
              'We prioritize the security and privacy of your data:',
            ),
            
            _buildSubsection(
              context,
              'Local Storage',
              [
                'All user data (playlists, downloaded music, settings) is stored locally on your device',
                'We do not have access to your local files or data',
              ],
            ),
            
            _buildSubsection(
              context,
              'Network Security',
              [
                'All API communications use HTTPS encryption',
                'We do not store or transmit personal information',
              ],
            ),
            
            _buildSection(
              context,
              'Third-Party Services',
              'We work with trusted third-party services for music content only:',
            ),
            
            _buildSubsection(
              context,
              'Music API',
              [
                'We use third-party music APIs to provide search and streaming functionality',
                'These services have their own privacy policies',
                'We do not share any of your data with these services',
              ],
            ),
            
            
            _buildSection(
              context,
              'Your Rights',
              'You have control over your data and privacy:',
            ),
            
            _buildSubsection(
              context,
              'Data Control',
              [
                'You can delete all app data by uninstalling the app',
                'You can clear downloaded music through app settings',
                'You can reset app settings to default values',
              ],
            ),
            
            _buildSubsection(
              context,
              'Data Control',
              [
                'You can delete all app data by uninstalling the app',
                'You can clear downloaded music through app settings',
                'You can reset app settings to default values',
                'All data is stored locally and under your control',
              ],
            ),
            
            _buildSection(
              context,
              'Age Requirements',
              'There are no age restrictions for using LTunes. The app is suitable for users of all ages.',
            ),
            
            _buildSection(
              context,
              'Changes to This Policy',
              'We may update this Privacy Policy from time to time. We will notify you of any changes by posting the new Privacy Policy in the app.',
            ),
            
            _buildSection(
              context,
              'Legal Basis (GDPR)',
              'For users in the European Union: Since we do not collect or process any personal data, GDPR requirements do not apply to our app. All data remains on your device.',
            ),
            
            _buildSection(
              context,
              'California Privacy Rights (CCPA)',
              'For California residents: Since we do not collect, sell, or share any personal information, CCPA requirements do not apply to our app. All data remains on your device.',
            ),
            
            const SizedBox(height: 32),
            Center(
              child: Text(
                'LTunes - Your music, your privacy. 🎵',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(BuildContext context, String title, String content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          content,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }

  Widget _buildSubsection(BuildContext context, String title, List<String> items, {bool isNegative = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: isNegative 
                ? Theme.of(context).colorScheme.error 
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        ...items.map((item) => Padding(
          padding: const EdgeInsets.only(left: 16.0, bottom: 4.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isNegative ? '• ' : '• ',
                style: TextStyle(
                  color: isNegative 
                      ? Theme.of(context).colorScheme.error 
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
              Expanded(
                child: Text(
                  item,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: isNegative 
                        ? Theme.of(context).colorScheme.error 
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        )),
      ],
    );
  }
} 