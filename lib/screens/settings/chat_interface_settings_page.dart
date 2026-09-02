import 'package:flutter/material.dart';

import '../../models/chat_interface.dart';
import '../../widgets/interface_preset_sheet.dart';
import 'chat_interface/actions_page.dart';
import 'chat_interface/avatars_page.dart';
import 'chat_interface/colours_page.dart';
import 'chat_interface/group_bar_page.dart';
import 'chat_interface/layout_page.dart';
import 'chat_interface/names_page.dart';
import 'chat_interface/spoke.dart';
import 'chat_interface/text_page.dart';
import 'chat_ui_scope.dart';
import 'chat_interface_preview.dart';
import 'setting_anchors.dart';
import 'setting_highlight.dart';

/// The "Chat Interface" section: a hub of six spokes, each a short page about one
/// thing, each carrying a summary of where it currently stands.
///
/// It used to be one flat list of nine sections and some sixty-six rows, which
/// meant a fling past everything to reach the bottom and no way to see at a
/// glance what a chat was set to. The eye in the app bar still opens the live
/// mock chat, from here and from every spoke.
///
/// Given a [scope] it edits that draft instead of the app-wide settings — the
/// same hub and the same spokes, serving the per-chat copy from the Chat settings
/// screen. Nothing app-wide-only appears on these pages, so in that scope every
/// row is one that applies.
class ChatInterfaceSettingsPage extends StatelessWidget {
  const ChatInterfaceSettingsPage({super.key, this.highlight, this.scope});

  final SettingAnchor? highlight;
  final ChatUiScope? scope;

  @override
  Widget build(BuildContext context) {
    return ChatUiBuilder(
      scope: scope,
      builder: (context, ui, _) => Scaffold(
        appBar: AppBar(
          title: Text(scope?.title ?? 'Chat Interface'),
          actions: [
            // Only app-wide: from a chat's own copy this page is editing a draft,
            // and a sheet that wrote somewhere else while a draft was open would
            // be two answers to one question.
            if (scope == null)
              IconButton(
                tooltip: 'Looks',
                icon: const Icon(Icons.style_outlined),
                onPressed: () => showInterfacePresetSheet(context),
              ),
            IconButton(
              tooltip: 'Preview',
              icon: const Icon(Icons.visibility_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChatInterfacePreviewPage(scope: scope),
                ),
              ),
            ),
          ],
        ),
        body: _list(context, ui),
      ),
    );
  }
  Widget _list(BuildContext context, ChatInterface ui) {
    final spokes = <_Spoke>[
      _Spoke(
        icon: Icons.dashboard_outlined,
        title: 'Layout & spacing',
        summary: _layoutSummary(ui),
        changed: _layoutChanges(ui),
        anchors: const {
          SettingAnchor.textPlacement,
          SettingAnchor.spacing,
          SettingAnchor.floatingButtons,
        },
        open: (a) => LayoutSpokePage(highlight: a, scope: scope),
      ),
      _Spoke(
        icon: Icons.account_circle_outlined,
        title: 'Avatars',
        summary: _avatarSummary(ui),
        changed: _avatarChanges(ui),
        anchors: const {SettingAnchor.chatAvatars},
        open: (a) => AvatarsSpokePage(highlight: a, scope: scope),
      ),
      _Spoke(
        icon: Icons.badge_outlined,
        title: 'Names',
        summary: _nameSummary(ui),
        changed: _nameChanges(ui),
        anchors: const {SettingAnchor.names},
        open: (a) => NamesSpokePage(highlight: a, scope: scope),
      ),
      _Spoke(
        icon: Icons.palette_outlined,
        title: 'Colours',
        summary: _colourSummary(ui),
        changed: _colourChanges(ui),
        anchors: const {SettingAnchor.chatColours},
        open: (a) => ColoursSpokePage(highlight: a, scope: scope),
      ),
      _Spoke(
        icon: Icons.text_fields_outlined,
        title: 'Text',
        summary: _textSummary(ui),
        changed: _textChanges(ui),
        anchors: const {},
        open: (a) => TextSpokePage(highlight: a, scope: scope),
      ),
      _Spoke(
        icon: Icons.more_horiz,
        title: 'Message actions',
        summary: _actionSummary(ui),
        changed: _actionChanges(ui),
        anchors: const {SettingAnchor.messageActions},
        open: (a) => ActionsSpokePage(highlight: a, scope: scope),
      ),
    ];
    // The participant bar is only a thing while group chats are switched on, so
    // the row is simply not there otherwise — rather than leading to a page of
    // controls that draw nothing.
    if (ui.groupChatsEnabled) {
      spokes.add(_Spoke(
        icon: Icons.groups_outlined,
        title: 'Group chat bar',
        summary: _groupBarSummary(ui),
        changed: _groupBarChanges(ui),
        anchors: const {SettingAnchor.groupChats},
        open: (a) => GroupBarSpokePage(highlight: a, scope: scope),
      ));
    }

    return ListView(
      padding: EdgeInsets.only(bottom: 16 + MediaQuery.paddingOf(context).bottom),
      children: [
        if (scope?.note != null) _ScopeNote(text: scope!.note!),
        for (final spoke in spokes)
          SettingHighlight(
            active: highlight != null && spoke.anchors.contains(highlight),
            child: _SpokeTile(
              spoke: spoke,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => spoke.open(null)),
              ),
            ),
          ),
      ],
    );
  }
}

/// One row of the hub, and how to reach the page behind it.
class _Spoke {
  const _Spoke({
    required this.icon,
    required this.title,
    required this.summary,
    required this.changed,
    required this.anchors,
    required this.open,
  });

  final IconData icon;
  final String title;

  /// Where this spoke currently stands, in the voice the Settings hub uses.
  final String summary;

  /// How many of this spoke's settings differ from the defaults.
  final int changed;

  /// The search anchors this spoke owns, so a deep link flashes the right row.
  final Set<SettingAnchor> anchors;

  final Widget Function(SettingAnchor? highlight) open;
}
/// A hub row: tinted icon, title, the current-value summary, a count of what has
/// been changed away from the defaults, and the chevron that says there is more
/// inside. Deliberately the same shape as the top-level Settings rows.
class _SpokeTile extends StatelessWidget {
  const _SpokeTile({required this.spoke, required this.onTap});

  final _Spoke spoke;
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
        child: Icon(spoke.icon, color: scheme.onSecondaryContainer, size: 22),
      ),
      title: Text(spoke.title),
      subtitle: Text(spoke.summary),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spoke.changed > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                '${spoke.changed} changed',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Says whose settings the hub is editing, when it is not the app-wide ones.
class _ScopeNote extends StatelessWidget {
  const _ScopeNote({required this.text});

  final String text;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Icon(Icons.info_outline,
                size: 18, color: scheme.onSecondaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Summaries and change counts -------------------------------------------
//
// A summary answers "what is this set to?" without opening the page; the count
// answers "did I change anything in there?". The counts treat an `AvatarStyle`
// or a `NameStyle` as one setting rather than picking them apart — they are a
// hint that something was touched, not an audit.

const ChatInterface _d = ChatInterface();

String _layoutSummary(ChatInterface ui) => [
      ui.bubbles ? 'Bubbles' : 'Document',
      ui.textPlacement.label,
      ui.contentWidth.label,
      '${ui.messageSpacing.round()} px gap',
    ].join(' · ');

int _layoutChanges(ChatInterface ui) =>
    (ui.bubbles != _d.bubbles ? 1 : 0) +
    (ui.textPlacement != _d.textPlacement ? 1 : 0) +
    (ui.contentWidth != _d.contentWidth ? 1 : 0) +
    (ui.bubbleOpacity != _d.bubbleOpacity ? 1 : 0) +
    (ui.messageSpacing != _d.messageSpacing ? 1 : 0) +
    (ui.menuButtonOpacity != _d.menuButtonOpacity ? 1 : 0) +
    (ui.jumpButtonOpacity != _d.jumpButtonOpacity ? 1 : 0) +
    (ui.looksButtonOpacity != _d.looksButtonOpacity ? 1 : 0);
String _avatarSummary(ChatInterface ui) {
  final bot = ui.botAvatar;
  final user = ui.userAvatar;
  if (!bot.show && !user.show) return 'Both hidden';
  final shown = bot.show && user.show
      ? (ui.syncAvatars ? 'Both, synced' : 'Both')
      : (bot.show ? 'Character only' : 'You only');
  final ref = bot.show ? bot : user;
  return '$shown · ${ref.size.round()} px · ${ref.shape.label}';
}

int _avatarChanges(ChatInterface ui) =>
    (ui.botAvatar != _d.botAvatar ? 1 : 0) +
    (ui.userAvatar != _d.userAvatar ? 1 : 0) +
    (ui.syncAvatars != _d.syncAvatars ? 1 : 0);

String _nameSummary(ChatInterface ui) {
  if (!ui.showNames) return 'Hidden';
  final where = ui.botNameStyle.position == NamePosition.above
      ? 'above the message'
      : 'below the avatar';
  return '${ui.syncNames ? 'Shown · synced' : 'Shown'} · $where';
}

int _nameChanges(ChatInterface ui) =>
    (ui.showNames != _d.showNames ? 1 : 0) +
    (ui.syncNames != _d.syncNames ? 1 : 0) +
    (ui.botNameStyle != _d.botNameStyle ? 1 : 0) +
    (ui.userNameStyle != _d.userNameStyle ? 1 : 0);

String _colourSummary(ChatInterface ui) {
  final n = _colourChanges(ui);
  if (n == 0) return 'All following the theme';
  return 'Theme, with $n overridden';
}

int _colourChanges(ChatInterface ui) =>
    (ui.userTextColor != null ? 1 : 0) +
    (ui.botTextColor != null ? 1 : 0) +
    (ui.userBubbleColor != null ? 1 : 0) +
    (ui.botBubbleColor != null ? 1 : 0) +
    (ui.backgroundColor != null ? 1 : 0);

String _textSummary(ChatInterface ui) {
  final rules = ui.textWrapRules.length;
  return [
    '${ui.fontSize.round()} px',
    'Markdown ${ui.markdown ? 'on' : 'off'}',
    if (rules > 0) '$rules wrapping ${rules == 1 ? 'rule' : 'rules'}',
  ].join(' · ');
}

int _textChanges(ChatInterface ui) =>
    (ui.fontSize != _d.fontSize ? 1 : 0) +
    (ui.markdown != _d.markdown ? 1 : 0) +
    (ui.emphasisColor != null ? 1 : 0) +
    (ui.quoteColor != null ? 1 : 0) +
    (ui.textWrapRules.isNotEmpty ? 1 : 0);
String _actionSummary(ChatInterface ui) {
  if (!ui.messageActionsEnabled) return 'Hidden';
  final inline = ui.inlineActions.length;
  final menu = ui.overflowActions.length;
  return '$inline inline · $menu in the menu';
}

int _actionChanges(ChatInterface ui) =>
    (ui.messageActionsEnabled != _d.messageActionsEnabled ? 1 : 0) +
    (ui.actionBarPlacement != _d.actionBarPlacement ? 1 : 0) +
    (_sameActions(ui.messageActions, _d.messageActions) ? 0 : 1);

bool _sameActions(List<MessageActionPref> a, List<MessageActionPref> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _groupBarSummary(ChatInterface ui) => [
      '${ui.groupBarHeight.round()} px',
      if (ui.groupBarColor != null) 'recoloured',
      if (ui.groupBarImage != null) 'with a picture',
    ].join(' · ');

int _groupBarChanges(ChatInterface ui) =>
    (ui.groupBarHeight != _d.groupBarHeight ? 1 : 0) +
    (ui.groupBarColor != null ? 1 : 0) +
    (ui.groupBarImage != null ? 1 : 0);






