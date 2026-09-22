import 'package:flutter/material.dart';

/// Opens the plain-English explainer for Regex.
void showRegexInfo(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => const RegexInfoScreen()));

/// What regex is, in a user's terms — opened from the "i" beside the Regex
/// title. No cheat sheet of syntax; just what the feature is for and how the
/// three "how it changes things" choices differ, since that is the part that
/// trips people up.
class RegexInfoScreen extends StatelessWidget {
  const RegexInfoScreen({super.key});

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
      appBar: AppBar(title: const Text('About regex')),
      body: ListView(
        padding: EdgeInsets.only(bottom: 24 + bottom),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text(
              'What is regex?',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          p('A regex rule is a find-and-replace that runs on your chat by '
              'itself. You write a pattern to look for and what it should become, '
              'and the app applies it every time a message goes by — no need to '
              'edit each one by hand.'),
          p('People use it to strip something the model keeps adding (a '
              'disclaimer, a stray tag, an out-of-character note), to reformat '
              'replies (wrap actions in italics, tidy quotes), or to fix a '
              'character card that outputs broken formatting.'),
          h('What each rule needs'),
          p('• A name, so you can find it later.\n\n'
              '• Find — the text or pattern to match. A plain word matches that '
              'word; the pattern language lets you match "anything in brackets" '
              'or "a line starting with…". You can also paste the /pattern/flags '
              'form shared elsewhere.\n\n'
              '• Replace with — what each match becomes. Leave it empty to simply '
              r'delete the match. Use {{match}} to keep the matched text, or $1, '
              r'$2 to reuse parts you captured.'),
          h('Where it applies'),
          p('Pick which messages a rule touches: the messages you send, the '
              'replies you receive, or the reasoning a model shows. A rule that '
              'targets nothing does nothing.'),
          h('How it changes things'),
          p('This is the important choice, and there are three:\n\n'
              '• Edit the saved message — the change is permanent. The message is '
              'rewritten in the chat for good. Best for cleaning up junk you '
              'never want to see again.\n\n'
              '• Only change what is shown — cosmetic. The saved message is left '
              'exactly as it was; only its appearance on screen changes. Good for '
              'restyling without losing the original.\n\n'
              '• Only change what is sent — the saved message and what you see '
              'stay the same, but the model receives the cleaned-up version. Good '
              'for trimming the prompt without touching your chat.'),
          h('Order matters'),
          p('Rules run from the top of the list down, and each one works on the '
              'result of the one before it. Drag a rule by its handle to move it.'),
          h('Advanced options'),
          p('A rule can be limited to a depth window (how far back from the '
              'newest message it reaches), told whether to re-run when you edit a '
              'message, and given "trim" snippets that are stripped from a match '
              'before it is put back. Most rules need none of these.'),
          h('Moving them around'),
          p('Rules export to a .json file and import from one, in the same shape '
              'SillyTavern uses — so a rule shared there works here, and one '
              'written here works there.'),
        ],
      ),
    );
  }
}
