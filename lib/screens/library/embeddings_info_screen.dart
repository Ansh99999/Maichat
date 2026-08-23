import 'package:flutter/material.dart';

/// A plain-English explainer for the Embeddings feature, opened from the "i"
/// beside the Embeddings title. No jargon — what it is, what it does, how to use
/// it.
class EmbeddingsInfoScreen extends StatelessWidget {
  const EmbeddingsInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;

    Widget h(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 6),
          child: Text(text,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
        );
    Widget p(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Text(text,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.4)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('About embeddings')),
      body: ListView(
        padding: EdgeInsets.only(bottom: 24 + bottom),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text(
              'What are embeddings?',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          p('An embedding turns a piece of text into a list of numbers that '
              'captures its meaning. Two texts about the same thing get similar '
              'numbers — even if they use different words. "The dragon burned the '
              'village" and "the beast set the town ablaze" land close together.'),
          h('Why the app uses them'),
          p('Normally the AI only sees your most recent messages — older ones '
              'scroll out of view and are forgotten. Lorebooks help, but only '
              'when your text contains the exact keyword.'),
          p('Embeddings add memory by meaning. When you send a message, the app '
              'finds the few most related older messages (or lorebook entries, or '
              'document pages) and quietly slips them back into the conversation '
              'so the AI "remembers" them.'),
          h('The three things it can recall'),
          p('• Past messages — turn on "Semantic recall" for a chat, and it '
              'remembers things you talked about long ago.\n\n'
              '• Lorebooks — mark a book "Use embeddings" and its entries can '
              'trigger by meaning, not just keywords.\n\n'
              '• Documents — add a file, a web link, or pasted text here, attach '
              'it to a chat, and the AI can pull relevant parts into its answers.'),
          h('How to set it up'),
          p('1. Open Configuration (the gear, top-right) and turn Embeddings on.\n'
              '2. Choose a provider and an embedding model (e.g. '
              'text-embedding-3-small). This must be an OpenAI-compatible '
              'provider that offers an embeddings endpoint.\n'
              '3. Add documents here, and/or turn on Semantic recall inside a '
              "chat's Memory panel."),
          h('Does it cost anything?'),
          p('A little. Each new message and document is sent once to the '
              'embedding model (this is cheap), and each reply does one small '
              'lookup. Everything is off until you turn it on, so nothing runs '
              'and nothing is spent unless you ask for it.'),
          h('Good to know'),
          p('Your documents and message vectors are stored as files on your '
              "device, not sent anywhere except to create the embeddings. If you "
              'change the embedding model, everything is rebuilt automatically.'),
        ],
      ),
    );
  }
}
