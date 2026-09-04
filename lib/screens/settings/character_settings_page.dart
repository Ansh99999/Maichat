import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/view_prefs.dart';
import '../../state/app_state.dart';
import 'chat_interface/controls.dart';
import 'setting_anchors.dart';
import 'setting_highlight.dart';

/// Settings about characters — which editor "Create" and "Edit" open.
///
/// Creator v2 is the default: the picture at its own proportions, six tabs, a
/// token count and a full-screen editor on every long field, previews for the
/// greetings and the notes, several scenarios, attached lorebooks and a per-card
/// theme. Creator v1 is the single-page form it replaced, kept because it is
/// faster to fill in when you already know what you are typing — and because
/// taking away a working screen to hand somebody a better one is still taking
/// away a working screen.
///
/// Both write the same card. Nothing about a character records which editor made
/// it, so switching back and forth costs nothing and loses nothing.
class CharacterSettingsPage extends StatelessWidget {
  const CharacterSettingsPage({super.key, this.highlight});

  final SettingAnchor? highlight;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final version = state.creatorVersion;

    return Scaffold(
      appBar: AppBar(title: const Text('Characters')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          8,
          8,
          8,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          settingHeader(context, 'Character creator'),
          settingNote(
            context,
            'Which editor opens when you create or edit a character. Both save '
            'the same card, so you can switch whenever you like.',
          ),
          SettingHighlight(
            active: highlight == SettingAnchor.characterCreator,
            child: SettingEnumRow<CreatorVersion>(
              icon: Icons.edit_note_outlined,
              label: 'Editor',
              value: version,
              values: CreatorVersion.values,
              labelOf: (v) => v.label,
              onChanged: (picked) {
                state.setCreatorVersion(picked);
                notifySetting(context, '${picked.label} it is');
              },
            ),
          ),
          settingNote(context, version.blurb),
          settingNote(
            context,
            version == CreatorVersion.v2
                ? 'Creator v2 also carries the things only it can edit: several '
                    'scenarios attached to individual greetings, the lorebooks a '
                    'character travels with, and a theme of their own. A card '
                    'that has those keeps them whichever editor you use — v1 '
                    'simply does not show them.'
                : 'Creator v1 shows the fields both ecosystems have. A card that '
                    'already carries per-greeting scenarios, attached lorebooks '
                    'or its own theme keeps all of them; they are only editable '
                    'in v2.',
          ),
        ],
      ),
    );
  }
}
