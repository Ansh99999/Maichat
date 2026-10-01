import 'package:flutter/material.dart';

import '../../models/character.dart';
import '../../models/studio.dart';
import '../../services/studio/studio_controller.dart';
import '../../widgets/message_markdown.dart';
import 'draft/draft_widgets.dart';
import 'shell/area_pages.dart';
import 'shell/studio_chrome.dart';

/// Which Playground chat is on screen — shared by the page, which draws it,
/// and the dock's [PlaygroundComposer], which writes into it. Null means none
/// yet: the first line sent starts one.
class PlaygroundSelection extends ValueNotifier<String?> {
  PlaygroundSelection([super.value]);

  /// The chat on screen: the one chosen, or — when none is, or it is gone —
  /// the newest, so a playtest an agent files appears without a tap.
  StudioPlaytest? resolve(StudioController controller) {
    final chosen = value == null ? null : controller.session.playtest(value!);
    if (chosen != null) return chosen;
    final all = controller.playtests;
    return all.isEmpty ? null : all.first;
  }
}

/// The Playground: the draft played as a chat, through the user's real chat
/// setup (preset, persona, model, the draft's lorebooks) — the user's own
/// chats with it, and every playtest an agent ran, kept where the user can
/// read what was tested.
///
/// A page *body*. The chats sit in a strip beside the floating menu square,
/// newest first, with "New" ahead of them; the chat on screen runs from the
/// bottom up, as a chat does, under the dock's composer.
class StudioPlaygroundView extends StatelessWidget {
  const StudioPlaygroundView({
    super.key,
    required this.controller,
    required this.selection,
  });

  final StudioController controller;
  final PlaygroundSelection selection;

  Future<void> _newChat(BuildContext context) async {
    final greetings = controller.session.workspace.character.greetings;
    var index = 0;
    if (greetings.length > 1) {
      final picked = await showModalBottomSheet<int>(
        context: context,
        showDragHandle: true,
        builder: (sheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  'Start from which greeting?',
                  style: Theme.of(sheet).textTheme.titleMedium,
                ),
              ),
              for (var i = 0; i < greetings.length; i++)
                ListTile(
                  key: Key('playground-greeting-$i'),
                  leading: Icon(i == 0 ? Icons.waving_hand_outlined : Icons.swipe),
                  title: Text(i == 0 ? 'First message' : 'Alternate greeting $i'),
                  subtitle: Text(
                    greetings[i].replaceAll(RegExp(r'\s+'), ' ').trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.of(sheet).pop(i),
                ),
            ],
          ),
        ),
      );
      if (picked == null) return;
      index = picked;
    }
    selection.value = controller.newPlaygroundChat(greetingIndex: index).id;
  }

  Future<void> _chatMenu(BuildContext context, StudioPlaytest test) async {
    final remove = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListTile(
          key: const Key('playground-delete'),
          leading: const Icon(Icons.delete_outline),
          title: Text('Remove "${test.displayTitle}"'),
          onTap: () => Navigator.of(sheet).pop(true),
        ),
      ),
    );
    if (remove != true) return;
    controller.deletePlaytest(test.id);
    if (selection.value == test.id) {
      final rest = controller.playtests;
      selection.value = rest.isEmpty ? null : rest.first.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ActiveListenableBuilder(
      listenable: controller,
      builder: (context) => ValueListenableBuilder<String?>(
        valueListenable: selection,
        builder: (context, _, _) {
          final tests = controller.playtests;
          final current = selection.resolve(controller);
          final chrome = context
              .dependOnInheritedWidgetOfExactType<StudioChrome>();
          return Column(
            children: [
              _ChatStrip(
                chrome: chrome,
                tests: tests,
                selected: current?.id,
                busy: controller.playgroundBusy,
                onNew: () => _newChat(context),
                onSelect: (id) => selection.value = id,
                onMenu: (t) => _chatMenu(context, t),
              ),
              Expanded(
                child: current == null
                    ? _Empty(bottom: chrome?.bottom ?? 0)
                    : _Transcript(
                        key: ValueKey('playground-transcript-${current.id}'),
                        controller: controller,
                        test: current,
                        bottom: chrome?.bottom ?? 0,
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The chats, in the row beside the menu square: "New", then each chat as a
/// pill — a person for the user's, a robot for an agent's.
class _ChatStrip extends StatelessWidget {
  const _ChatStrip({
    required this.chrome,
    required this.tests,
    required this.selected,
    required this.busy,
    required this.onNew,
    required this.onSelect,
    required this.onMenu,
  });

  final StudioChrome? chrome;
  final List<StudioPlaytest> tests;
  final String? selected;
  final String? busy;
  final VoidCallback onNew;
  final ValueChanged<String> onSelect;
  final ValueChanged<StudioPlaytest> onMenu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = chrome == null ? 8.0 : chrome!.statusBar + StudioChrome.buttonTop;
    final left = chrome == null ? 12.0 : StudioChrome.side - 4;
    final right = chrome != null && chrome!.rightButton ? StudioChrome.side - 4 : 12.0;
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: 8),
      child: SizedBox(
        height: StudioChrome.buttonSize,
        child: ListView(
          key: const Key('playground-strip'),
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.only(left: left, right: right),
          children: [
            Center(
              child: FilledButton.tonalIcon(
                key: const Key('playground-new'),
                onPressed: onNew,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New chat'),
              ),
            ),
            for (final t in tests)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Center(
                  child: GestureDetector(
                    onLongPress: () => onMenu(t),
                    child: ChoiceChip(
                      key: Key('playground-chat-${t.id}'),
                      selected: t.id == selected,
                      showCheckmark: false,
                      shape: const StadiumBorder(),
                      side: BorderSide(color: scheme.outlineVariant),
                      avatar: Icon(
                        busy == t.id
                            ? Icons.more_horiz
                            : t.byUser
                                ? Icons.person_outline
                                : Icons.smart_toy_outlined,
                        size: 18,
                      ),
                      label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(
                          t.byUser
                              ? t.displayTitle
                              : '${_agentName(t.by)} · ${t.displayTitle}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      onSelected: (_) => onSelect(t.id),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _agentName(String by) => by == 'the main agent' ? 'Main' : by;

class _Empty extends StatelessWidget {
  const _Empty({required this.bottom});

  final double bottom;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 24, 16, bottom + 16),
      children: const [
        DraftEmpty(
          icon: Icons.sports_esports_outlined,
          text: 'Talk to the draft as it stands, through your own chat '
              'setup — preset, persona, model and the draft\'s lorebooks. '
              'Nothing here reaches your library. The Studio\'s playtests '
              'show up here too, so you can read what it tried.',
        ),
      ],
    );
  }
}

/// One chat, newest line at the bottom.
class _Transcript extends StatelessWidget {
  const _Transcript({
    super.key,
    required this.controller,
    required this.test,
    required this.bottom,
  });

  final StudioController controller;
  final StudioPlaytest test;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final character = controller.session.workspace.character;
    final userName = controller.state.playtestUserName(character);
    final busy = controller.playgroundBusy == test.id;
    final lastReply = test.turns.lastIndexWhere((t) => !t.user);
    final children = <Widget>[
      _Header(test: test),
      for (var i = 0; i < test.turns.length; i++)
        test.turns[i].user
            ? _UserLine(text: test.turns[i].text)
            : _CharacterLine(
                name: character.displayName,
                text: _resolve(test.turns[i].text, character, userName),
                error: test.turns[i].error,
                // The user's own chat can have its last reply written again.
                onRetry: test.byUser &&
                        !busy &&
                        controller.playgroundBusy == null &&
                        i == lastReply &&
                        i == test.turns.length - 1 &&
                        i > 0
                    ? () => controller.playgroundRetry(test.id)
                    : null,
              ),
      if (busy)
        _CharacterLine(
          key: const Key('playground-live'),
          name: character.displayName,
          text: controller.playgroundLive,
          writing: true,
        ),
    ];
    // Bottom-anchored like a chat: the newest line sits over the composer.
    return ListView(
      key: PageStorageKey('playground-${test.id}'),
      reverse: true,
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottom + 12),
      children: children.reversed.toList(),
    );
  }

  static String _resolve(String text, Character c, String userName) =>
      Character.resolveMacros(text, charName: c.displayName, userName: userName);
}

/// What a chat is: whose, and — for an agent's — who it played and where.
class _Header extends StatelessWidget {
  const _Header({required this.test});

  final StudioPlaytest test;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lines = <String>[
      test.byUser
          ? 'Your chat with the draft'
          : 'Playtest by ${_agentName(test.by)}',
      if (test.persona.isNotEmpty) 'Playing: ${test.persona}',
      if (test.scenario.isNotEmpty) 'Scenario: ${test.scenario}',
      if (test.greetingIndex > 0) 'From alternate greeting ${test.greetingIndex}',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              test.byUser ? Icons.person_outline : Icons.smart_toy_outlined,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(lines.first, style: theme.textTheme.titleSmall),
                  for (final line in lines.skip(1))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        line,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
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

class _UserLine extends StatelessWidget {
  const _UserLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.fromLTRB(56, 6, 0, 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(22),
        ),
        child: SelectableText(
          text,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: scheme.onPrimaryContainer),
        ),
      ),
    );
  }
}

class _CharacterLine extends StatelessWidget {
  const _CharacterLine({
    super.key,
    required this.name,
    required this.text,
    this.error = false,
    this.writing = false,
    this.onRetry,
  });

  final String name;
  final String text;
  final bool error;
  final bool writing;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
      color: error ? scheme.onErrorContainer : scheme.onSurface,
      height: 1.45,
    );
    final styles = MarkdownStyles(
      base: base,
      emphasis: error ? scheme.onErrorContainer : scheme.onSurfaceVariant,
      quote: scheme.onSurface,
      codeBackground: scheme.surfaceContainerHighest,
      codeForeground: scheme.onSurface,
      link: scheme.primary,
    );
    final body = writing && text.isEmpty
        ? Text('…', style: base.copyWith(color: scheme.onSurfaceVariant))
        : SelectableText.rich(TextSpan(children: buildMessageSpans(text, styles)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 24, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name.isEmpty ? 'The character' : name,
            style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary),
          ),
          const SizedBox(height: 6),
          if (error)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: body,
            )
          else
            body,
          if (onRetry != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: TextButton.icon(
                key: const Key('playground-retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Write again'),
              ),
            ),
        ],
      ),
    );
  }
}

/// What the dock shows on the Playground: a line to send the draft — or, while
/// an agent's playtest is on screen, a note that it is read-only and the way to
/// a chat of the user's own.
class PlaygroundComposer extends StatefulWidget {
  const PlaygroundComposer({
    super.key,
    required this.controller,
    required this.selection,
  });

  final StudioController controller;
  final PlaygroundSelection selection;

  @override
  State<PlaygroundComposer> createState() => _PlaygroundComposerState();
}

class _PlaygroundComposerState extends State<PlaygroundComposer> {
  final TextEditingController _input = TextEditingController();

  StudioController get _c => widget.controller;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _c.playgroundBusy != null) return;
    final current = widget.selection.resolve(_c);
    final String id;
    if (current == null || !current.byUser) {
      id = _c.newPlaygroundChat().id;
      widget.selection.value = id;
    } else {
      id = current.id;
    }
    _input.clear();
    _c.playgroundSend(id, text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([_c, widget.selection]),
      builder: (context, _) {
        final current = widget.selection.resolve(_c);
        final busy = _c.playgroundBusy != null;
        if (current != null && !current.byUser) {
          return Container(
            key: const Key('playground-readonly'),
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Row(
              children: [
                Icon(Icons.smart_toy_outlined,
                    size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${_agentName(current.by)}\'s playtest · read-only',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                FilledButton.tonalIcon(
                  key: const Key('playground-own-chat'),
                  onPressed: () {
                    final mine = _c.playtests.where((t) => t.byUser).firstOrNull;
                    widget.selection.value =
                        (mine ?? _c.newPlaygroundChat()).id;
                  },
                  icon: const Icon(Icons.person_outline, size: 18),
                  label: const Text('Your chat'),
                ),
              ],
            ),
          );
        }
        return Container(
          key: const Key('playground-composer'),
          margin: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          padding: const EdgeInsets.fromLTRB(20, 4, 6, 4),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: TextField(
                    key: const Key('playground-input'),
                    controller: _input,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Say something to the draft',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              busy
                  ? IconButton.filledTonal(
                      key: const Key('playground-stop'),
                      tooltip: 'Stop',
                      onPressed: _c.stopPlayground,
                      icon: const Icon(Icons.stop_rounded),
                    )
                  : IconButton.filled(
                      key: const Key('playground-send'),
                      tooltip: 'Send',
                      onPressed: _send,
                      icon: const Icon(Icons.arrow_upward_rounded),
                    ),
            ],
          ),
        );
      },
    );
  }
}
