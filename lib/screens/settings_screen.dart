import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'backups/backups_screen.dart';
import 'backups/backup_import_screen.dart';
import 'backups/drive_settings_page.dart';
import 'chats_screen.dart' show relativeTime;
import 'settings/about_settings_page.dart';
import 'settings/appearance_settings_page.dart';
import 'settings/chat_interface_settings_page.dart';
import 'providers/providers_screen.dart';
import 'settings/setting_anchors.dart';
import 'settings/storage_settings_page.dart';
import 'settings/tokenizer_settings_page.dart';

/// The settings hub, laid out the Android way: a search bar that jumps to any
/// individual setting, then a short list of sections you drill into.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: EdgeInsets.only(bottom: 16 + bottom),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: const _SettingsSearch(),
          ),
          _SectionTile(
            icon: Icons.dns_outlined,
            title: 'Providers',
            subtitle: _providerSummary(state),
            onTap: () => _open(context, const ProvidersScreen()),
          ),
          _SectionTile(
            icon: Icons.palette_outlined,
            title: 'Appearance',
            subtitle: _appearanceSummary(state),
            onTap: () => _open(context, const AppearanceSettingsPage()),
          ),
          _SectionTile(
            icon: Icons.chat_bubble_outline,
            title: 'Chat Interface',
            subtitle: _chatInterfaceSummary(state),
            onTap: () => _open(context, const ChatInterfaceSettingsPage()),
          ),
          _SectionTile(
            icon: Icons.sd_storage_outlined,
            title: 'Storage',
            subtitle: 'Images, chats and cached data',
            onTap: () => _open(context, const StorageSettingsPage()),
          ),
          _SectionTile(
            icon: Icons.backup_outlined,
            title: 'Backups',
            subtitle: _backupSummary(state),
            onTap: () => _open(context, const BackupsScreen()),
          ),
          _SectionTile(
            icon: Icons.info_outline,
            title: 'About',
            subtitle: 'Version ${AboutSettingsPage.version}',
            onTap: () => _open(context, const AboutSettingsPage()),
          ),
        ],
      ),
    );
  }

  static String _providerSummary(AppState state) {
    final active = state.activeProvider;
    if (active == null) return 'Not set up yet';
    final count = state.providers.length;
    final suffix = count > 1 ? ' · +${count - 1} more' : '';
    final model = active.model.trim();
    final label = model.isEmpty
        ? '${active.displayName} · no model'
        : '${active.displayName} · $model';
    return '$label$suffix';
  }

  static String _appearanceSummary(AppState state) {
    final a = state.appearance;
    return a.dynamicColor
        ? '${a.mode.label} · System colours'
        : a.mode.label;
  }

  static String _chatInterfaceSummary(AppState state) {    final ui = state.chatInterface;
    final style = ui.bubbles ? 'Bubbles' : 'Document';
    final avatars = (ui.botAvatar.show || ui.userAvatar.show)
        ? 'avatars on'
        : 'no avatars';
    return '$style · $avatars · ${ui.textPlacement.label}';
  }

  static String _backupSummary(AppState state) {
    final stats = state.backupStats;
    final newest = stats.newest;
    if (newest == null) {
      return state.backupPrefs.automatic
          ? '${state.backupPrefs.schedule.label} · none taken yet'
          : 'Export and import everything';
    }
    final count = '${stats.count} ${stats.count == 1 ? 'backup' : 'backups'}';
    return '$count · newest ${relativeTime(newest)}';
  }

  static void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }
}

/// A top-level category row: tinted icon, title, current-value summary and the
/// chevron that says "there is more inside".
class _SectionTile extends StatelessWidget {
  const _SectionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: scheme.onSecondaryContainer, size: 22),
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// One searchable setting: what it is called, where it lives, and how to reach
/// it. [keywords] are extra words a user might type that are not in [title].
class _SearchEntry {
  const _SearchEntry({
    required this.title,
    required this.section,
    required this.icon,
    required this.keywords,
    required this.builder,
  });

  final String title;
  final String section;
  final IconData icon;
  final String keywords;
  final Widget Function() builder;

  bool matches(String needle) =>
      title.toLowerCase().contains(needle) ||
      section.toLowerCase().contains(needle) ||
      keywords.toLowerCase().contains(needle);
}

/// Every individual setting, flattened so search can jump straight to it — the
/// destination page flashes the row via [SettingAnchor].
const List<_SearchEntry> _searchIndex = [
  _SearchEntry(
    title: 'Provider name',
    section: 'Providers',
    icon: Icons.badge_outlined,
    keywords: 'label title rename friendly',
    builder: _providersPage,
  ),
  _SearchEntry(
    title: 'API format',
    section: 'Providers',
    icon: Icons.swap_horiz,
    keywords: 'type openai compatible anthropic claude style wire protocol',
    builder: _providersPage,
  ),
  _SearchEntry(
    title: 'Base URL',
    section: 'Providers',
    icon: Icons.link,
    keywords: 'endpoint server host address api openai compatible v1',
    builder: _providersPage,
  ),
  _SearchEntry(
    title: 'API key',
    section: 'Providers',
    icon: Icons.key_outlined,
    keywords: 'token secret credential auth bearer password',
    builder: _providersPage,
  ),
  _SearchEntry(
    title: 'Model',
    section: 'Providers',
    icon: Icons.memory_outlined,
    keywords: 'gpt claude llm chat completion browse',
    builder: _providersPage,
  ),
  _SearchEntry(
    title: 'Tokenizer',
    section: 'Providers',
    icon: Icons.calculate_outlined,
    keywords: 'token count tokenizer tiktoken openai anthropic claude bpe '
        'cl100k o200k context window encoding custom',
    builder: _tokenizerPage,
  ),
  _SearchEntry(
    title: 'Theme',
    section: 'Appearance',
    icon: Icons.brightness_6_outlined,
    keywords: 'dark light night system mode brightness',
    builder: _themePage,
  ),
  _SearchEntry(
    title: 'Use system colours',
    section: 'Appearance',
    icon: Icons.palette_outlined,
    keywords: 'material you dynamic color colour wallpaper palette',
    builder: _systemColoursPage,
  ),
  _SearchEntry(
    title: 'App font',
    section: 'Appearance',
    icon: Icons.font_download_outlined,
    keywords: 'font typeface google fonts family typography text',
    builder: _fontPage,
  ),
  _SearchEntry(
    title: 'Avatars',
    section: 'Chat Interface',
    icon: Icons.account_circle_outlined,
    keywords: 'avatar size shape corners circle square fit picture image free '
        'rounded roundness radius none xxs xs small medium large xl xxl',
    builder: _chatAvatarsPage,
  ),
  _SearchEntry(
    title: 'Message spacing',
    section: 'Chat Interface',
    icon: Icons.height_outlined,
    keywords: 'gap space spacing between messages turns margin padding close '
        'tight distance avatars touching',
    builder: _spacingPage,
  ),
  _SearchEntry(
    title: 'Text placement',
    section: 'Chat Interface',
    icon: Icons.view_agenda_outlined,
    keywords: 'beside below under around wrap avatar layout position bubbles flat',
    builder: _textPlacementPage,
  ),
  _SearchEntry(
    title: 'Sender names',
    section: 'Chat Interface',
    icon: Icons.badge_outlined,
    keywords: 'name label title font google fonts typeface size placement align '
        'alignment position nudge offset drag sync independent character user',
    builder: _namesPage,
  ),
  _SearchEntry(
    title: 'Message actions',
    section: 'Chat Interface',
    icon: Icons.more_horiz,
    keywords: 'message actions buttons regenerate edit delete copy fork prompt '
        'info inline overflow three dot menu',
    builder: _messageActionsPage,
  ),
  _SearchEntry(
    title: 'Floating buttons',
    section: 'Chat Interface',
    icon: Icons.opacity_outlined,
    keywords: 'floating buttons opacity transparent translucent see through '
        'faint hide chrome menu hamburger square top left drawer sidebar jump '
        'to latest newest scroll to bottom arrow down fab',
    builder: _floatingButtonsPage,
  ),
  _SearchEntry(
    title: 'Message colours',
    section: 'Chat Interface',
    icon: Icons.format_color_fill_outlined,
    keywords: 'text bubble background colour color chat theme override font size',
    builder: _chatColoursPage,
  ),
  _SearchEntry(
    title: 'Group chat',
    section: 'Chat Interface',
    icon: Icons.groups_outlined,
    keywords: 'group chat multi character participants members bar height '
        'background picture colour color enable roleplay scene',
    builder: _groupChatsPage,
  ),
  _SearchEntry(
    title: 'Response hint',
    section: 'Chat Interface',
    icon: Icons.tips_and_updates_outlined,
    keywords: 'response hint guide steer nudge direction instruction inject '
        'depth realtime live author note ooc guidance next reply',
    builder: _responseHintPage,
  ),
  _SearchEntry(
    title: 'Storage',
    section: 'Storage',
    icon: Icons.sd_storage_outlined,
    keywords: 'data space usage size images pictures chats cache delete clean '
        'manage where saved unencrypted privacy',
    builder: _storagePage,
  ),
  _SearchEntry(
    title: 'Backups',
    section: 'Backups',
    icon: Icons.backup_outlined,
    keywords: 'backup export import restore snapshot zip archive google drive '
        'schedule automatic periodic daily weekly monthly keep retention '
        'migrate new phone move everything',
    builder: _backupsPage,
  ),
  _SearchEntry(
    title: 'Import a backup',
    section: 'Backups',
    icon: Icons.download_outlined,
    keywords: 'import restore sillytavern silly tavern agnai agnaistic chub '
        'venus card jsonl world info bring in migrate',
    builder: _backupImportPage,
  ),
  _SearchEntry(
    title: 'Google Drive',
    section: 'Backups',
    icon: Icons.cloud_outlined,
    keywords: 'google drive oauth sign in cloud upload account connect '
        'client id secret',
    builder: _drivePage,
  ),
  _SearchEntry(
    title: 'Version',
    section: 'About',
    icon: Icons.info_outline,
    keywords: 'build number release',
    builder: _versionPage,
  ),
];
// Const tear-offs so the index above stays a compile-time constant.
Widget _providersPage() => const ProvidersScreen();
Widget _tokenizerPage() => const TokenizerSettingsPage();
Widget _themePage() =>
    const AppearanceSettingsPage(highlight: SettingAnchor.theme);
Widget _systemColoursPage() =>
    const AppearanceSettingsPage(highlight: SettingAnchor.systemColours);
Widget _fontPage() =>
    const AppearanceSettingsPage(highlight: SettingAnchor.font);
Widget _chatAvatarsPage() =>
    const ChatInterfaceSettingsPage(highlight: SettingAnchor.chatAvatars);
Widget _textPlacementPage() =>
    const ChatInterfaceSettingsPage(highlight: SettingAnchor.textPlacement);
Widget _spacingPage() =>
    const ChatInterfaceSettingsPage(highlight: SettingAnchor.spacing);
Widget _namesPage() =>
    const ChatInterfaceSettingsPage(highlight: SettingAnchor.names);
Widget _messageActionsPage() =>
    const ChatInterfaceSettingsPage(highlight: SettingAnchor.messageActions);
Widget _floatingButtonsPage() =>
    const ChatInterfaceSettingsPage(highlight: SettingAnchor.floatingButtons);
Widget _chatColoursPage() =>
    const ChatInterfaceSettingsPage(highlight: SettingAnchor.chatColours);
Widget _groupChatsPage() =>
    const ChatInterfaceSettingsPage(highlight: SettingAnchor.groupChats);
Widget _responseHintPage() =>
    const ChatInterfaceSettingsPage(highlight: SettingAnchor.responseHint);
Widget _storagePage() => const StorageSettingsPage();
Widget _backupsPage() => const BackupsScreen();
Widget _backupImportPage() => const BackupImportScreen();
Widget _drivePage() => const DriveSettingsPage();
Widget _versionPage() =>
    const AboutSettingsPage(highlight: SettingAnchor.version);

/// The Material 3 search bar that expands into a full-screen view of matching
/// settings; tapping a result closes the view and drills into its page.
class _SettingsSearch extends StatelessWidget {
  const _SettingsSearch();

  @override
  Widget build(BuildContext context) {
    return SearchAnchor.bar(
      barHintText: 'Search settings',
      barLeading: const Icon(Icons.search),
      suggestionsBuilder: (context, controller) {
        final needle = controller.text.trim().toLowerCase();
        final results = needle.isEmpty
            ? _searchIndex
            : _searchIndex.where((e) => e.matches(needle)).toList();
        if (results.isEmpty) {
          return const [
            Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('No settings match that')),
            ),
          ];
        }
        return [
          for (final entry in results)
            ListTile(
              leading: Icon(entry.icon),
              title: Text(entry.title),
              subtitle: Text(entry.section),
              onTap: () {
                controller.closeView('');
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => entry.builder()),
                );
              },
            ),
        ];
      },
    );
  }
}
