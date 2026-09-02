import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_info.dart';
import '../../widgets/brand_mark.dart';
import 'setting_anchors.dart';
import 'setting_highlight.dart';

/// Where the licence text lives, for the About row that offers to show it.
const String _kLicenseUrl =
    'https://github.com/Ansh99999/Maichat/blob/main/LICENSE';

/// App version, licence, and the plain truth about where data lives. Storage
/// *usage* moved to its own Settings ▸ Storage section; About keeps only the
/// version, the licence row and the one-line privacy note.
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
              subtitle: Text('A mobile-first AI chat frontend.'),
              trailing: Text(version),
            ),
          ),
          const Divider(height: 8),
          ListTile(
            // The GPL asks that the people running the program be told what
            // they are running under, so the notice lives in the app and not
            // only in the repository.
            leading: const Icon(Icons.balance_outlined),
            title: const Text('Licence'),
            subtitle: Text(
              'Free software under the GNU General Public License v3. '
              'No warranty. Tap to read it.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            onTap: () => launchUrl(
              Uri.parse(_kLicenseUrl),
              mode: LaunchMode.externalApplication,
            ),
          ),
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
