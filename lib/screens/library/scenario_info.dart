import 'package:flutter/material.dart';

/// A plain-English explainer for Scenarios, opened from the "i" beside the
/// Scenarios title. What a scenario is, the three places one can come from, and
/// what happens when you pick one.
class ScenarioInfoScreen extends StatelessWidget {
  const ScenarioInfoScreen({super.key});

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
      appBar: AppBar(title: const Text('About scenarios')),
      body: ListView(
        padding: EdgeInsets.only(bottom: 24 + bottom),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text(
              'What is a scenario?',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          p('A scenario is the situation a chat starts in: where you both are, '
              'what is going on, and why. "Snowed in at a mountain station, the '
              'radio dead since Tuesday" is a scenario. The character says who '
              'they are; the scenario says what is happening to them.'),
          p('It is sent to the model as part of the opening instructions, so it '
              'shapes every reply — not just the first one.'),
          h('Three places a scenario comes from'),
          p('• The character card. Most cards ship with one, and it is used '
              'automatically. You do not have to do anything.\n\n'
              '• This library. Write an opening once, then plug it into any '
              'character or any single chat. Good for a setting you reuse — a '
              'shared world, a recurring premise, a house style.\n\n'
              '• On the spot. Open the scenario picker, tap "Write a new one", '
              'and type. You can keep it in the library or use it just this once.'),
          h('Replace, or add to'),
          p('Each scenario says whether it replaces the character\'s own '
              'scenario or is added after it. Replacing is the usual choice and '
              'the default. Adding keeps the card\'s setting and layers yours on '
              'top, which is what you want when the card describes a place and '
              'you are describing today\'s events in it.'),
          h('How to use one'),
          p('1. Write it here — the button at the bottom right.\n'
              '2. Open a character, unfold Scenario, and choose from the library. '
              'Or open a chat\'s settings and set it for that chat alone.\n'
              '3. Preview it, edit it if you like, then Proceed. Editing asks '
              'whether the change belongs to the library copy or only where you '
              'are using it.'),
          h('Where it takes effect'),
          p('A scenario set on a character applies to every new chat with them. '
              'A scenario set inside a chat applies to that chat only and wins '
              'over both the character\'s and the library\'s. Nothing is ever '
              'destroyed: clearing a scenario puts the card\'s own back.'),
          h('Tokens'),
          p('A scenario costs tokens on every single turn, because it is part of '
              'the standing instructions rather than the conversation. The maker '
              'shows the count as you type. A few sentences is usually plenty — '
              'a page of prose crowds out the chat history it was meant to '
              'frame.'),
          h('Moving them around'),
          p('Scenarios import from and export to Agnai, and can be lifted '
              'straight out of a character card. Agnai scenarios that carry '
              'triggered events are kept intact so they export again unchanged, '
              'but the events do not fire here — only the scenario text is sent.'),
        ],
      ),
    );
  }
}
