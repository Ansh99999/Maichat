import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/conversation.dart';
import '../models/character.dart';
import '../models/chat_interface.dart';
import '../models/provider.dart';
import '../services/chat_client.dart';
import '../state/app_state.dart';
import '../widgets/avatar_image.dart';
import '../widgets/character_avatar.dart';
import '../widgets/message_bubble.dart';
import '../widgets/message_info_sheet.dart';
import '../widgets/startup_screen.dart';
import 'characters_screen.dart';
import 'chat_export.dart';
import 'chat_memory_panel.dart';
import 'chat_settings_screen.dart';
import 'chats_screen.dart';
import 'prompt_view_screen.dart';
import 'presets/chat_preset_panel.dart';
import 'presets/preset_pickers.dart';
import 'section_screen.dart';
import 'settings/appearance_settings_page.dart';
import 'settings_screen.dart';

/// A single conversation: the thread and a composer. The chat is deliberately
/// chrome-light — instead of a full app bar it carries a single translucent,
/// non-intrusive hamburger at the top-left that opens the chat sidebar, where
/// every option lives (provider/model, edit, export, restart, delete, and the
/// jumps to the other sections).
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// The index of the message currently being edited in place, or null.
  int? _editingIndex;

  @override
  void initState() {
    super.initState();
    // Never pop the soft keyboard just because the chat opened — drop any focus
    // carried in from the previous screen once the first frame is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send(AppState state) async {
    final text = _input.text;
    if (text.trim().isEmpty || state.streaming) return;
    if (!state.isConfigured) {
      _openSettings();
      return;
    }
    _input.clear();
    _scrollToEnd();
    await state.send(text);
    _scrollToEnd();
  }

  void _openSettings() => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
      );

  void _openAppearance() => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const AppearanceSettingsPage()),
      );

  void _openSection(String title, IconData icon) => Navigator.of(context).push(
        MaterialPageRoute<void>(
            builder: (_) => SectionScreen(title: title, icon: icon)),
      );

  void _openCharacters() => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const CharactersScreen()),
      );

  /// Back to the landing Home screen (the first route).
  void _goHome() => Navigator.of(context).popUntil((route) => route.isFirst);

  /// Home first, then open the full Chats list, so Back is predictable.
  void _goChats() {
    _goHome();
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ChatsScreen()),
    );
  }

  void _openQuickSettings() => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => _QuickSettingsSheet(onManage: () {
          Navigator.of(context).pop();
          _openSettings();
        }),
      );

  /// Opens the chat's own settings: title, background, a style of its own, and
  /// the characters taking part. Replaces the old rename-only dialog — renaming
  /// is now the first field on that screen.
  void _editChat(AppState state) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatSettingsScreen(conversationId: state.active.id),
        ),
      );

  /// Hands the thread to the export flow, which offers the shapes and then the
  /// file / clipboard chooser.
  Future<void> _exportChat(AppState state) async {
    final conversation = state.active;
    if (conversation.isEmpty) {
      _toast('Nothing to export yet.');
      return;
    }
    await exportChat(context, conversation);
  }

  Future<void> _restartChat(AppState state) async {
    final ok = await _confirm(
      title: 'Restart chat?',
      body: 'This clears every message in this chat but keeps it around.',
      action: 'Restart',
    );
    if (ok) {
      await state.restartConversation();
      _scrollToEnd();
    }
  }

  Future<void> _deleteChat(AppState state) async {
    final ok = await _confirm(
      title: 'Delete chat?',
      body: '"${state.active.title}" will be removed permanently.',
      action: 'Delete',
    );
    if (!ok) return;
    await state.deleteConversation(state.active.id);
    if (mounted) _goHome();
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _toast(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  /// Sticks to the newest message after the frame that added it.
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }
// APPEND-MARKER-1

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.ready) return const StartupScreen();
    final conversation = state.active;
    if (state.streaming) _scrollToEnd();
    final topInset = MediaQuery.paddingOf(context).top;
    // A chat can carry chat-style settings of its own; otherwise the app-wide
    // ones apply.
    final ui = state.interfaceFor(conversation);
    final bg = ui.backgroundColor != null ? Color(ui.backgroundColor!) : null;

    return Scaffold(
      backgroundColor: bg,
      drawer: _ChatDrawer(
        onProfile: _goHome,
        onCharacters: _openCharacters,
        onChats: _goChats,
        onParticipants: () => _editChat(state),
        onGallery: () => _openSection('Gallery', Icons.photo_library_outlined),
        onEditChat: () => _editChat(state),
        onUi: _openAppearance,
        onChatGraph: () =>
            _openSection('Chat Graph', Icons.account_tree_outlined),
        onProviderModel: _openQuickSettings,
        onSettings: _openSettings,
        onImageGen: () =>
            _openSection('Image Generation', Icons.add_photo_alternate_outlined),
        onExport: () => _exportChat(state),
        onRestart: () => _restartChat(state),
        onDelete: () => _deleteChat(state),
        onNotifications: () =>
            _openSection('Notifications', Icons.notifications_outlined),
      ),
      body: Stack(
        children: [
          // This chat's own picture, behind everything and behind nothing else's.
          if (conversation.backgroundImage != null)
            Positioned.fill(
              child: _ChatBackground(
                image: conversation.backgroundImage!,
                opacity: conversation.backgroundOpacity,
              ),
            ),
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: conversation.isEmpty
                      ? _EmptyState(
                          configured: state.isConfigured,
                          onSettings: _openSettings,
                        )
                      : _messageList(conversation, state, topInset),
                ),
                _composer(state),
              ],
            ),
          ),
          // The one piece of chrome: a translucent hamburger that floats over
          // the thread without boxing it in.
          Positioned(
            top: topInset + 6,
            left: 8,
            child: Builder(
              builder: (ctx) => _TranslucentMenuButton(
                onTap: () => Scaffold.of(ctx).openDrawer(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _messageList(Conversation conversation, AppState state, double top) {
    final ui = state.interfaceFor(conversation);
    final character = state.characterFor(conversation, conversation.characterId);
    final persona = state.impersonationFor(conversation);
    return ListView.builder(
      controller: _scroll,
      // Leave room so the first bubble clears the floating hamburger.
      padding: EdgeInsets.fromLTRB(0, top + 56, 0, 8),
      itemCount: conversation.messages.length,
      itemBuilder: (context, index) {
        final isLast = index == conversation.messages.length - 1;
        final message = conversation.messages[index];
        if (index == _editingIndex) {
          return _InlineMessageEditor(
            key: ValueKey('edit-${conversation.id}-$index'),
            initial: message.content,
            onCancel: () => setState(() => _editingIndex = null),
            onSave: (text) async {
              setState(() => _editingIndex = null);
              await state.editMessage(conversation.id, index, text);
            },
          );
        }
        return MessageBubble(
          message: message,
          ui: ui,
          character: character,
          userPersona: persona,
          pending: isLast && state.streaming,
          streaming: state.streaming,
          onAction: (action) =>
              _runMessageAction(state, conversation, index, action),
          onSwipe: (swipe) => state.setSwipe(conversation.id, index, swipe),
          onLongPress: message.content.isEmpty
              ? null
              : () => _showMessageActions(state, conversation, index),
        );
      },
    );
  }

  /// Dispatches an inline/overflow message action to the matching handler.
  void _runMessageAction(
    AppState state,
    Conversation conversation,
    int index,
    MessageAction action,
  ) {
    switch (action) {
      case MessageAction.regenerate:
        state.regenerateMessage(conversation.id, index);
        _scrollToEnd();
      case MessageAction.edit:
        setState(() => _editingIndex = index);
      case MessageAction.delete:
        state.deleteMessage(conversation.id, index);
      case MessageAction.copy:
        Clipboard.setData(
            ClipboardData(text: conversation.messages[index].content));
        _toast('Copied');
      case MessageAction.fork:
        _forkFrom(state, conversation, index);
      case MessageAction.prompt:
        _openPromptView(state, conversation, index);
      case MessageAction.info:
        _openMessageInfo(state, conversation, index);
    }
  }

  Future<void> _forkFrom(
      AppState state, Conversation conversation, int index) async {
    await state.forkConversation(conversation.id, index);
    if (!mounted) return;
    _toast('Forked into a new chat');
    _scrollToEnd();
  }

  /// Opens the full assembled prompt behind [index] — exactly what the model
  /// receives — in a scrollable inspector.
  void _openPromptView(AppState state, Conversation conversation, int index) {
    final assembled = state.assemblePromptForMessage(conversation, index);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PromptViewScreen(assembled: assembled),
      ),
    );
  }

  /// Opens the message info sheet: position, tokens, and a context breakdown.
  void _openMessageInfo(AppState state, Conversation conversation, int index) {
    final assembled = state.assemblePromptForMessage(conversation, index);
    final message = conversation.messages[index];
    // An exact provider-side count only exists for Anthropic; fetched lazily so
    // it never blocks opening the sheet.
    final exact = state.activeProvider?.kind == ProviderKind.anthropic
        ? state.exactTokenCount(assembled)
        : null;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => MessageInfoSheet(
        assembled: assembled,
        messageNumber: index + 1,
        messageCount: conversation.messages.length,
        message: message,
        messageTokens: state.estimateTokens(message.content),
        exactCount: exact,
      ),
    );
  }

  /// The per-message action sheet: copy, edit, regenerate (assistant turns),
  /// fork from here, or delete.
  void _showMessageActions(
    AppState state,
    Conversation conversation,
    int index,
  ) {
    final message = conversation.messages[index];
    final isAssistant = !message.isUser;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Copy'),
              onTap: () {
                Navigator.of(sheet).pop();
                Clipboard.setData(ClipboardData(text: message.content));
                _toast('Copied');
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.of(sheet).pop();
                setState(() => _editingIndex = index);
              },
            ),
            if (isAssistant)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Regenerate'),
                enabled: !state.streaming,
                onTap: () {
                  Navigator.of(sheet).pop();
                  state.regenerateMessage(conversation.id, index);
                  _scrollToEnd();
                },
              ),
            ListTile(
              leading: const Icon(Icons.call_split),
              title: const Text('Fork from here'),
              subtitle: const Text('Copy the chat up to this turn'),
              onTap: () async {
                Navigator.of(sheet).pop();
                await state.forkConversation(conversation.id, index);
                _toast('Forked into a new chat');
                _scrollToEnd();
              },
            ),
            if (isAssistant)
              ListTile(
                leading: const Icon(Icons.terminal),
                title: const Text('View prompt'),
                subtitle: const Text('Inspect the exact request sent'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _openPromptView(state, conversation, index);
                },
              ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Info'),
              subtitle: const Text('Tokens and context breakdown'),
              onTap: () {
                Navigator.of(sheet).pop();
                _openMessageInfo(state, conversation, index);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(sheet).colorScheme.error),
              title: const Text('Delete'),
              enabled: !state.streaming,
              onTap: () {
                Navigator.of(sheet).pop();
                state.deleteMessage(conversation.id, index);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _composer(AppState state) {
    final scheme = Theme.of(context).colorScheme;
    final persona = state.impersonationFor(state.active);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _ImpersonateButton(
            persona: persona,
            onTap: () => _openImpersonatePicker(state),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                hintText:
                    persona == null ? 'Message' : 'Message as ${persona.displayName}',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _sendButton(state),
        ],
      ),
    );
  }

  /// Opens the impersonation picker (search + character list) and, on a pick,
  /// confirms before switching the active identity.
  Future<void> _openImpersonatePicker(AppState state) async {
    final current = state.impersonationFor(state.active);
    final choice = await showModalBottomSheet<_ImpersonationChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ImpersonatePicker(
        characters: state.characters,
        currentId: current?.id,
      ),
    );
    if (choice == null || !mounted) return;

    if (choice.character == null) {
      // "Yourself" — clear any impersonation.
      if (current != null) {
        await state.setImpersonation(null);
        if (mounted) _toast('Impersonation cleared — back to yourself.');
      }
      return;
    }

    final character = choice.character!;
    final ok = await _confirm(
      title: 'Impersonate?',
      body: 'Do you want to impersonate ${character.displayName}? Your messages '
          'will be sent as this character.',
      action: 'Impersonate',
    );
    if (!ok || !mounted) return;
    await state.setImpersonation(character);
    if (mounted) _toast('Now impersonating ${character.displayName}.');
  }

  /// Doubles as the stop control while a reply is streaming.
  Widget _sendButton(AppState state) {
    final scheme = Theme.of(context).colorScheme;
    if (state.streaming) {
      return IconButton.filled(
        tooltip: 'Stop',
        onPressed: state.stop,
        style: IconButton.styleFrom(
          backgroundColor: scheme.error,
          foregroundColor: scheme.onError,
        ),
        icon: const Icon(Icons.stop),
      );
    }
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _input,
      builder: (context, value, _) => IconButton.filled(
        tooltip: 'Send',
        onPressed: value.text.trim().isEmpty ? null : () => _send(state),
        icon: const Icon(Icons.arrow_upward),
      ),
    );
  }
}
// APPEND-MARKER-2

/// Edits a message in place, right where it sits in the thread — no dialog. A
/// cancel (✕) and save (✓) sit at the top-right; the text field fills the row so
/// there is room to type.
/// The picture behind one chat, drawn edge to edge under the thread.
///
/// [opacity] is the point of the whole thing: a photograph at full strength
/// behind running text is unreadable, so the picture is faded towards whatever
/// the chat's background colour is. A reference that no longer resolves (the
/// file was swept, the URL went away) draws nothing rather than an error box.
class _ChatBackground extends StatelessWidget {
  const _ChatBackground({required this.image, required this.opacity});

  final String image;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final provider = avatarImage(
      image,
      displaySize: size.longestSide,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    if (provider == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Image(
          image: provider,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class _InlineMessageEditor extends StatefulWidget {  const _InlineMessageEditor({
    super.key,
    required this.initial,
    required this.onSave,
    required this.onCancel,
  });

  final String initial;
  final ValueChanged<String> onSave;
  final VoidCallback onCancel;

  @override
  State<_InlineMessageEditor> createState() => _InlineMessageEditorState();
}

class _InlineMessageEditorState extends State<_InlineMessageEditor> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.primary, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Cancel',
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                onPressed: widget.onCancel,
                icon: const Icon(Icons.close),
              ),
              IconButton(
                tooltip: 'Save',
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                color: scheme.primary,
                onPressed: () => widget.onSave(_controller.text),
                icon: const Icon(Icons.check),
              ),
            ],
          ),
          TextField(
            controller: _controller,
            autofocus: false,
            minLines: 1,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: 'Edit message',
            ),
          ),
        ],
      ),
    );
  }
}


/// The lone bit of chat chrome: a small, frosted, semi-transparent circle that
/// carries the menu icon. Translucent enough to let the thread show through,
/// so it never boxes the conversation in.
class _TranslucentMenuButton extends StatelessWidget {
  const _TranslucentMenuButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Material(
          color: scheme.surface.withValues(alpha: 0.4),
          shape: const CircleBorder(),
          child: IconButton(
            tooltip: 'Menu',
            icon: Icon(Icons.menu, color: scheme.onSurface.withValues(alpha: 0.9)),
            onPressed: onTap,
          ),
        ),
      ),
    );
  }
}

/// Which face the chat sidebar is showing: its menu, or one of the panels that
/// live *inside* the drawer. They replace the menu rather than being pushed as
/// routes, so backing out of one returns to the menu with the drawer still open.
enum _DrawerPanel { menu, presets, memory }

/// The chat sidebar. Mirrors agnai's chat menu: an editable chat title on top,
/// jumps to the other sections, provider/model, and a utility row of chat
/// actions (settings, image gen, export, restart, delete, notifications).
/// "Preset" and "Memory" open in-drawer panels rather than navigating away.
class _ChatDrawer extends StatefulWidget {
  const _ChatDrawer({
    required this.onProfile,
    required this.onCharacters,
    required this.onChats,
    required this.onParticipants,
    required this.onGallery,
    required this.onEditChat,
    required this.onUi,
    required this.onChatGraph,
    required this.onProviderModel,
    required this.onSettings,
    required this.onImageGen,
    required this.onExport,
    required this.onRestart,
    required this.onDelete,
    required this.onNotifications,
  });

  final VoidCallback onProfile;
  final VoidCallback onCharacters;
  final VoidCallback onChats;
  final VoidCallback onParticipants;
  final VoidCallback onGallery;
  final VoidCallback onEditChat;
  final VoidCallback onUi;
  final VoidCallback onChatGraph;
  final VoidCallback onProviderModel;
  final VoidCallback onSettings;
  final VoidCallback onImageGen;
  final VoidCallback onExport;
  final VoidCallback onRestart;
  final VoidCallback onDelete;
  final VoidCallback onNotifications;

  @override
  State<_ChatDrawer> createState() => _ChatDrawerState();
}

class _ChatDrawerState extends State<_ChatDrawer> {
  _DrawerPanel _panel = _DrawerPanel.menu;

  /// Runs [action] after the drawer has closed, so the drawer does not sit
  /// open behind whatever the action pushes or shows.
  void _close(BuildContext context, VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }

  void _show(_DrawerPanel panel) => setState(() => _panel = panel);

  @override
  Widget build(BuildContext context) {
    switch (_panel) {
      case _DrawerPanel.presets:
        return Drawer(
          child: SafeArea(
            child: ChatPresetPanel(
              onBack: () => _show(_DrawerPanel.menu),
            ),
          ),
        );
      case _DrawerPanel.memory:
        return Drawer(
          child: SafeArea(
            child: ChatMemoryPanel(
              onBack: () => _show(_DrawerPanel.menu),
            ),
          ),
        );
      case _DrawerPanel.menu:
        break;
    }

    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final conversation = state.active;
    final active = state.activeProvider;
    final model = active?.model.trim() ?? '';
    final providerSubtitle = active == null
        ? 'No provider yet'
        : '${active.displayName}${model.isEmpty ? '' : ' · $model'}';
    final presetName = state.presetFor(conversation)?.displayName ?? 'Default';
    // How much memory this chat is carrying, so the user can see it without
    // opening the panel. Resolved through AppState so a deleted book is not
    // counted.
    final memoryCount = state.lorebooksFor(conversation).length;
    final memorySubtitle =
        memoryCount == 0 ? 'None' : '$memoryCount active';

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            // Editable chat title, like agnai's "edit character" header.
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: InkWell(
                onTap: () => _close(context, widget.onEditChat),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined, size: 18, color: scheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          conversation.isEmpty ? 'New chat' : conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                children: [
                  _ChatNavItem(
                    icon: Icons.person_outline,
                    label: 'Profile',
                    onTap: () => _close(context, widget.onProfile),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: _BackNavButton(
                            label: 'Characters',
                            onTap: () => _close(context, widget.onCharacters),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _BackNavButton(
                            label: 'Chats',
                            onTap: () => _close(context, widget.onChats),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _ChatNavItem(
                    icon: Icons.group_outlined,
                    label: 'Participants',
                    onTap: () => _close(context, widget.onParticipants),
                  ),
                  _ChatNavItem(
                    icon: Icons.photo_library_outlined,
                    label: 'Gallery',
                    onTap: () => _close(context, widget.onGallery),
                  ),
                  _ChatNavItem(
                    icon: Icons.edit_note_outlined,
                    label: 'Edit Chat',
                    onTap: () => _close(context, widget.onEditChat),
                  ),
                  _ChatNavItem(
                    icon: Icons.tune_outlined,
                    label: 'Preset',
                    subtitle: presetName,
                    onTap: () => _show(_DrawerPanel.presets),
                  ),
                  _ChatNavItem(
                    icon: Icons.book_outlined,
                    label: 'Memory',
                    subtitle: memorySubtitle,
                    onTap: () => _show(_DrawerPanel.memory),
                  ),
                  _ChatNavItem(
                    icon: Icons.palette_outlined,
                    label: 'UI',
                    onTap: () => _close(context, widget.onUi),
                  ),
                  _ChatNavItem(
                    icon: Icons.account_tree_outlined,
                    label: 'Chat Graph',
                    onTap: () => _close(context, widget.onChatGraph),
                  ),
                  const SizedBox(height: 4),
                  _ChatNavItem(
                    icon: Icons.dns_outlined,
                    label: 'Provider & model',
                    subtitle: providerSubtitle,
                    onTap: () => _close(context, widget.onProviderModel),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            _ChatDrawerFooter(
              onSettings: () => _close(context, widget.onSettings),
              onImageGen: () => _close(context, widget.onImageGen),
              onExport: () => _close(context, widget.onExport),
              onRestart: () => _close(context, widget.onRestart),
              onDelete: () => _close(context, widget.onDelete),
              onNotifications: () => _close(context, widget.onNotifications),
            ),
          ],
        ),
      ),
    );
  }
}
// APPEND-MARKER-3

/// A single rounded destination in the chat sidebar, optionally with a quiet
/// second line (used to show the active provider and model).
class _ChatNavItem extends StatelessWidget {
  const _ChatNavItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        leading: Icon(icon, color: scheme.onSurfaceVariant),
        title: Text(
          label,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w500),
        ),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onTap: onTap,
      ),
    );
  }
}

/// One half of the "← Characters / ← Chats" back-navigation pair.
class _BackNavButton extends StatelessWidget {
  const _BackNavButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.chevron_left, size: 18),
      label: Text(label, overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

/// The utility strip pinned to the bottom of the chat sidebar: icon-only chat
/// actions, echoing agnai's footer row.
class _ChatDrawerFooter extends StatelessWidget {
  const _ChatDrawerFooter({
    required this.onSettings,
    required this.onImageGen,
    required this.onExport,
    required this.onRestart,
    required this.onDelete,
    required this.onNotifications,
  });

  final VoidCallback onSettings;
  final VoidCallback onImageGen;
  final VoidCallback onExport;
  final VoidCallback onRestart;
  final VoidCallback onDelete;
  final VoidCallback onNotifications;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Wrap(
        alignment: WrapAlignment.spaceEvenly,
        children: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: onSettings,
          ),
          IconButton(
            tooltip: 'Image generation',
            icon: const Icon(Icons.add_photo_alternate_outlined),
            onPressed: onImageGen,
          ),
          IconButton(
            tooltip: 'Export chat',
            icon: const Icon(Icons.download_outlined),
            onPressed: onExport,
          ),
          IconButton(
            tooltip: 'Restart chat',
            icon: const Icon(Icons.restart_alt),
            onPressed: onRestart,
          ),
          IconButton(
            tooltip: 'Delete chat',
            icon: Icon(Icons.delete_outline, color: scheme.error),
            onPressed: onDelete,
          ),
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_outlined),
            onPressed: onNotifications,
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.configured, required this.onSettings});

  final bool configured;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              configured ? Icons.forum_outlined : Icons.key_outlined,
              size: 44,
              color: scheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              configured
                  ? 'Say something to get started.'
                  : 'Add a provider with a model to start chatting.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            if (!configured) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: onSettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Open settings'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
// APPEND-MARKER-4

/// The chat-screen quick picker: switch the active provider and choose its
/// model without leaving the conversation. "Manage providers" drops into the
/// full settings for adding, editing or deleting.
class _QuickSettingsSheet extends StatefulWidget {
  const _QuickSettingsSheet({required this.onManage});

  final VoidCallback onManage;

  @override
  State<_QuickSettingsSheet> createState() => _QuickSettingsSheetState();
}

class _QuickSettingsSheetState extends State<_QuickSettingsSheet> {
  Future<void> _browseModels(AppState state, Provider active) async {
    final chosen = await showSearchPicker(
      context: context,
      title: 'Choose model',
      entries: [
        for (final m in state.cachedModels(active.id)) PickerEntry(id: m, title: m),
      ],
      selectedId: active.model.trim(),
      allowCustom: true,
      onRefresh: () async {
        try {
          final models = await state.refreshModels(active);
          return [for (final m in models) PickerEntry(id: m, title: m)];
        } on ChatApiException catch (e) {
          throw PickerRefreshException(e.message);
        }
      },
      refreshOnEmpty: state.cachedModels(active.id).isEmpty,
    );
    if (chosen == null || !mounted) return;
    await state.setActiveModel(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final providers = state.providers;
    final active = state.activeProvider;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                'Provider',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (providers.isEmpty)
              const ListTile(
                leading: Icon(Icons.dns_outlined),
                title: Text('No providers yet'),
                subtitle: Text('Add one to start chatting'),
              )
            else
              Flexible(
                child: RadioGroup<String>(
                  groupValue: active?.id,
                  onChanged: (id) {
                    if (id != null) state.selectProvider(id);
                  },
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final provider in providers)
                        RadioListTile<String>(
                          value: provider.id,
                          title: Text(
                            provider.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            provider.kind.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            const Divider(height: 1),
            if (active != null)
              ListTile(
                leading: const Icon(Icons.memory_outlined),
                title: const Text('Model'),
                subtitle: Text(
                  active.model.trim().isEmpty ? 'None selected' : active.model,
                ),
                trailing: const Icon(Icons.expand_more),
                onTap: () => _browseModels(state, active),
              ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Manage providers'),
              onTap: widget.onManage,
            ),
          ],
        ),
      ),
    );
  }
}

/// The small circular avatar on the far left of the composer. Shows the
/// impersonated character's picture when the user has assumed an identity,
/// otherwise a plain person glyph. Tapping it opens the impersonation picker.
class _ImpersonateButton extends StatelessWidget {
  const _ImpersonateButton({required this.persona, required this.onTap});

  final Character? persona;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const double diameter = 40;
    final impersonating = persona != null;
    return Tooltip(
      message: impersonating
          ? 'Impersonating ${persona!.displayName}'
          : 'Impersonate a character',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: impersonating ? scheme.primary : scheme.outlineVariant,
              width: impersonating ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: impersonating
              ? CharacterAvatar(character: persona!, size: diameter)
              : Icon(Icons.person_outline,
                  color: scheme.onSurfaceVariant, size: 22),
        ),
      ),
    );
  }
}

/// The result of the impersonation picker: a chosen character, or a null
/// character meaning "be yourself" (clear impersonation).
class _ImpersonationChoice {
  const _ImpersonationChoice(this.character);
  final Character? character;
}

/// A bottom sheet to pick who to impersonate: a search field over a scrollable
/// list of saved characters, plus a "Yourself" entry at the top to step back
/// out of any active impersonation.
class _ImpersonatePicker extends StatefulWidget {
  const _ImpersonatePicker({required this.characters, this.currentId});

  final List<Character> characters;
  final String? currentId;

  @override
  State<_ImpersonatePicker> createState() => _ImpersonatePickerState();
}

class _ImpersonatePickerState extends State<_ImpersonatePicker> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Character> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.characters;
    return widget.characters
        .where((c) =>
            c.name.toLowerCase().contains(q) ||
            c.blurb.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.viewInsetsOf(context).bottom +
        MediaQuery.paddingOf(context).bottom;
    final results = _visible;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Text('Impersonate',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _search,
                autofocus: false,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Search characters',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.secondaryContainer,
                      child: Icon(Icons.person_outline,
                          color: scheme.onSecondaryContainer),
                    ),
                    title: const Text('Yourself'),
                    subtitle: const Text('Stop impersonating'),
                    trailing: widget.currentId == null
                        ? Icon(Icons.check, color: scheme.primary)
                        : null,
                    onTap: () => Navigator.of(context)
                        .pop(const _ImpersonationChoice(null)),
                  ),
                  if (widget.characters.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: Text('No characters yet — import or create one '
                            'to impersonate.'),
                      ),
                    )
                  else if (results.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('No characters match that')),
                    )
                  else
                    for (final c in results)
                      ListTile(
                        leading: CharacterAvatar(character: c, radius: 20),
                        title: Text(c.displayName,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: c.blurb.isEmpty
                            ? null
                            : Text(c.blurb,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: widget.currentId == c.id
                            ? Icon(Icons.check, color: scheme.primary)
                            : null,
                        onTap: () => Navigator.of(context)
                            .pop(_ImpersonationChoice(c)),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}


