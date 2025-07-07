import 'package:flutter/material.dart';

class TermsOfServiceScreen extends StatelessWidget {
  const TermsOfServiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terms of Service'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Terms of Service for LTunes',
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
              'Acceptance of Terms',
              'By downloading, installing, or using LTunes ("the App"), you agree to be bound by these Terms of Service ("Terms"). If you do not agree to these Terms, do not use the App.',
            ),
            
            _buildSection(
              context,
              'Description of Service',
              'LTunes is a music player application that allows users to:\n\n• Search for and stream music\n• Create and manage playlists\n• Download music for offline listening\n• Import local music files\n• Listen to radio stations',
            ),
            
            _buildSection(
              context,
              'User Responsibilities',
              'You are responsible for your use of the App and any content you access or download.',
            ),
            
            _buildSubsection(
              context,
              'Acceptable Use',
              [
                'Use the App only for lawful purposes and in accordance with these Terms',
                'Respect intellectual property rights of music creators and copyright holders',
                'Do not use the App to violate any laws or regulations',
                'Do not attempt to reverse engineer or modify the App',
                'Do not use the App to transmit harmful, offensive, or inappropriate content',
              ],
            ),
            
            _buildSubsection(
              context,
              'Prohibited Activities',
              [
                'Using the App for commercial purposes without permission',
                'Attempting to gain unauthorized access to our systems',
                'Interfering with the App\'s functionality or other users\' experience',
                'Sharing your account or credentials with others',
                'Using automated tools to access the App',
              ],
              isNegative: true,
            ),
            
            _buildSection(
              context,
              'Intellectual Property',
              'The App and its content are protected by intellectual property laws.',
            ),
            
            _buildSubsection(
              context,
              'App Ownership',
              [
                'LTunes and its original content, features, and functionality are owned by us',
                'The App is licensed, not sold, to you for use strictly in accordance with these Terms',
                'You may not copy, modify, distribute, sell, or lease any part of the App',
              ],
            ),
            
            _buildSubsection(
              context,
              'Music Content',
              [
                'Music content is provided by third-party services and is subject to their terms',
                'We do not own or control the music content available through the App',
                'You are responsible for ensuring you have the right to access and use music content',
              ],
            ),
            
            _buildSection(
              context,
              'Privacy and Data',
              'Your privacy is important to us. Please review our Privacy Policy, which also governs your use of the App.',
            ),
            
            _buildSubsection(
              context,
              'Data Collection',
              [
                'We collect minimal data necessary to provide the App\'s functionality',
                'All data is stored locally on your device',
                'We do not collect personal identification information',
                'You can control your data through app settings',
              ],
            ),
            
            _buildSection(
              context,
              'Service Availability',
              'We strive to provide reliable service but cannot guarantee uninterrupted access.',
            ),
            
            _buildSubsection(
              context,
              'Service Modifications',
              [
                'We may modify, suspend, or discontinue the App at any time',
                'We will provide reasonable notice of significant changes when possible',
                'Your continued use of the App after changes constitutes acceptance of new terms',
              ],
            ),
            
            _buildSubsection(
              context,
              'Third-Party Services',
              [
                'The App relies on third-party music APIs and services',
                'We are not responsible for the availability or content of third-party services',
                'Third-party services have their own terms of service and privacy policies',
              ],
            ),
            
            _buildSection(
              context,
              'Limitation of Liability',
              'To the maximum extent permitted by law, we shall not be liable for any indirect, incidental, special, consequential, or punitive damages.',
            ),
            
            _buildSubsection(
              context,
              'Disclaimer of Warranties',
              [
                'The App is provided "as is" without warranties of any kind',
                'We do not guarantee that the App will be error-free or uninterrupted',
                'We do not guarantee the accuracy or completeness of music information',
              ],
            ),
            
            _buildSubsection(
              context,
              'Limitation of Damages',
              [
                'Our total liability shall not exceed the amount you paid for the App (if any)',
                'We are not liable for any damages arising from your use of third-party content',
                'We are not liable for any damages caused by unauthorized access to your device',
              ],
            ),
            
            _buildSection(
              context,
              'Indemnification',
              'You agree to indemnify and hold us harmless from any claims, damages, or expenses arising from your use of the App or violation of these Terms.',
            ),
            
            _buildSection(
              context,
              'Termination',
              'We may terminate or suspend your access to the App immediately, without prior notice, for any reason.',
            ),
            
            _buildSubsection(
              context,
              'Termination by You',
              [
                'You may stop using the App at any time',
                'You can delete the App and all associated data from your device',
                'These Terms will continue to apply to your past use of the App',
              ],
            ),
            
            _buildSubsection(
              context,
              'Termination by Us',
              [
                'We may terminate access for violations of these Terms',
                'We may terminate service for technical or business reasons',
                'Upon termination, your right to use the App ceases immediately',
              ],
            ),
            
            _buildSection(
              context,
              'Governing Law',
              'These Terms shall be governed by and construed in accordance with the laws of the jurisdiction in which we operate, without regard to conflict of law principles.',
            ),
            
            _buildSection(
              context,
              'Dispute Resolution',
              'Any disputes arising from these Terms or your use of the App shall be resolved through binding arbitration or small claims court.',
            ),
            
            _buildSection(
              context,
              'Changes to Terms',
              'We reserve the right to modify these Terms at any time. We will notify users of significant changes through the App or other reasonable means.',
            ),
            
            _buildSubsection(
              context,
              'Notification of Changes',
              [
                'We will post updated Terms in the App',
                'Continued use after changes constitutes acceptance',
                'You can review the current Terms at any time in the App settings',
              ],
            ),
            
            _buildSection(
              context,
              'Severability',
              'If any provision of these Terms is found to be unenforceable, the remaining provisions will continue in full force and effect.',
            ),
            
            _buildSection(
              context,
              'Entire Agreement',
              'These Terms constitute the entire agreement between you and us regarding the App and supersede all prior agreements and understandings.',
            ),
            
            _buildSection(
              context,
              'International Use',
              'The App may be available in multiple countries. You are responsible for compliance with local laws and regulations in your jurisdiction.',
            ),
            
            const SizedBox(height: 32),
            Center(
              child: Text(
                'Thank you for using LTunes! 🎵',
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