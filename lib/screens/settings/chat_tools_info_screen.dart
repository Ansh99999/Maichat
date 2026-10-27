import 'package:flutter/material.dart';

/// Opens the plain-English explainer for tool calls.
void showChatToolsInfo(BuildContext context) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ChatToolsInfoScreen()),
    );

/// What tool calls are, in a user's terms — opened from the ⓘ beside the
/// Tools title. No protocol detail, no JSON: just what the feature is for,
/// what the user will see, and where the choices live.
class ChatToolsInfoScreen extends StatelessWidget {
  const ChatToolsInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;

    Widget h(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 6),
          child: Text(
            text,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        );
    Widget p(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('About tools')),
      body: ListView(
        padding: EdgeInsets.only(bottom: 24 + bottom),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text(
              'What are tools?',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          p('A tool is something the character\'s AI can ask MaiChat to do '
              'mid-reply — roll dice, read a stat, generate a picture. The AI '
              'doesn\'t pretend to do it: it asks, MaiChat does the real thing, '
              'hands the result back, and the AI carries on writing with that '
              'result.'),
          p('A simple example: you write "roll a d20 for this attack". The '
              'character asks for a dice roll, MaiChat rolls — say, a 17 — and '
              'the character narrates the hit using that number. The roll is '
              'real and it is remembered.'),
          h('What you see in the chat'),
          p('Each tool use shows up as a small row under the reply that made '
              'it: what was asked, and what came back. Tap the row to see the '
              'full details. If you find that noisy, there is a switch in the '
              'Tools settings that hides these rows — the tools keep working, '
              'the chat just stays clean.'),
          h('Trackers'),
          p('Trackers are numbers that live with the chat — health, energy, '
              'excitement, whatever the story needs. Tools can read them and '
              'change them, and MaiChat keeps the history straight: switch to '
              'an earlier reply, fork the chat, regenerate — the numbers always '
              'match the version of the story you are looking at. Where the '
              'little tracker chips appear (under the reply, in a panel at the '
              'top, or nowhere) is a setting.'),
          h('Custom tools'),
          p('Beyond the ones that ship with MaiChat, you can write your own. '
              'A custom tool is a name, a description, the arguments it takes '
              'and a recipe — a small JSON script that calls MaiChat\'s '
              'operations and shapes the answer. It is deliberately not '
              'JavaScript: there is nothing it can run except the operations '
              'the app already has.'),
          p('You can test a custom tool right from its page with sample '
              'arguments before ever letting a character use it.'),
          h('On and off'),
          p('Tools start switched off everywhere. Turn them on for the whole '
              'app, or just for one chat — a chat with its own settings always '
              'uses those. Each tool in the list also has its own toggle, so '
              'you can offer the character dice but not pictures, or the '
              'other way round.'),
          h('Limits'),
          p('A reply that keeps calling tools is reined in by two limits you '
              'can set: how many rounds of follow-ups it may make, and how '
              'many tool calls in total. When a limit is hit, the reply just '
              'finishes with what it has.'),
          h('Moving them around'),
          p('Tools export to a .json file and import from one, so a tool you '
              'write in one chat (or a friend writes on their phone) can be '
              'shared. Imports land in the same list, where you can edit or '
              'rename them like anything else.'),
        ],
      ),
    );
  }
}
