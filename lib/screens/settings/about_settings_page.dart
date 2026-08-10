import 'package:flutter/material.dart';

import 'setting_anchors.dart';
import 'setting_highlight.dart';

/// App version and the plain truth about where data lives.
class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key, this.highlight});

  final SettingAnchor? highlight;

  /// Kept in step with the `version:` line in pubspec.yaml.
  static const String version = '1.2.0';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          8,
          8,
          8,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          SettingHighlight(
            active: highlight == SettingAnchor.version,
            child: const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('MaiChat'),
              subtitle: Text('A minimal OpenAI-compatible chat client.'),
              trailing: Text(version),
            ),
          ),
          const Divider(height: 8),
          SettingHighlight(
            active: highlight == SettingAnchor.storage,
            child: ListTile(
              leading: const Icon(Icons.sd_storage_outlined),
              title: const Text('Storage'),
              subtitle: Text(
                'Settings and chats are stored in this app\'s private storage '
                'on the device, unencrypted. Use a scoped key you can revoke.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
