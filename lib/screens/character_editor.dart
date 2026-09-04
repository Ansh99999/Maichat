import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/character.dart';
import '../models/view_prefs.dart';
import '../state/app_state.dart';
import 'character_creator/creator_screen.dart';
import 'character_edit_screen.dart';

/// Opens whichever character editor the user has chosen, and returns the card
/// that came back (null when they backed out).
///
/// **The** door to editing a character. Six places create or edit one — the
/// roster, the sheet, the actions menu, chat settings, the persona picker, the
/// group sheet — and every one of them goes through here, so the preference in
/// Settings decides once rather than in six places that could disagree.
///
/// With [persist] false the editor collects a *draft*: nothing is written to the
/// roster and the built [Character] is handed back for the caller to place. Both
/// editors honour it identically.
Future<Character?> openCharacterEditor(
  BuildContext context, {
  Character? character,
  bool persist = true,
}) {
  final version = context.read<AppState>().creatorVersion;
  return Navigator.of(context).push<Character>(
    MaterialPageRoute<Character>(
      builder: (_) => switch (version) {
        CreatorVersion.v1 => CharacterEditScreen(
            character: character,
            persist: persist,
          ),
        CreatorVersion.v2 => CharacterCreatorScreen(
            character: character,
            persist: persist,
          ),
      },
    ),
  );
}
