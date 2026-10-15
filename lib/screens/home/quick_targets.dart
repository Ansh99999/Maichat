import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/appearance.dart';
import '../../models/home_layout.dart';
import '../../state/app_state.dart';
import '../../widgets/interface_preset_sheet.dart';
import '../backups/backups_screen.dart';
import '../character_editor.dart';
import '../characters_screen.dart';
import '../chat_screen.dart';
import '../chats_screen.dart';
import '../discover/discover_screen.dart';
import '../gallery/gallery_screen.dart';
import '../image_gen/image_gen_sheet.dart';
import '../library/library_screen.dart';
import '../library/lorebooks_screen.dart';
import '../library/scenarios_screen.dart';
import '../presets/presets_screen.dart';
import '../profile_screen.dart';
import '../providers/providers_screen.dart';
import '../settings_screen.dart';
import '../studio/studio_home_screen.dart';
import '../studio/studio_screen.dart';
import '../../services/studio/studio_controller.dart';
import '../../services/studio/studio_store.dart';

/// How one quick-open destination looks and what it does.
///
/// Icons are Material Symbols chosen so no two in the set read alike at 24 px:
/// a chat is a speech bubble, the Studio is the sparkle the rest of the app
/// already uses for it, the Library is a shelf of books, Discover is a compass
/// (it browses other people's catalogues — the globe stays the drawer's), and
/// the "new" actions are their noun with a plus.
class QuickTargetInfo {
  const QuickTargetInfo({
    required this.label,
    required this.icon,
    required this.description,
    this.group = QuickGroup.open,
  });

  final String label;
  final IconData icon;
  final String description;
  final QuickGroup group;
}

/// The headings the destination picker groups targets under.
enum QuickGroup {
  create('Start something'),
  open('Open a screen'),
  tools('Tools');

  const QuickGroup(this.label);
  final String label;
}

const Map<QuickTarget, QuickTargetInfo> kQuickTargets = {
  QuickTarget.newChat: QuickTargetInfo(
    label: 'New chat',
    icon: Icons.add_comment_outlined,
    description: 'Start a blank conversation',
    group: QuickGroup.create,
  ),
  QuickTarget.resume: QuickTargetInfo(
    label: 'Resume',
    icon: Icons.history_rounded,
    description: 'Back into the chat you were last in',
    group: QuickGroup.create,
  ),
  QuickTarget.newCharacter: QuickTargetInfo(
    label: 'New character',
    icon: Icons.person_add_alt_1_outlined,
    description: 'Open the character creator',
    group: QuickGroup.create,
  ),
  QuickTarget.newStudioSession: QuickTargetInfo(
    label: 'New draft',
    icon: Icons.auto_fix_high_outlined,
    description: 'A fresh Character Studio session',
    group: QuickGroup.create,
  ),
  QuickTarget.importCharacter: QuickTargetInfo(
    label: 'Import',
    icon: Icons.file_download_outlined,
    description: 'Bring in a character card',
    group: QuickGroup.create,
  ),
  QuickTarget.chats: QuickTargetInfo(
    label: 'Chats',
    icon: Icons.forum_outlined,
    description: 'Every conversation',
  ),
  QuickTarget.characters: QuickTargetInfo(
    label: 'Characters',
    icon: Icons.groups_outlined,
    description: 'Your roster',
  ),
  QuickTarget.studio: QuickTargetInfo(
    label: 'Studio',
    icon: Icons.auto_awesome_outlined,
    description: 'The Character Studio and its agents',
  ),
  QuickTarget.discover: QuickTargetInfo(
    label: 'Discover',
    icon: Icons.explore_outlined,
    description: 'Browse character catalogues',
  ),
  QuickTarget.library: QuickTargetInfo(
    label: 'Library',
    icon: Icons.local_library_outlined,
    description: 'Lorebooks, scenarios, regex and more',
  ),
  QuickTarget.lorebooks: QuickTargetInfo(
    label: 'Lorebooks',
    icon: Icons.auto_stories_outlined,
    description: 'World info, straight to the shelf',
  ),
  QuickTarget.scenarios: QuickTargetInfo(
    label: 'Scenarios',
    icon: Icons.theater_comedy_outlined,
    description: 'Settings to drop a character into',
  ),
  QuickTarget.gallery: QuickTargetInfo(
    label: 'Gallery',
    icon: Icons.photo_library_outlined,
    description: 'Every picture in the app',
  ),
  QuickTarget.profile: QuickTargetInfo(
    label: 'Profile',
    icon: Icons.face_outlined,
    description: 'Who you are in chats',
  ),
  QuickTarget.imageStudio: QuickTargetInfo(
    label: 'Imagine',
    icon: Icons.brush_outlined,
    description: 'Generate a picture',
    group: QuickGroup.tools,
  ),
  QuickTarget.providers: QuickTargetInfo(
    label: 'Providers',
    icon: Icons.dns_outlined,
    description: 'Where replies come from',
    group: QuickGroup.tools,
  ),
  QuickTarget.presets: QuickTargetInfo(
    label: 'Presets',
    icon: Icons.tune_outlined,
    description: 'Prompt presets',
    group: QuickGroup.tools,
  ),
  QuickTarget.chatLook: QuickTargetInfo(
    label: 'Chat look',
    icon: Icons.palette_outlined,
    description: 'Switch the saved look chats wear',
    group: QuickGroup.tools,
  ),
  QuickTarget.backups: QuickTargetInfo(
    label: 'Backups',
    icon: Icons.backup_outlined,
    description: 'Back up or restore',
    group: QuickGroup.tools,
  ),
  QuickTarget.themeToggle: QuickTargetInfo(
    label: 'Light / dark',
    icon: Icons.contrast_rounded,
    description: 'Flip between light and dark',
    group: QuickGroup.tools,
  ),
  QuickTarget.settings: QuickTargetInfo(
    label: 'Settings',
    icon: Icons.settings_outlined,
    description: 'Everything else',
    group: QuickGroup.tools,
  ),
};

QuickTargetInfo quickTargetInfo(QuickTarget target) => kQuickTargets[target]!;

void _push(BuildContext context, Widget screen) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => screen));

/// Does what [target] stands for, from the Home screen.
Future<void> openQuickTarget(BuildContext context, QuickTarget target) async {
  final state = context.read<AppState>();
  switch (target) {
    case QuickTarget.newChat:
      state.newConversation();
      _push(context, const ChatScreen());
    case QuickTarget.resume:
      final last = state.conversations.where((c) => !c.isEmpty).firstOrNull;
      if (last == null) {
        state.newConversation();
      } else {
        state.selectConversation(last.id);
      }
      _push(context, const ChatScreen());
    case QuickTarget.chats:
      _push(context, const ChatsScreen());
    case QuickTarget.characters:
      _push(context, const CharactersScreen());
    case QuickTarget.newCharacter:
      await openCharacterEditor(context);
    case QuickTarget.importCharacter:
      _push(context, const CharactersScreen(openImport: true));
    case QuickTarget.studio:
      await openCharacterStudio(context);
    case QuickTarget.newStudioSession:
      await openNewStudioSession(context);
    case QuickTarget.discover:
      _push(context, const DiscoverScreen());
    case QuickTarget.library:
      _push(context, const LibraryScreen());
    case QuickTarget.lorebooks:
      _push(context, const LorebooksScreen());
    case QuickTarget.scenarios:
      _push(context, const ScenariosScreen());
    case QuickTarget.gallery:
      _push(context, const GalleryScreen());
    case QuickTarget.imageStudio:
      await showImageStudio(context);
    case QuickTarget.providers:
      _push(context, const ProvidersScreen());
    case QuickTarget.presets:
      _push(context, const PresetsScreen());
    case QuickTarget.chatLook:
      await showInterfacePresetSheet(context);
    case QuickTarget.profile:
      _push(context, const ProfileScreen());
    case QuickTarget.backups:
      _push(context, const BackupsScreen());
    case QuickTarget.settings:
      _push(context, const SettingsScreen());
    case QuickTarget.themeToggle:
      final mode = state.appearance.mode;
      final dark = mode.isDark ||
          (mode == AppThemeMode.system &&
              MediaQuery.platformBrightnessOf(context) == Brightness.dark);
      await state.updateAppearance(state.appearance.copyWith(
        mode: dark ? AppThemeMode.light : AppThemeMode.dark,
      ));
  }
}

/// Starts a Studio session and opens it, the way the session list's "New
/// session" does, without making the user go through the list.
Future<void> openNewStudioSession(BuildContext context) async {
  final store = await StudioStore.open();
  if (!context.mounted) return;
  if (store == null) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('This device would not give the Studio a folder to keep '
          'its sessions in.'),
    ));
    return;
  }
  final session = newStudioSession();
  await store.save(session);
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    settings: const RouteSettings(name: kStudioSessionRoute),
    builder: (_) => StudioScreen(store: store, session: session),
  ));
}
