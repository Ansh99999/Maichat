// Part of the screenshot generator (see developer notes/screenshots.md). Not a
// test: no `_test.dart` suffix, so `flutter test` never collects it.
//
// The world the screenshots are taken in. Everything here goes in through the
// app's own state — `addCharacter`, `startChatWithCharacter`, `recordUsage`'s
// ledger, `addGalleryRefs` — so a screenshot is the real screen drawing real
// state, not a mock-up of one. The only inventions are the words and the
// pictures, and the pictures are arithmetic (see png.dart).
import 'package:maichat/models/character.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/model_pricing.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/usage.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/services/usage_ledger.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'png.dart';

/// Never sends anything. A screenshot must not depend on a network, and a stray
/// request from a screen that streams on open would hang the generator.
class SilentClient extends ChatClient {
  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {}

  @override
  Future<List<String>> listModels(Provider provider) async =>
      const ['gpt-5.2', 'claude-opus-5', 'gemini-3-pro'];
}

/// The demo cast. One hue each, so every face is distinguishable at avatar size.
const List<({String id, String name, double hue, String description})> kCast = [
  (
    id: 'mira',
    name: 'Mira Vale',
    hue: 268,
    description: 'Lighthouse keeper\'s granddaughter. Dry, unhurried, watches '
        'the water more than she watches you.',
  ),
  (
    id: 'ash',
    name: 'Ash',
    hue: 186,
    description: 'A courier who knows every roof in the city and will not say '
        'who pays them.',
  ),
  (
    id: 'juniper',
    name: 'Juniper',
    hue: 32,
    description: 'Runs the tea stall at the harbour steps. Knows everyone, '
        'repeats nothing.',
  ),
  (
    id: 'orrin',
    name: 'Orrin Blake',
    hue: 132,
    description: 'Cartographer. Convinced the coast is drawn wrong on purpose.',
  ),
  (
    id: 'sable',
    name: 'Sable',
    hue: 320,
    description: 'A voice on the radio at 3am, and nobody at the transmitter.',
  ),
  (
    id: 'wren',
    name: 'Wren',
    hue: 218,
    description: 'Keeps the ferry timetable in her head and resents being '
        'asked for it.',
  ),
];

/// Who the demo user is. A persona is just a character worn by the other side
/// of the conversation, which is the whole point of the feature — so it joins
/// the roster like anyone else.
const ({String id, String name, double hue, String description}) kPersona = (
  id: 'cal',
  name: 'Cal',
  hue: 6,
  description: 'Came to the coast to finish something and has not started it.',
);

/// A ledger with a fortnight of spend behind it, so the Costs tab has a shape
/// to draw instead of one lonely bar. Written through `UsageLedger.record`,
/// which is what the app itself calls — only the timestamps are fabricated.
String _seededLedger(String providerId) {
  final ledger = UsageLedger();
  final now = DateTime.now();
  // A quiet weekday rhythm: a handful of exchanges most evenings, a long
  // session two days ago, nothing at all on one day.
  const shape = <int>[6, 3, 0, 9, 4, 5, 2, 7, 3, 0, 8, 14, 5, 4];
  for (var day = shape.length - 1; day >= 0; day--) {
    final replies = shape[day];
    for (var i = 0; i < replies; i++) {
      final at = now.subtract(Duration(days: day, hours: 4 + i * 2));
      final long = i % 4 == 3;
      ledger.record(
        providerId: providerId,
        model: i % 3 == 0 ? 'claude-opus-5' : 'gpt-5.2',
        usage: TokenUsage(
          inputTokens: long ? 9200 + i * 240 : 2400 + i * 180,
          outputTokens: long ? 1400 + i * 60 : 420 + i * 30,
          reasoningTokens: long ? 600 : 0,
          cachedTokens: i.isEven ? 1800 : 0,
        ),
        price: const ModelPrice(model: 'claude-opus-5', input: 3.0, output: 15.0),
        at: at,
      );
    }
  }
  return ledger.encode();
}

/// Boots an [AppState] on mock preferences with the cast, a chat worth reading,
/// a fortnight of spend and a gallery. Nothing touches the disk or the network.
Future<AppState> demoWorld() async {
  const providerId = 'demo-provider';
  SharedPreferences.setMockInitialValues(<String, Object>{
    'usage': _seededLedger(providerId),
  });
  final state = AppState(client: SilentClient());
  await state.init();
  await state.addProvider(Provider(
    id: providerId,
    name: 'OpenRouter',
    kind: ProviderKind.openai,
    baseUrl: 'https://openrouter.ai/api/v1',
    model: 'gpt-5.2',
    apiKey: 'sk-demo',
    prices: const [
      ModelPrice(model: 'gpt-5.2', input: 1.25, output: 10.0),
      ModelPrice(model: 'claude-opus-5', input: 3.0, output: 15.0),
    ],
  ));
  for (final member in [...kCast, kPersona]) {
    await state.addCharacter(Character(
      id: member.id,
      name: member.name,
      description: member.description,
      avatar: demoArtBase64(size: 512, hue: member.hue),
      tags: const ['original', 'slice of life'],
    ));
  }
  // Set before any chat is started: a persona is applied when the thread is
  // created, and existing threads keep whatever they already had.
  await state.setDefaultPersona(kPersona.id);
  return state;
}

/// Opens a chat with Mira and fills it with something worth photographing:
/// asterisks and quotes (so the wrap rules have something to colour), a reply
/// the model thought about first, and an alternative kept behind a swipe.
///
/// Seeded directly onto the conversation rather than sent — `send()` never
/// returns inside a widget test's fake clock (see CLAUDE.md).
void seedChat(AppState state) {
  final mira = state.characterById('mira')!;
  state.startChatWithCharacter(mira);
  state.active.messages
    ..clear()
    ..add(ChatMessage(
      role: 'assistant',
      content: '*The lamp room is cold and smells of brass polish. Mira is '
          'already up here, elbows on the rail, watching the water go from '
          'black to pewter.*\n\n'
          '"You\'re early. Nobody\'s early."',
    ))
    ..add(ChatMessage(
      role: 'user',
      content: 'I couldn\'t sleep. Is the light still working?',
    ))
    ..add(ChatMessage(
      role: 'assistant',
      reasoning: 'They came up here at dawn rather than sleeping, which is a '
          'question about the light and not about the light. Mira should answer '
          'the literal question first — she would — and let the other one sit.',
      thinkingMs: 3400,
      content: '*She doesn\'t look round. One hand comes off the rail and taps '
          'the housing twice, the way you\'d pat a horse.*\n\n'
          '"It works. Nobody\'s lit it since my grandmother, but it works." '
          '*A gull goes past below eye level, which is a strange thing to get '
          'used to.* "That\'s not what you came up to ask."',
      swipes: [
        MessageVariant(
          content: '*She doesn\'t look round. One hand comes off the rail and '
              'taps the housing twice, the way you\'d pat a horse.*\n\n'
              '"It works. Nobody\'s lit it since my grandmother, but it works." '
              '*A gull goes past below eye level, which is a strange thing to '
              'get used to.* "That\'s not what you came up to ask."',
          reasoning: 'They came up here at dawn rather than sleeping, which is '
              'a question about the light and not about the light. Mira should '
              'answer the literal question first — she would — and let the '
              'other one sit.',
          thinkingMs: 3400,
        ),
        const MessageVariant(
          content: '"Working is a strong word." *She straightens up, and for '
              'the first time looks at you properly.* "It turns. Whether '
              'anything out there can see it turning is a different question."',
        ),
      ],
    ));
}

/// A gallery with something in it, filed under the cast so the whole-app view
/// has owners to group by. Refs are base64 pictures, which is a shape
/// `avatarImage` decodes without a pictures directory.
Future<void> seedGallery(AppState state) async {
  const titles = <String>[
    'the lamp room at dawn',
    'harbour steps, low tide',
    'the ferry, wrong timetable',
    'roofs, third district',
    'transmitter hut',
    'chart of a coast drawn wrong',
    'tea stall, morning',
    'the light, turning',
    'pewter water',
  ];
  for (var i = 0; i < titles.length; i++) {
    final member = kCast[i % kCast.length];
    await state.addGalleryRefs(
      [
        (
          ref: demoArtBase64(
            size: 384,
            height: i % 3 == 0 ? 512 : 384,
            hue: member.hue + i * 9,
          ),
          title: titles[i],
          tags: i.isEven ? const ['scene'] : const ['portrait'],
        ),
      ],
      characterId: member.id,
    );
  }
}


