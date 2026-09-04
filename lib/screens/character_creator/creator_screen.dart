import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/character.dart';
import '../../state/app_state.dart';
import '../../widgets/character_theme_scope.dart';
import 'advanced_tab.dart';
import 'creator_avatar_header.dart';
import 'creator_draft.dart';
import 'creator_theme_sheet.dart';
import 'greetings_tab.dart';
import 'identity_tab.dart';
import 'lorebooks_tab.dart';
import 'persona_tab.dart';
import 'scenarios_tab.dart';

/// Creator v2: the picture, then the card behind six tabs you can swipe between.
///
/// The shape is the whole idea. A character card is six unrelated jobs — who they
/// are, what the model is told, how a chat opens, where it opens, what facts come
/// with them, and the instructions underneath — and the single scrolling form they
/// used to share meant every one of those jobs was a scroll position you had to
/// remember. Tabs make each of them a place.
///
/// The picture is above the tabs rather than inside one, because it is the thing
/// you keep glancing at while you write, and it steps out of the way when the
/// keyboard comes up: with a text field focused the display belongs to the field.
///
/// Everything lives on one [CreatorDraft], handed down through a provider, so a
/// tab that has been swiped away and rebuilt does not lose what was typed into it.
/// Nothing is written to the roster until Save.
class CharacterCreatorScreen extends StatefulWidget {
  const CharacterCreatorScreen({
    super.key,
    this.character,
    this.persist = true,
  });

  final Character? character;

  /// With false the card is *not* saved: Save pops the built [Character] and the
  /// caller decides where it lands. That is how chat settings collect a change
  /// before asking whether it belongs to one chat or to everywhere.
  final bool persist;

  @override
  State<CharacterCreatorScreen> createState() => _CharacterCreatorScreenState();
}

class _CharacterCreatorScreenState extends State<CharacterCreatorScreen>
    with SingleTickerProviderStateMixin {
  late final CreatorDraft _draft = CreatorDraft(source: widget.character);
  late final TabController _tabs = TabController(length: 6, vsync: this);

  /// What the card looked like when this screen opened, so backing out can tell
  /// "nothing happened" from "there is work here". Compared as JSON with the
  /// timestamps and the id taken out, because those move on their own.
  ///
  /// Taken in [initState] and *not* `late`: a lazy field would be initialised by
  /// its first read, which is the first back-press, and would therefore record
  /// the edited card as the one this screen opened on — the discard dialog would
  /// never appear.
  Map<String, dynamic> _opened = const <String, dynamic>{};

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _opened = _comparable();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _draft.dispose();
    super.dispose();
  }

  Map<String, dynamic> _comparable() {
    final json = _draft.snapshot().toJson()
      ..remove('id')
      ..remove('createdAt')
      ..remove('updatedAt');
    return json;
  }

  bool get _dirty => _opened.toString() != _comparable().toString();

  Future<void> _save() async {
    if (_saving) return;
    if (_draft.name.text.trim().isEmpty) {
      _tabs.animateTo(0);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Give them a name first.'),
          behavior: SnackBarBehavior.floating,
        ));
      return;
    }
    setState(() => _saving = true);
    final state = context.read<AppState>();
    final card = widget.persist
        ? _draft.build(into: widget.character)
        : _draft.build();
    if (widget.persist) await state.saveCharacter(card);
    if (!mounted) return;
    Navigator.of(context).pop(card);
  }

  Future<void> _leave() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard this character?'),
        content: Text(widget.character == null
            ? 'Nothing has been saved yet.'
            : 'The changes you made will be lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<CreatorDraft>.value(
      value: _draft,
      child: Consumer<CreatorDraft>(
        builder: (context, draft, _) => CharacterThemeScope(
          theme: draft.theme,
          child: PopScope(
            // Always intercepted, then decided: whether there is anything to
            // discard depends on text typed into a controller, which does not
            // rebuild this widget — so asking at the moment of the gesture is the
            // only way to get the answer right.
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              _leave();
            },
            child: _scaffold(context, draft),
          ),
        ),
      ),
    );
  }

  Widget _scaffold(BuildContext context, CreatorDraft draft) {
    final media = MediaQuery.of(context);
    // With the keyboard up the header goes away entirely: a portrait is worth
    // looking at, and it is worth nothing at all while it is squeezing the field
    // being typed into down to two lines.
    final typing = media.viewInsets.bottom > 0;
    final headerHeight =
        (media.size.height * 0.3).clamp(170.0, 320.0).toDouble();
    final name = draft.name.text.trim();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _leave,
        ),
        title: Text(
          name.isEmpty
              ? (draft.isNew ? 'New character' : 'Edit character')
              : name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            key: const Key('creator-theme-button'),
            tooltip: "This character's theme",
            icon: Icon(
              draft.theme.isSet
                  ? Icons.palette
                  : Icons.palette_outlined,
            ),
            onPressed: () => showCharacterThemeSheet(context, draft: draft),
          ),
          TextButton(
            key: const Key('creator-save'),
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: Column(
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: typing
                ? const SizedBox(width: double.infinity, height: 0)
                : CreatorAvatarHeader(
                    draft: draft,
                    characterId: widget.character?.id,
                    height: headerHeight,
                  ),
          ),
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: TabBar(
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: const [
                Tab(text: 'Identity'),
                Tab(text: 'Persona'),
                Tab(text: 'Greetings'),
                Tab(text: 'Scenarios'),
                Tab(text: 'Lorebooks'),
                Tab(text: 'Advanced'),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: const [
                IdentityTab(),
                PersonaTab(),
                GreetingsTab(),
                ScenariosTab(),
                LorebooksTab(),
                AdvancedTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
