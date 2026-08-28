import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/character.dart';
import '../models/message.dart';
import '../state/app_state.dart';
import '../widgets/message_bubble.dart';
import '../widgets/rich_notes_view.dart';
import '../widgets/scenario_picker_sheet.dart';
import '../services/rich_notes.dart';

/// The character sheet's blocks, kept out of the screen file so each stays small
/// enough to read: the tag band, the creator-notes block, the thin rule, and the
/// definition folds (scenario with its custom-scenario editor, description, and
/// the greetings rendered exactly as the chat renders them).

/// The tags as a single horizontally scrolling line, so a card with thirty tags
/// takes one row rather than eight.
class TagBand extends StatelessWidget {
  const TagBand({super.key, required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            for (final tag in tags)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Chip(
                  label: Text(tag),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The creator's notes: their own HTML/CSS when they wrote any, plain text
/// otherwise. Long plain notes collapse behind "Read more"; rich notes are shown
/// whole, because clipping a designed card mid-way looks broken.
class NotesBlock extends StatefulWidget {
  const NotesBlock({super.key, required this.character});

  final Character character;

  @override
  State<NotesBlock> createState() => _NotesBlockState();
}

class _NotesBlockState extends State<NotesBlock> {
  bool _expanded = false;

  static const int _collapsedLines = 8;

  @override
  Widget build(BuildContext context) {
    final notes = widget.character.creatorNotes.trim();
    if (notes.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final rich = notesLookRich(notes);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SheetLabel('Creator notes'),
          const SizedBox(height: 8),
          if (rich)
            RichNotes(
              notes: notes,
              baseColor: scheme.onSurface,
              linkColor: scheme.primary,
              fontSize: 14.5,
            )
          else ...[
            AnimatedSize(
              duration: const Duration(milliseconds: 150),
              alignment: Alignment.topCenter,
              child: Text(
                notes,
                maxLines: _expanded ? null : _collapsedLines,
                overflow:
                    _expanded ? TextOverflow.clip : TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            if (notes.length > 260)
              MoreButton(
                expanded: _expanded,
                onPressed: () => setState(() => _expanded = !_expanded),
              ),
          ],
        ],
      ),
    );
  }
}

/// The thin rule between the notes and the definition.
class SheetDivider extends StatelessWidget {
  const SheetDivider({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 2),
        child: Divider(
          height: 1,
          thickness: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      );
}

/// A small tinted section label, the sheet's one heading style.
class SheetLabel extends StatelessWidget {
  const SheetLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
      );
}

/// The "Read more"/"Read less" toggle, sized as a text link rather than a button.
class MoreButton extends StatelessWidget {
  const MoreButton({
    super.key,
    required this.expanded,
    required this.onPressed,
  });

  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: onPressed,
          child: Text(expanded ? 'Read less' : 'See more…'),
        ),
      );
}
// APPEND-FOLDS

/// The definition, behind folds: scenario (with the custom-scenario editor
/// beside it), description, greetings, then the remaining card fields.
///
/// Each fold's body is built only while it is open ([ExpansionTile] with
/// `maintainState: false`), so a card with a huge description or a dozen
/// HTML greetings costs nothing until asked.
class DefinitionFolds extends StatelessWidget {
  const DefinitionFolds({super.key, required this.character});

  final Character character;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ScenarioFold(character: character),
        TextFold(title: 'Description', body: character.description),
        GreetingsFold(character: character),
        TextFold(title: 'Personality', body: character.personality),
        TextFold(title: 'Example dialogue', body: character.mesExample),
        TextFold(title: 'System prompt', body: character.systemPrompt),
        TextFold(
          title: 'Post-history instructions',
          body: character.postHistoryInstructions,
        ),
      ],
    );
  }
}

/// A fold holding one field's text. Long bodies still collapse behind
/// "See more…" once open, so a 4000-word description does not become the page.
class TextFold extends StatefulWidget {
  const TextFold({super.key, required this.title, required this.body});

  final String title;
  final String body;

  @override
  State<TextFold> createState() => _TextFoldState();
}

class _TextFoldState extends State<TextFold> {
  bool _expanded = false;

  static const int _collapsedLines = 10;
  static const int _threshold = 700;

  @override
  Widget build(BuildContext context) {
    final body = widget.body.trim();
    if (body.isEmpty) return const SizedBox.shrink();
    final long = body.length > _threshold;
    return FoldTile(
      title: widget.title,
      children: [
        SelectableText(
          body,
          maxLines: long && !_expanded ? _collapsedLines : null,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.45),
        ),
        if (long)
          MoreButton(
            expanded: _expanded,
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
      ],
    );
  }
}

/// The shared fold shell, so every row on the sheet opens the same way.
class FoldTile extends StatelessWidget {
  const FoldTile({
    super.key,
    required this.title,
    required this.children,
    this.trailingAction,
    this.subtitle,
  });

  final String title;
  final List<Widget> children;

  /// An extra control on the header row, beside the expand chevron.
  final Widget? trailingAction;

  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Theme(
      // The fold is a quiet row, not a card: no divider lines of its own.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: Text(
          title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
        trailing: trailingAction == null
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  trailingAction!,
                  const Icon(Icons.expand_more),
                ],
              ),
        tilePadding: const EdgeInsets.symmetric(horizontal: 20),
        childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        // Bodies are rebuilt on open rather than held: that is the whole point
        // of folding a card this large.
        maintainState: false,
        children: children,
      ),
    );
  }
}
// APPEND-SCENARIO

/// The scenario fold. Shows whichever scenario is in force, says when that is a
/// custom one, and offers the two ways to change it: plug one in from the
/// library, or write your own here.
///
/// The library route is the interesting one. It opens the picker over the bottom
/// three-quarters of the screen, where a scenario can be searched for, read,
/// edited in place and only then committed — so choosing an opening for a
/// character never means leaving the character.
class ScenarioFold extends StatelessWidget {
  const ScenarioFold({super.key, required this.character});

  final Character character;

  /// Opens the picker and applies what comes back as this character's own
  /// scenario, so every new chat with them starts there.
  Future<void> _plugIn(BuildContext context) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final pick = await showScenarioPickerSheet(
      context,
      localLabel: character.displayName,
      cardScenario: character.scenario,
      currentText: character.customScenario,
    );
    if (pick == null) return;
    await state.setCustomScenario(character.id, pick.preview);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(pick.isClear
            ? "Back to the card's own scenario."
            : 'Scenario set for ${character.displayName}.'),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = character.activeScenario.trim();
    final custom = character.hasCustomScenario;

    return FoldTile(
      title: 'Scenario',
      subtitle: custom
          ? 'Your own scenario'
          : (active.isEmpty ? 'None on this card' : null),
      trailingAction: IconButton(
        // The picker is the primary action, so it lives on the *collapsed* row.
        // It used to sit inside the fold's body with only a pencil showing out
        // here, which meant the one thing this row is for was invisible until
        // you unfolded it — and the visible icon opened the plain text editor
        // instead. Whichever affordance is reached first now leads to the picker.
        tooltip: 'Choose a scenario',
        icon: Icon(
          Icons.theater_comedy_outlined,
          color: custom ? scheme.primary : null,
        ),
        onPressed: () => _plugIn(context),
      ),
      children: [
        if (active.isEmpty)
          Text(
            'This character has no scenario. Choose one from your library or '
            'write your own, and it will be used in every new chat with them.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          )
        else
          SelectableText(
            active,
            style:
                Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
        // With a custom scenario in force, the card's own is still worth being
        // able to read — it is what "Use the card's scenario" restores.
        if (custom && character.scenario.trim().isNotEmpty) ...[
          const SizedBox(height: 14),
          SheetLabel("Card's own scenario"),
          const SizedBox(height: 6),
          Text(
            character.scenario.trim(),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
          ),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: () => _plugIn(context),
              icon: const Icon(Icons.theater_comedy_outlined, size: 18),
              label: const Text('Choose a scenario'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => showCustomScenarioSheet(context, character),
              child: const Text('Write your own'),
            ),
          ],
        ),
      ],
    );
  }
}

/// The from-the-bottom scenario editor: type a scenario, save it, or clear it
/// back to the card's own.
Future<void> showCustomScenarioSheet(
    BuildContext context, Character character) async {
  final state = context.read<AppState>();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _CustomScenarioSheet(
      character: character,
      onSave: (text) => state.setCustomScenario(character.id, text),
    ),
  );
}

class _CustomScenarioSheet extends StatefulWidget {
  const _CustomScenarioSheet({required this.character, required this.onSave});

  final Character character;
  final Future<void> Function(String) onSave;

  @override
  State<_CustomScenarioSheet> createState() => _CustomScenarioSheetState();
}

class _CustomScenarioSheetState extends State<_CustomScenarioSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.character.customScenario);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save(String text) async {
    await widget.onSave(text);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = widget.character.scenario.trim();
    return Padding(
      // Lift the sheet clear of the keyboard, so the field stays visible while
      // it is being typed into.
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Custom scenario',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            'Used instead of the card\'s scenario, in every chat with '
            '${widget.character.displayName}.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            minLines: 4,
            maxLines: 10,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: card.isEmpty
                  ? 'Where are they, and what is happening?'
                  : card,
              labelText: 'Scenario',
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              if (widget.character.hasCustomScenario)
                TextButton(
                  onPressed: () => _save(''),
                  child: const Text("Use the card's"),
                ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _save(_controller.text),
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
// APPEND-GREETINGS

/// The greetings fold. One greeting is shown directly; several become folds of
/// their own, so a card with eight alternates is one row until opened.
///
/// Each greeting is drawn by the real [MessageBubble] under the app's own chat
/// style, which is what makes "rendered exactly how they will be shown in the
/// chat" true rather than approximately true: the same bubble, the same avatar
/// rules, the same markdown/HTML/CSS/image path, the same macro resolution.
class GreetingsFold extends StatelessWidget {
  const GreetingsFold({super.key, required this.character});

  final Character character;

  List<String> get _greetings => <String>[
        character.firstMes.trim(),
        ...character.alternateGreetings.map((g) => g.trim()),
      ].where((g) => g.isNotEmpty).toList();

  @override
  Widget build(BuildContext context) {
    final greetings = _greetings;
    if (greetings.isEmpty) return const SizedBox.shrink();
    final single = greetings.length == 1;

    return FoldTile(
      title: 'Greetings',
      subtitle: single ? null : '${greetings.length} to choose from',
      children: [
        if (single)
          GreetingPreview(character: character, text: greetings.first)
        else
          for (var i = 0; i < greetings.length; i++)
            _NestedGreeting(
              label: i == 0 ? 'First message' : 'Alternate $i',
              character: character,
              text: greetings[i],
            ),
      ],
    );
  }
}

/// One greeting behind its own fold, inside the greetings fold.
class _NestedGreeting extends StatelessWidget {
  const _NestedGreeting({
    required this.label,
    required this.character,
    required this.text,
  });

  final String label;
  final Character character;
  final String text;

  @override
  Widget build(BuildContext context) => Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          subtitle: Text(
            text.replaceAll(RegExp(r'\s+'), ' '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          maintainState: false,
          children: [GreetingPreview(character: character, text: text)],
        ),
      );
}

/// A greeting drawn as the chat would draw it.
class GreetingPreview extends StatelessWidget {
  const GreetingPreview({
    super.key,
    required this.character,
    required this.text,
  });

  final Character character;
  final String text;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return Align(
      alignment: Alignment.centerLeft,
      child: MessageBubble(
        message: ChatMessage(role: 'assistant', content: text),
        ui: state.chatInterface,
        character: character,
        // The persona whose name a `{{user}}` in the greeting resolves to, so the
        // preview reads with the same name the chat will use.
        userPersona: state.defaultPersona,
        // No callbacks: no action bar, no swipe control, nothing tappable. This
        // is a picture of a turn, not a turn.
      ),
    );
  }
}
