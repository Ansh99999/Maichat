import 'package:flutter/material.dart';

import '../../models/character.dart';
import '../character_sheet_parts.dart';

/// Opens one greeting on a blank screen, drawn exactly as the chat will draw it.
///
/// A greeting is often the most designed thing on a card — HTML, CSS, an image,
/// a table — and none of that is visible in the box it is typed into. This is
/// where you find out: the real [MessageBubble], under the app's real chat style,
/// with the same markdown, HTML, CSS, image and macro handling a message gets.
/// Nothing but a back button, because there is nothing to do here but look.
Future<void> openGreetingPreview(
  BuildContext context, {
  required Character character,
  required String text,
  required String label,
}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GreetingPreviewScreen(
          character: character,
          text: text,
          label: label,
        ),
      ),
    );

class GreetingPreviewScreen extends StatelessWidget {
  const GreetingPreviewScreen({
    super.key,
    required this.character,
    required this.text,
    required this.label,
  });

  final Character character;
  final String text;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        // The back arrow is the whole app bar: the point of the screen is that
        // there is nothing else on it.
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          label,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
      body: SafeArea(
        top: false,
        child: text.trim().isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Nothing written yet.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              )
            : ListView(
                key: const Key('greeting-preview-body'),
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 40),
                children: [
                  GreetingPreview(character: character, text: text),
                ],
              ),
      ),
    );
  }
}
