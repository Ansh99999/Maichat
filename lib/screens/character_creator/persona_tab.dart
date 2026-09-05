import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../services/character_writer.dart';
import 'creator_controls.dart';
import 'creator_draft.dart';

/// What the model is told about this character: the description that carries the
/// detail, and the personality that carries the manner.
///
/// Both are ordinary [CreatorField]s, which is where the three things the brief
/// asks for come from — a live token count, a full-screen editor in the top right,
/// and the assistant beside it.
class PersonaTab extends StatelessWidget {  const PersonaTab({super.key});

  @override
  Widget build(BuildContext context) {
    final draft = context.watch<CreatorDraft>();
    return CreatorTabBody(
      children: [
        CreatorField(
          key: const Key('creator-description'),
          label: 'Description',
          controller: draft.description,
          draft: draft,
          field: WritableField.description,
          hint: 'Who they are, how they look, how they speak, where they come '
              'from.',
          lines: 12,
        ),
        CreatorField(
          key: const Key('creator-personality'),
          label: 'Personality',
          controller: draft.personality,
          draft: draft,
          field: WritableField.personality,
          hint: 'Temperament, habits, what they want.',
          lines: 7,
        ),
      ],
    );
  }
}
