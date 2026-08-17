import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/character.dart';
import '../models/chat_interface.dart';
import '../models/conversation.dart';
import '../state/app_state.dart';
import '../widgets/avatar_image.dart';
import '../widgets/character_avatar.dart';
import 'character_edit_screen.dart';
import 'group_add_sheet.dart';
import 'settings/chat_interface_settings_page.dart';
import 'settings/chat_ui_scope.dart';

/// Everything that belongs to one chat rather than to the app: its title, a
/// picture behind it, a chat style of its own, and the characters taking part —
/// including definitions edited for this chat alone.
///
/// Nothing here is written until Save. That matters most for the character
/// edits: a change to a card has two plausible homes (this chat, or everywhere),
/// so the edits are collected as drafts and Save asks where each one goes.
class ChatSettingsScreen extends StatefulWidget {
  const ChatSettingsScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

/// Where a pending character edit is to be kept.
enum CharacterSaveTarget {
  chat('For this chat', 'Saved for chat'),
  global('Globally', 'Saved globally');

  const CharacterSaveTarget(this.label, this.done);

  /// The choice as offered in the menu.
  final String label;

  /// The row's label once the choice is made.
  final String done;
}

/// One participant of a chat, as the "Characters involved" list sees it.
class _Participant {
  const _Participant({
    required this.role,
    required this.character,
    this.id,
    this.placeholder,
    this.removable = false,
  });

  /// 'Character' or 'You' — what this row is, not who.
  final String role;

  /// The character id this row stands for, kept even when the card has been
  /// deleted from the roster so the row can still be removed. Null for the user.
  final String? id;

  /// Null for the plain user, and for a character whose card has been deleted.
  final Character? character;

  /// Shown instead of a name when there is no character to name.
  final String? placeholder;

  /// Whether this row can be taken out of the chat.
  final bool removable;

  bool get isUser => role != 'Character';
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  late final TextEditingController _title;

  /// The picture behind this chat, as a reference to persist. Null means none.
  String? _background;
  double _opacity = 1;

  /// This chat's own chat style, or null to follow the app-wide settings.
  ChatInterface? _appearance;

  bool _overrideDefinitions = false;

  /// Character edits made here but not yet given a home, by character id.
  final Map<String, Character> _edits = <String, Character>{};

  @override
  void initState() {
    super.initState();
    final conversation = context.read<AppState>().conversationById(
          widget.conversationId,
        );
    _title = TextEditingController(text: conversation?.title ?? '');
    _background = conversation?.backgroundImage;
    _opacity = conversation?.backgroundOpacity ?? 1;
    _appearance = conversation?.interfaceOverride;
    _overrideDefinitions = conversation?.overrideDefinitions ?? false;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Conversation? _conversation(AppState state) =>
      state.conversationById(widget.conversationId);

  /// Whether anything on this screen differs from what is stored.
  bool _dirty(Conversation conversation) =>
      _edits.isNotEmpty ||
      _title.text.trim() != conversation.title.trim() ||
      _background != conversation.backgroundImage ||
      _opacity != conversation.backgroundOpacity ||
      _appearance != conversation.interfaceOverride ||
      _overrideDefinitions != conversation.overrideDefinitions;

  /// Who is taking part: every AI character in the thread, then the user's
  /// identity. A one-to-one chat lists its single character; a group lists all
  /// its members, in speaking order.
  List<_Participant> _participants(AppState state, Conversation conversation) {
    final rows = <_Participant>[];
    for (final id in conversation.memberIds) {
      // A thread outlives the card it was started from, so a character that has
      // been deleted from the roster still gets a row — otherwise the chat looks
      // like nobody is in it and there is no way to unlink the ghost.
      final bot = _resolved(state, conversation, id);
      final ghostName = id == conversation.characterId
          ? (conversation.characterName ?? 'Character')
          : 'Character';
      rows.add(_Participant(
        role: 'Character',
        id: id,
        character: bot,
        placeholder: bot == null ? '$ghostName (deleted)' : null,
        removable: true,
      ));
    }
    final me = _resolved(state, conversation, conversation.impersonateId);
    rows.add(_Participant(
      role: 'You',
      character: me,
      placeholder: me == null ? 'You' : null,
      removable: me != null,
    ));
    return rows;
  }

  /// The definition this screen should show for [id]: a pending edit first, then
  /// the chat's own override, then the roster's card.
  Character? _resolved(AppState state, Conversation conversation, String? id) {
    if (id == null) return null;
    return _edits[id] ?? state.characterFor(conversation, id);
  }

  void _toast(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
    ));

  /// Opens the character editor on a draft. What comes back is held here until
  /// Save decides whether it belongs to this chat or to the roster.
  Future<void> _editCharacter(Character character) async {
    final edited = await Navigator.of(context).push<Character>(
      MaterialPageRoute<Character>(
        builder: (_) => CharacterEditScreen(
          character: character.clone(),
          persist: false,
        ),
      ),
    );
    if (edited == null || !mounted) return;
    setState(() => _edits[edited.id] = edited);
  }

  /// Takes a participant out of this chat. The messages stay — only the
  /// definition behind them goes.
  Future<void> _removeParticipant(_Participant participant) async {
    final name = participant.character?.displayName ??
        participant.placeholder ??
        'this participant';
    final ok = await _confirm(
      title: participant.isUser ? 'Stop impersonating?' : 'Remove $name?',
      body: participant.isUser
          ? 'Your turns go back to being signed as you. The messages stay.'
          : '$name stops taking part in this chat and its definition is no '
              'longer sent. The messages stay.',
      action: 'Remove',
    );
    if (!ok || !mounted) return;
    final state = context.read<AppState>();
    if (participant.isUser) {
      await state.detachCharacter(widget.conversationId, impersonation: true);
      return;
    }
    // A character member — group-aware removal that collapses a two-member
    // thread back to one-to-one and unlinks the last member entirely.
    final id = participant.id ?? participant.character?.id;
    if (id == null) return;
    await state.removeParticipant(widget.conversationId, id);
    if (mounted) setState(() => _edits.remove(id));
  }

  /// The "+" beside Characters involved. With group chats on, this opens the
  /// add/remove sheet so the chat can hold several characters; with the feature
  /// off, a chat holds one, so it attaches one when there is none and says why
  /// it cannot do more when there is.
  Future<void> _addParticipant(Conversation conversation) async {
    final state = context.read<AppState>();
    if (state.characters.isEmpty) {
      _toast('No characters yet — import or create one first.');
      return;
    }
    if (state.groupChatsEnabled) {
      await showGroupAddSheet(context, conversationId: widget.conversationId);
      if (!mounted) return;
      // The title may have been taken from the first character attached.
      final fresh = state.conversationById(widget.conversationId);
      if (fresh != null && _title.text.trim().isEmpty) {
        _title.text = fresh.title;
      }
      return;
    }
    if (conversation.characterId != null) {
      _toast('One character per chat — turn on group chats in Chat Interface '
          'settings to add more.');
      return;
    }
    final picked = await showModalBottomSheet<Character>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _CharacterPickerSheet(characters: state.characters),
    );
    if (picked == null || !mounted) return;
    await state.attachCharacter(widget.conversationId, picked);
    if (!mounted) return;
    // The title may have been taken from the character just attached.
    final fresh = state.conversationById(widget.conversationId);
    if (fresh != null && _title.text.trim().isEmpty) {
      _title.text = fresh.title;
    }
    _toast('${picked.displayName} joined this chat.');
  }

  /// The background chooser: an in-app gallery is not built yet, so that route
  /// says so rather than pretending. A picked file is written to the pictures
  /// directory straight away and only its reference is held as a draft.
  Future<void> _pickBackground() async {
    final source = await showModalBottomSheet<_BackgroundSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Gallery'),
              subtitle: const Text('Coming soon — pictures kept in the app'),
              onTap: () =>
                  Navigator.of(context).pop(_BackgroundSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Files'),
              subtitle: const Text('Choose a picture from this device'),
              onTap: () => Navigator.of(context).pop(_BackgroundSource.files),
            ),
            if (_background != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Remove background'),
                onTap: () =>
                    Navigator.of(context).pop(_BackgroundSource.remove),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    switch (source) {
      case _BackgroundSource.gallery:
        _toast('The gallery is coming soon — use Files for now.');
      case _BackgroundSource.remove:
        setState(() => _background = null);
      case _BackgroundSource.files:
        await _pickBackgroundFile();
    }
  }

  Future<void> _pickBackgroundFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.first.bytes;
    if (bytes == null || bytes.isEmpty || !mounted) return;
    final ref = await context.read<AppState>().storePicture(bytes);
    if (!mounted) return;
    if (ref == null) {
      _toast('That picture could not be stored.');
      return;
    }
    setState(() => _background = ref);
  }

  /// Opens the app's own Chat Interface editor, pointed at this chat's copy.
  /// Seeded from the app-wide settings, and an untouched copy is dropped again
  /// on the way out — otherwise merely *looking* would pin the chat to a frozen
  /// style that later app-wide changes never reach.
  Future<void> _editAppearance() async {
    final global = context.read<AppState>().chatInterface;
    final draft = ValueNotifier<ChatInterface>(_appearance ?? global);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatInterfaceSettingsPage(
          scope: ChatUiScope(
            draft: draft,
            title: 'Chat appearance',
            note: 'These settings apply to this chat only. Saving gives the '
                'chat a full copy of the app-wide Chat Interface settings, so '
                'later app-wide changes will not reach it — Reset puts the chat '
                'back on the shared settings.',
          ),
        ),
      ),
    );
    final result = draft.value;
    draft.dispose();
    if (!mounted) return;
    setState(() => _appearance = result == global ? null : result);
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

  /// Writes the screen. Pending character edits are asked about first, and a
  /// cancelled question cancels the whole save — the alternative is silently
  /// keeping half of what the user asked for.
  Future<void> _save() async {
    final state = context.read<AppState>();
    final conversation = _conversation(state);
    if (conversation == null) return;

    Map<String, CharacterSaveTarget>? targets;
    if (_edits.isNotEmpty) {
      targets = await showDialog<Map<String, CharacterSaveTarget>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CharacterSaveDialog(edits: _edits.values.toList()),
      );
      if (targets == null || !mounted) return;
    }

    final title = _title.text.trim();
    if (title.isNotEmpty && title != conversation.title) {
      await state.renameConversation(conversation.id, title);
    }
    if (_background != conversation.backgroundImage ||
        _opacity != conversation.backgroundOpacity) {
      await state.setChatBackground(
        conversation.id,
        _background,
        opacity: _opacity,
      );
    }
    if (_appearance == null) {
      if (conversation.interfaceOverride != null) {
        await state.clearChatInterfaceOverride(conversation.id);
      }
    } else if (_appearance != conversation.interfaceOverride) {
      await state.saveChatInterfaceOverride(conversation.id, _appearance!);
    }

    for (final entry in (targets ?? const <String, CharacterSaveTarget>{})
        .entries) {
      final character = _edits[entry.key];
      if (character == null) continue;
      switch (entry.value) {
        case CharacterSaveTarget.chat:
          await state.saveChatCharacterOverride(conversation.id, character);
        case CharacterSaveTarget.global:
          await state.saveCharacter(character);
          await state.clearChatCharacterOverride(conversation.id, character.id);
      }
    }

    // Last, and unconditionally: storing an override switches overriding on by
    // itself, so the toggle is applied afterwards to make sure the chat ends up
    // exactly as the screen showed it.
    if (_overrideDefinitions != conversation.overrideDefinitions) {
      await state.setOverrideDefinitions(conversation.id, _overrideDefinitions);
    }

    if (!mounted) return;
    _edits.clear();
    Navigator.of(context).pop();
  }

  /// Guards the back arrow when there is unsaved work.
  Future<bool> _confirmDiscard(Conversation conversation) async {
    if (!_dirty(conversation)) return true;
    return _confirm(
      title: 'Discard changes?',
      body: 'This chat\'s settings have unsaved changes.',
      action: 'Discard',
    );
  }

  /// The back arrow / system back gesture: asks before throwing work away.
  Future<void> _handlePop(bool didPop, Conversation conversation) async {
    if (didPop) return;
    final leave = await _confirmDiscard(conversation);
    if (leave && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final conversation = _conversation(state);
    // The thread was deleted from under this screen.
    if (conversation == null) {
      return const Scaffold(body: Center(child: Text('This chat is gone.')));
    }
    final scheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _handlePop(didPop, conversation),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Chat settings'),
          centerTitle: true,
          actions: [TextButton(onPressed: _save, child: const Text('Save'))],
        ),
        body: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            12,
            16,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          children: _sections(context, state, conversation, scheme),
        ),
      ),
    );
  }

  List<Widget> _sections(
    BuildContext context,
    AppState state,
    Conversation conversation,
    ColorScheme scheme,
  ) =>
      [
        TextField(
          controller: _title,
          autofocus: false,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Chat title',
            prefixIcon: Icon(Icons.title_outlined),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        _BackgroundCard(
          image: _background,
          opacity: _opacity,
          onPick: _pickBackground,
          onOpacity: (v) => setState(() => _opacity = v),
        ),
        const SizedBox(height: 4),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Custom chat appearance'),
          subtitle: Text(_appearance == null
              ? 'Following the app-wide Chat Interface settings'
              : 'This chat has a style of its own'),
          trailing: _appearance == null
              ? const Icon(Icons.chevron_right)
              : TextButton(
                  onPressed: () => setState(() => _appearance = null),
                  child: const Text('Reset'),
                ),
          onTap: _editAppearance,
        ),
        const Divider(height: 32),
        Row(
          children: [
            Expanded(
              child: Text(
                'Characters involved',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            IconButton.filledTonal(
              tooltip: 'Add a character',
              icon: const Icon(Icons.add),
              onPressed: () => _addParticipant(conversation),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _overrideDefinitions,
          onChanged: (v) => setState(() => _overrideDefinitions = v),
          secondary: const Icon(Icons.edit_note_outlined),
          title: const Text('Enable overriding definitions'),
          subtitle: const Text('Edit a character for this chat alone, leaving '
              'the saved card as it is'),
        ),
        for (final participant in _participants(state, conversation))
          _ParticipantTile(
            participant: participant,
            edited: participant.character != null &&
                _edits.containsKey(participant.character!.id),
            overridden: participant.character != null &&
                conversation.characterOverrides
                    .containsKey(participant.character!.id),
            canEdit: _overrideDefinitions && participant.character != null,
            onEdit: participant.character == null
                ? null
                : () => _editCharacter(participant.character!),
            onRemove: participant.removable
                ? () => _removeParticipant(participant)
                : null,
          ),
        if (_edits.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '${_edits.length} character '
              '${_edits.length == 1 ? 'change' : 'changes'} waiting — Save asks '
              'where each one goes.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.primary),
            ),
          ),
      ];
}

/// Where a background picture can come from.
enum _BackgroundSource { gallery, files, remove }

/// The background row: a preview of what is set, a tap to change it, and — once
/// there is a picture — how strongly it shows through. A photo at full strength
/// behind running text is unreadable, which is the whole reason the fade exists.
class _BackgroundCard extends StatelessWidget {
  const _BackgroundCard({
    required this.image,
    required this.opacity,
    required this.onPick,
    required this.onOpacity,
  });

  final String? image;
  final double opacity;
  final VoidCallback onPick;
  final ValueChanged<double> onOpacity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final provider = image == null
        ? null
        : avatarImage(
            image!,
            displaySize: 96,
            devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: SizedBox(
            width: 48,
            height: 48,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: scheme.surfaceContainerHighest,
                image: provider == null
                    ? null
                    : DecorationImage(image: provider, fit: BoxFit.cover),
              ),
              child: provider == null
                  ? Icon(Icons.image_outlined, color: scheme.onSurfaceVariant)
                  : null,
            ),
          ),
          title: const Text('Custom background'),
          subtitle: Text(image == null
              ? 'No picture behind this chat'
              : 'A picture of its own'),
          trailing: const Icon(Icons.chevron_right),
          onTap: onPick,
        ),
        if (image != null)
          Row(
            children: [
              Icon(Icons.opacity_outlined,
                  size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Slider(
                  value: opacity.clamp(0.05, 1),
                  min: 0.05,
                  max: 1,
                  onChanged: onOpacity,
                ),
              ),
              Text('${(opacity * 100).round()}%',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      )),
            ],
          ),
      ],
    );
  }
}

/// One row of "Characters involved": who it is, what has been done to them here,
/// and a three-dot menu with Edit and Remove.
class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.participant,
    required this.edited,
    required this.overridden,
    required this.canEdit,
    required this.onEdit,
    required this.onRemove,
  });

  final _Participant participant;

  /// An edit is waiting to be saved.
  final bool edited;

  /// This chat already carries its own definition of them.
  final bool overridden;

  /// Editing needs the overriding toggle on, so the menu says so when it is off.
  final bool canEdit;

  final VoidCallback? onEdit;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final character = participant.character;
    final subtitle = <String>[
      participant.role,
      if (edited) 'edit pending',
      if (!edited && overridden) 'edited for this chat',
      if (character == null && participant.isUser) 'speaking as yourself',
      if (character == null && !participant.isUser) 'card no longer saved',
    ].join(' · ');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: character == null
          ? CircleAvatar(
              backgroundColor: scheme.secondaryContainer,
              child: Icon(
                participant.isUser
                    ? Icons.person_outline
                    : Icons.help_outline,
                color: scheme.onSecondaryContainer,
              ),
            )
          : CharacterAvatar(character: character, radius: 20),
      title: Text(character?.displayName ?? participant.placeholder ?? 'You'),
      subtitle: Text(subtitle),
      trailing: onRemove == null && onEdit == null
          ? null
          : PopupMenuButton<_ParticipantAction>(
              icon: const Icon(Icons.more_vert),
              onSelected: (action) {
                switch (action) {
                  case _ParticipantAction.edit:
                    onEdit?.call();
                  case _ParticipantAction.remove:
                    onRemove?.call();
                }
              },
              itemBuilder: (_) => [
                if (onEdit != null)
                  PopupMenuItem(
                    value: _ParticipantAction.edit,
                    enabled: canEdit,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.edit_outlined),
                      title: const Text('Edit'),
                      subtitle: canEdit
                          ? null
                          : const Text('Needs overriding definitions on'),
                    ),
                  ),
                if (onRemove != null)
                  const PopupMenuItem(
                    value: _ParticipantAction.remove,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.person_remove_outlined),
                      title: Text('Remove'),
                    ),
                  ),
              ],
            ),
    );
  }
}

enum _ParticipantAction { edit, remove }

/// Picks a character to attach to a chat that has none.
class _CharacterPickerSheet extends StatelessWidget {
  const _CharacterPickerSheet({required this.characters});

  final List<Character> characters;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          for (final character in characters)
            ListTile(
              leading: CharacterAvatar(character: character, radius: 20),
              title: Text(character.displayName),
              subtitle: character.blurb.isEmpty
                  ? null
                  : Text(character.blurb, maxLines: 1,
                      overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.of(context).pop(character),
            ),
        ],
      ),
    );
  }
}

/// Asks where each pending character edit belongs. Returns a target per
/// character id, or null when the whole save is called off.
///
/// A change to a card is genuinely ambiguous — the same edit can mean "this
/// chat's version of them" or "this is who they are now" — so it is not guessed.
/// Every row must be answered before the dialog's own Save will finish.
class CharacterSaveDialog extends StatefulWidget {
  const CharacterSaveDialog({super.key, required this.edits});

  final List<Character> edits;

  @override
  State<CharacterSaveDialog> createState() => _CharacterSaveDialogState();
}

class _CharacterSaveDialogState extends State<CharacterSaveDialog> {
  final Map<String, CharacterSaveTarget> _targets =
      <String, CharacterSaveTarget>{};
  bool _nagging = false;

  List<Character> get _unresolved =>
      widget.edits.where((c) => !_targets.containsKey(c.id)).toList();

  void _finish() {
    if (_unresolved.isNotEmpty) {
      setState(() => _nagging = true);
      return;
    }
    Navigator.of(context).pop(Map<String, CharacterSaveTarget>.of(_targets));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = widget.edits.length;
    return AlertDialog(
      title: Text('You have made changes for $count '
          '${count == 1 ? 'character' : 'characters'}:'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final character in widget.edits)
              _SaveRow(
                name: character.displayName,
                target: _targets[character.id],
                highlight: _nagging && !_targets.containsKey(character.id),
                onChosen: (t) => setState(() {
                  _targets[character.id] = t;
                  if (_unresolved.isEmpty) _nagging = false;
                }),
              ),
            if (_nagging)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Address the following changes before saving: '
                  '${_unresolved.map((c) => c.displayName).join(', ')}.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _finish, child: const Text('Save')),
      ],
    );
  }
}

/// One character's row in the save dialog: their name, and a `Save ▾` control
/// that turns into what was chosen. Tapping it again changes the answer.
class _SaveRow extends StatelessWidget {
  const _SaveRow({
    required this.name,
    required this.target,
    required this.highlight,
    required this.onChosen,
  });

  final String name;
  final CharacterSaveTarget? target;

  /// Outlined in the error colour after a save was refused for want of an answer.
  final bool highlight;

  final ValueChanged<CharacterSaveTarget> onChosen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chosen = target;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: highlight ? scheme.error : null),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<CharacterSaveTarget>(
            tooltip: chosen == null ? 'Choose where to save' : 'Change',
            onSelected: onChosen,
            itemBuilder: (_) => [
              for (final t in CharacterSaveTarget.values)
                PopupMenuItem<CharacterSaveTarget>(
                  value: t,
                  child: Text(t.label),
                ),
            ],
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: chosen == null
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                border: highlight
                    ? Border.all(color: scheme.error, width: 1.5)
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (chosen != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.check,
                          size: 16, color: scheme.onSurfaceVariant),
                    ),
                  Text(
                    chosen?.done ?? 'Save',
                    style: TextStyle(
                      color: chosen == null
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Icon(
                    Icons.expand_more,
                    size: 18,
                    color: chosen == null
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

