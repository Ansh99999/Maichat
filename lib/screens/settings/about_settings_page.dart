import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../widgets/brand_mark.dart';
import 'setting_anchors.dart';
import 'setting_highlight.dart';

/// App version and the plain truth about where data lives. Storage *usage* moved
/// to its own Settings ▸ Storage section; About keeps only the version and the
/// one-line privacy note.
class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key, this.highlight});

  final SettingAnchor? highlight;

  /// Kept in step with the `version:` line in pubspec.yaml.
  static const String version = kAppVersion;

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
              // The row that *is* the app's identity card: the mark stands in
              // for the generic info glyph.
              leading: MaiChatMark(),
              title: Text(kMaiChatName),
              subtitle: Text('A minimal OpenAI-compatible chat client.'),
              trailing: Text(version),
            ),
          ),
          const Divider(height: 8),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Data & privacy'),
            subtitle: Text(
              'Settings and chats are stored in this app\'s private storage '
              'on the device, unencrypted. Use a scoped key you can revoke. '
              'See Settings ▸ Storage to manage what is stored.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
