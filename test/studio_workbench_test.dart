import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/message_image.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/models/studio_revisions.dart';
import 'package:maichat/services/studio/custom_agents.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/services/studio/studio_tools.dart';
import 'package:maichat/services/studio/workbench_tools.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The agents' workbench — `count_tokens`, the session's notes, and the
/// Playground's playtests — against a fake app, then the Playground end to end
/// against a loopback model, asserting the request a playtest really sends.
///
/// Plain `test()`s only: a `testWidgets` in this file would make every real
/// HTTP request in it answer 400. The Playground's UI is in
/// `studio_playground_ui_test.dart`.

class _Call {
  _Call(this.userTurns, this.earlier, this.scenario, this.greetingIndex);
  final List<String> userTurns;
  final List<StudioPlaytestTurn> earlier;
  final String scenario;
  final int greetingIndex;
}

class _Fake implements StudioServices {
  final List<_Call> playtests = <_Call>[];
  Object? failWith;

  @override
  int countTokens(String text) => text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

  @override
  List<Character> libraryCharacters = <Character>[];

  @override
  List<Lorebook> libraryLorebooks = <Lorebook>[];

  @override
  bool get canGenerateImages => false;

  @override
  Future<String> generatePicture({
    required String prompt,
    required String characterId,
  }) async =>
      '';

  @override
  Future<List<String>> playtest({
    required Character character,
    required List<Lorebook> lorebooks,
    required List<String> userTurns,
    int greetingIndex = 0,
    List<StudioPlaytestTurn> earlier = const <StudioPlaytestTurn>[],
    String scenario = '',
  }) async {
    playtests.add(_Call(userTurns, earlier, scenario, greetingIndex));
    if (failWith != null) throw failWith!;
    return [for (final t in userTurns) 'reply to $t'];
  }

  @override
  Future<StudioTaskOutcome> runTask({
    required String agentType,
    required String description,
    required String prompt,
    required String callId,
    String? taskId,
  }) =>
      throw UnimplementedError();
}

/// A fake that can also size a prompt, as the real app does.
class _Sizer extends _Fake implements StudioPromptSizer {
  @override
  ({int tokens, int context, List<(String, int)> sections})? promptSize({
    required Character character,
    required List<Lorebook> lorebooks,
    int greetingIndex = 0,
  }) =>
      (tokens: 900, context: 8000, sections: const [('Character', 600), ('Empty', 0)]);
}

Map<String, dynamic> _json(StudioToolResult r) =>
    jsonDecode(r.text) as Map<String, dynamic>;

void main() {
  late StudioSession session;
  late _Fake services;

  StudioSession fresh() => StudioSession(
        id: 's',
        title: '',
        workspace: StudioWorkspace(
          character: Character(
            id: 'c',
            name: 'Maren',
            description: 'She keeps the light',
            personality: 'dry and patient',
            firstMes: 'You made it, {{user}}.',
            alternateGreetings: ['The lamp is out again.'],
          ),
          lorebooks: [
            Lorebook(id: 'b', name: 'Marsh', entries: [
              LorebookEntry(uid: 0, name: 'Bog', keys: ['bog'], content: 'grey and hungry'),
              LorebookEntry(uid: 1, keys: ['law'], content: 'the light never dies', constant: true),
            ]),
          ],
        ),
      );

  setUp(() {
    session = fresh();
    services = _Fake();
  });

  Future<StudioToolResult> call(
    String tool,
    Map<String, dynamic> args, {
    String agent = 'studio',
    StudioServices? using,
  }) {
    final ctx = StudioToolContext(session: session, services: using ?? services);
    return kStudioTools[tool]!(agent == 'studio' ? ctx : ctx.as(agent), args);
  }

  group('count_tokens', () {
    test('counts text, and named parts of the draft', () async {
      final r = _json(await call('count_tokens', {
        'text': 'one two three',
        'parts': ['description', 'greetings', 'lorebook:b'],
      }));
      expect(r['text_tokens'], 3);
      final parts = r['parts'] as Map<String, dynamic>;
      expect(parts['description'], 4);
      expect(parts['first_message'], 4);
      expect(parts['alternate_greetings[0]'], 5);
      expect(parts['lorebook:b:entry:0 (Bog)'], 3);
      final constant =
          parts.keys.singleWhere((k) => k.startsWith('lorebook:b:entry:1'));
      expect(constant, endsWith('[constant]'));
      expect(parts[constant], 4);
      expect(parts['lorebook:b (Marsh) total'], 7);
      // A book's total is not counted twice.
      expect(r['parts_total'], 4 + 4 + 5 + 3 + 4);
    });

    test('card reports the permanent fields, and unknown parts are named',
        () async {
      final r = _json(await call('count_tokens', {
        'parts': ['card', 'wings'],
      }));
      expect(r['permanent_fields_sum'], 4 + 3);
      expect(r['permanent_tokens'], isA<int>());
      expect(r['unknown_parts'], ['wings']);
      expect(r['known_parts'], contains('prompt'));
    });

    test('prompt is the assembled first request, when the app can size it',
        () async {
      final none = _json(await call('count_tokens', {'parts': ['prompt']}));
      expect(none['prompt'], contains('no chat provider'));
      final sized = _json(
        await call('count_tokens', {'parts': ['prompt']}, using: _Sizer()),
      );
      final prompt = sized['prompt'] as Map<String, dynamic>;
      expect(prompt['tokens'], 900);
      expect(prompt['context'], 8000);
      expect(prompt['share_of_context'], '11.3%');
      expect(prompt['sections'], {'Character': 600});
    });

    test('with nothing passed it reports the usual parts', () async {
      final r = _json(await call('count_tokens', {}));
      expect(r.containsKey('permanent_tokens'), isTrue);
      expect(r['prompt'], isNotNull);
      expect((r['parts'] as Map).keys, contains('first_message'));
    });
  });

  group('notes', () {
    test('appendToNotes files under a heading, making it when missing', () {
      var notes = appendToNotes('', 'First thought.');
      expect(notes, 'First thought.\n');
      notes = appendToNotes(notes, 'Fandom says so.', section: 'Research');
      expect(notes, 'First thought.\n\n## Research\n\nFandom says so.\n');
      notes = appendToNotes(notes, 'Open: her age?', section: 'Questions');
      // Into an existing section, before the next heading.
      notes = appendToNotes(notes, 'Wikipedia agrees.', section: 'research');
      expect(
        notes,
        'First thought.\n\n## Research\n\nFandom says so.\n\nWikipedia agrees.'
        '\n\n## Questions\n\nOpen: her age?\n',
      );
      expect(notesHeadings(notes), ['Research', 'Questions']);
      // A sub-heading belongs to its section.
      notes = appendToNotes('## A\n\nx\n\n### A.1\n\ny\n\n## B\n\nz', 'w', section: 'A');
      expect(notes, '## A\n\nx\n\n### A.1\n\ny\n\nw\n\n## B\n\nz');
    });

    test('agents append, read, edit and rewrite; each is a change', () async {
      await call('append_notes', {'text': 'Canon: born 1802.', 'section': 'Research'});
      await call('append_notes', {'text': 'Voice: clipped.'}, agent: 'Subagent 1');
      final read = _json(await call('read_notes', {}));
      expect(read['notes'], contains('Canon: born 1802.'));
      expect(read['notes'], contains('Voice: clipped.'));
      expect(read['sections'], ['Research']);
      expect(_json(await call('edit_notes', {'find': '1802', 'replace': '1803'}))['ok'], isTrue);
      expect(session.workspace.notes, contains('born 1803'));
      final bad = await call('edit_notes', {'find': 'nowhere', 'replace': 'x'});
      expect(bad.isError, isTrue);
      await call('write_notes', {'text': '# Clean slate'});
      expect(session.workspace.notes, '# Clean slate');
      expect(session.ops.map((o) => o.tool), [
        'append_notes',
        'Subagent 1 · append_notes',
        'edit_notes',
        'write_notes',
      ]);
      // A rewind takes the notes back with the rest of the draft.
      session.rewindTo(2);
      expect(session.workspace.notes, contains('born 1802'));
    });

    test('a rewrite over notes someone else changed is refused; an append is not',
        () async {
      await call('read_notes', {});
      await call('append_notes', {'text': 'Mine.'}, agent: 'Subagent 2');
      final stale = await call('write_notes', {'text': 'Replaced.'});
      expect(stale.isError, isTrue);
      expect(stale.text, contains('Subagent 2'));
      expect(stale.text, contains('read_notes'));
      expect((await call('append_notes', {'text': 'Also mine.'})).isError, isFalse);
      // A hand edit counts as the user's.
      session.edit('manual', 'Edited the notes by hand', (ws) => ws.notes = 'By hand.');
      expect(session.revisions['notes']!.by, kUserEditor);
    });

    test('the notes are saved with the session and never on the card', () {
      session.workspace.notes = '## Research\n\nA source.';
      final back = StudioSession.fromJson(
        jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>,
      );
      expect(back.workspace.notes, '## Research\n\nA source.');
      expect(jsonEncode(back.workspace.character.toJson()), isNot(contains('A source')));
      // An empty note costs nothing in the file.
      expect(StudioWorkspace(character: Character(id: 'x', name: '')).toJson(),
          isNot(contains('notes')));
    });

    test('who gets which notes tools', () {
      List<String> names(String type) =>
          [for (final t in studioToolsFor(type)) t.name];
      for (final type in ['studio', 'general', 'writer', 'lore_writer', 'critic']) {
        expect(names(type), containsAll(['count_tokens', 'read_notes', 'append_notes']),
            reason: type);
      }
      // A critic changes nothing: it adds to the notes but never rewrites them.
      expect(names('critic'), isNot(contains('write_notes')));
      expect(names('critic'), isNot(contains('edit_notes')));
      expect(names('writer'), containsAll(['write_notes', 'edit_notes', 'read_playtests']));
      expect(names('lore_writer'), isNot(contains('playtest')));
      // A type the user defined has every notes tool and counting, whatever
      // groups it was given.
      const config = StudioConfig(customAgents: [
        StudioAgentType(id: 'poet', label: 'Poet', description: 'Verse.', toolGroups: {'read'}),
      ]);
      final poet = [for (final t in studioToolsForType('poet', config)) t.name];
      expect(poet, containsAll([...kNotesToolNames, 'count_tokens']));
      expect(poet, isNot(contains('playtest')));
    });
  });

  group('playtests', () {
    test('a playtest is filed for the Playground, greeting first', () async {
      final r = _json(await call('playtest', {
        'messages': ['Who are you?'],
        'title': 'Voice check',
        'persona': 'a wary sailor',
      }));
      final test = session.playtests.single;
      expect(r['playtest_id'], test.id);
      expect(test.by, kMainAgentEditor);
      expect(test.title, 'Voice check');
      expect(test.persona, 'a wary sailor');
      expect(test.turns.map((t) => (t.user, t.text)), [
        (false, 'You made it, {{user}}.'),
        (true, 'Who are you?'),
        (false, 'reply to Who are you?'),
      ]);
      // The greeting went to the chat path as the start of the playtest.
      expect(services.playtests.single.earlier.single.text, 'You made it, {{user}}.');
    });

    test('carrying one on sends everything said so far', () async {
      final first = _json(await call('playtest', {
        'messages': ['Hello'],
        'greeting_index': 1,
        'scenario': 'A storm night.',
      }, agent: 'Subagent 3'));
      final id = first['playtest_id'] as String;
      expect(session.playtest(id)!.by, 'Subagent 3');
      await call('playtest', {'messages': ['And then?'], 'playtest_id': id},
          agent: 'Subagent 3');
      final again = services.playtests.last;
      expect(again.userTurns, ['And then?']);
      expect(again.earlier.map((t) => t.text),
          ['The lamp is out again.', 'Hello', 'reply to Hello']);
      expect(again.scenario, 'A storm night.');
      expect(again.greetingIndex, 1);
      expect(session.playtests, hasLength(1));
      expect(session.playtest(id)!.turns, hasLength(5));
    });

    test('the user\'s own chat cannot be taken over, and failures are kept',
        () async {
      final mine = StudioPlaytest(id: 'mine', by: kUserEditor);
      session.addPlaytest(mine);
      final r = await call('playtest', {'messages': ['x'], 'playtest_id': 'mine'});
      expect(r.isError, isTrue);
      expect(r.text, contains('user'));
      expect((await call('playtest', {'messages': ['x'], 'playtest_id': 'nope'})).isError,
          isTrue);
      services.failWith = Exception('no provider');
      final failed = await call('playtest', {'messages': ['Hi']});
      expect(failed.isError, isTrue);
      expect(failed.text, contains('no provider'));
      final kept = session.playtests.last;
      expect(kept.turns.last.error, isTrue);
      // A failed line is shown, never sent back.
      expect(kept.sendable.where((t) => t.error), isEmpty);
    });

    test('read_playtests lists newest first and reads one in full', () async {
      session.addPlaytest(StudioPlaytest(id: 'u', by: kUserEditor, turns: const [
        StudioPlaytestTurn(user: true, text: 'Tell me a secret.'),
        StudioPlaytestTurn(user: false, text: 'No.'),
      ]));
      await call('playtest', {'messages': ['Hi']});
      final list = (_json(await call('read_playtests', {}))['playtests'] as List)
          .cast<Map>();
      expect(list.map((p) => p['by']), ['the main agent', 'the user']);
      final one = _json(await call('read_playtests', {'playtest_id': 'u'}));
      expect(one['transcript'], [
        {'user': 'Tell me a secret.'},
        {'Maren': 'No.'},
      ]);
    });

    test('playtests are saved with the session, and capped', () {
      for (var i = 0; i < kStudioPlaytestLimit + 3; i++) {
        session.addPlaytest(StudioPlaytest(id: 'p$i', by: kUserEditor, persona: 'P'));
      }
      expect(session.playtests, hasLength(kStudioPlaytestLimit));
      expect(session.playtests.first.id, 'p3');
      session.playtests.last.turns.add(
          const StudioPlaytestTurn(user: false, text: 'oops', error: true));
      final back = StudioSession.fromJson(
        jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>,
      );
      expect(back.playtests.map((p) => p.id), session.playtests.map((p) => p.id));
      expect(back.playtests.last.turns.single.error, isTrue);
      expect(back.playtests.last.persona, 'P');
      // A rewind leaves them alone: they are not part of the draft.
      session.edit('set_fields', 'x', (ws) => ws.character.name = 'Other');
      session.rewindTo(session.ops.length - 1);
      expect(session.playtests, hasLength(kStudioPlaytestLimit));
    });

    test('a playtest is a chat: its turns are the chat\'s messages', () {
      final test = StudioPlaytest(id: 'p', by: 'Subagent 1', title: 'Voice',
          scenario: 'A storm night.', turns: const [
        StudioPlaytestTurn(user: false, text: 'You came back.'),
      ]);
      expect(test.chat.id, '${kHostedChatPrefix}p');
      expect(test.chat.scenarioOverride, 'A storm night.');
      test.turns
        ..add(const StudioPlaytestTurn(user: true, text: 'Hello?'))
        ..add(const StudioPlaytestTurn(user: false, text: 'no', error: true));
      expect(test.chat.messages.map((m) => (m.role, m.content, m.error)), [
        ('assistant', 'You came back.', false),
        ('user', 'Hello?', false),
        ('assistant', 'no', true),
      ]);
      // A turn the chat screen added reads back as a turn.
      test.chat.messages.add(ChatMessage(role: 'assistant', content: 'Mind it.'));
      expect(test.turns.last.text, 'Mind it.');
      expect(test.sendable.map((t) => t.text),
          ['You came back.', 'Hello?', 'Mind it.']);
    });

    test('a session saved before playtests were chats loads them as chats', () {
      final old = StudioPlaytest.fromJson({
        'id': 'old',
        'by': kUserEditor,
        'scenario': 'A storm night.',
        'turns': [
          {'user': false, 'text': 'Hi'},
          {'user': true, 'text': 'Yo'},
          {'user': false, 'text': 'boom', 'error': true},
        ],
      })!;
      expect(old.chat.id, '${kHostedChatPrefix}old');
      expect(old.scenario, 'A storm night.');
      expect(old.chat.messages.map((m) => (m.isUser, m.content, m.error)), [
        (false, 'Hi', false),
        (true, 'Yo', false),
        (false, 'boom', true),
      ]);
      final again = StudioPlaytest.fromJson(
          jsonDecode(jsonEncode(old.toJson())) as Map<String, dynamic>)!;
      expect(again.turns.map((t) => t.text), ['Hi', 'Yo', 'boom']);
      expect(again.scenario, 'A storm night.');
    });

    test('a Playground chat\'s pictures are kept by the picture sweep',
        () async {
      final dir = await Directory.systemTemp.createTemp('studio_pg_pics');
      addTearDown(() => dir.delete(recursive: true));
      final store = StudioStore(dir);
      final test = StudioPlaytest(id: 'p', by: kUserEditor);
      test.chat
        ..backgroundImage = 'local:behind.png'
        ..messages.add(ChatMessage(
          role: 'user',
          content: 'Look',
          images: [const MessageImage(ref: 'local:sent.png', mime: 'image/png')],
        ));
      session.addPlaytest(test);
      await store.save(session);
      final refs = await store.pictureRefs();
      expect(refs, containsAll(['local:behind.png', 'local:sent.png']));
    });
  });

  group('against the real app', () {
    late HttpServer server;
    late Directory dir;
    late List<Map<String, dynamic>> bodies;
    late List<List<Object>> script;

    Map<String, dynamic> words(String text) => {
          'choices': [
            {
              'delta': {'content': text},
            },
          ],
        };

    Map<String, dynamic> toolCall(String id, String name, Map<String, dynamic> args) => {
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': id,
                    'type': 'function',
                    'function': {'name': name, 'arguments': jsonEncode(args)},
                  },
                ],
              },
            },
          ],
        };

    Future<AppState> boot() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      bodies = [];
      dir = await Directory.systemTemp.createTemp('studio_workbench');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        bodies.add(jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>);
        final events = bodies.length <= script.length
            ? script[bodies.length - 1]
            : [words('(out of script)')];
        request.response.headers.contentType = ContentType('text', 'event-stream');
        for (final e in events) {
          request.response.write('data: ${jsonEncode(e)}\n\n');
        }
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });
      final state = AppState();
      await state.init();
      await state.addProvider(Provider(
        id: 'p',
        name: 'local',
        kind: ProviderKind.openai,
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'm',
        apiKey: 'k',
      ));
      return state;
    }

    tearDown(() async {
      await server.close(force: true);
      await dir.delete(recursive: true);
    });

    List<Map> messagesOf(Map<String, dynamic> body) =>
        (body['messages'] as List).cast<Map>();

    test('a continued playtest sends its whole chat, one system message first',
        () async {
      script = [
        [words('The '), words('storm passes.')],
      ];
      final state = await boot();
      final heard = <String>[];
      final replies = await state.playtestCharacter(
        character: Character(
          id: 'c',
          name: 'Maren',
          description: 'DESC_TOKEN',
          firstMes: 'unused greeting',
        ),
        userTurns: ['What now?'],
        transcript: [
          ChatMessage(role: 'assistant', content: 'Welcome, {{user}}.'),
          ChatMessage(role: 'user', content: 'Is it safe?'),
          ChatMessage(role: 'assistant', content: 'Not tonight.'),
        ],
        scenario: 'SCENARIO_TOKEN: a storm night.',
        onText: heard.add,
      );
      expect(replies, ['The storm passes.']);
      expect(heard.last, 'The storm passes.');
      final messages = messagesOf(bodies.single);
      final roles = [for (final m in messages) m['role']];
      expect(roles.first, 'system');
      expect(roles.where((r) => r == 'system'), hasLength(1));
      final wire = jsonEncode(messages);
      expect(wire, contains('DESC_TOKEN'));
      expect(wire, contains('SCENARIO_TOKEN'));
      expect(wire, isNot(contains('unused greeting')));
      expect(wire, isNot(contains('{{user}}')));
      // The chat so far, in order, then the new line last.
      final chat = [
        for (final m in messages)
          if (m['role'] != 'system') m['content'].toString(),
      ];
      final at = [
        for (final needle in ['Welcome,', 'Is it safe?', 'Not tonight.', 'What now?'])
          chat.indexWhere((c) => c.contains(needle)),
      ];
      expect(at.every((i) => i >= 0), isTrue, reason: '$chat');
      expect(at, orderedEquals([...at]..sort()));
      expect(chat.last, contains('What now?'));
      expect(state.conversations, isEmpty);
    });

    test('the prompt size is the assembled request, sent nowhere', () async {
      script = [];
      final state = await boot();
      final size = state.playtestPromptSize(
        character: Character(id: 'c', name: 'Maren', description: 'word ' * 300),
      );
      expect(size, isNotNull);
      expect(size!.tokens, greaterThan(300));
      expect(size.context, greaterThan(0));
      expect(bodies, isEmpty);
    });

    test('the Playground is a real chat with the draft: the app\'s own send, '
        'the draft as it stands, kept with the session and nowhere else',
        () async {
      script = [
        // The user's lines, through the chat's own send.
        [words('Mind the tide, stranger.')],
        [words('Then stay a while.')],
        // The lead's playtest: its call, then the character's reply, then its
        // closing words.
        [toolCall('t1', 'playtest', {'messages': ['Why stay?'], 'title': 'Why'})],
        [words('The light needs me.')],
        [words('She holds up.')],
      ];
      final state = await boot();
      final store = StudioStore(dir);
      final session = newStudioSession()
        ..workspace.character.name = 'Maren'
        ..workspace.character.description = 'DESC_TOKEN keeps the light'
        ..workspace.character.firstMes = 'You came back.'
        ..workspace.notes = 'NOTES_TOKEN';
      // The user's default persona: a new chat with the draft speaks as it,
      // as any new chat does.
      await state.addCharacter(
          Character(id: 'me', name: 'Ash', description: 'PERSONA_TOKEN'));
      await state.setDefaultPersona('me');
      final controller = StudioController(state: state, store: store, session: session);
      addTearDown(controller.flush);

      // Opening the Playground makes one of its chats the app's active chat —
      // a new one, seeded the way any new chat with a character is.
      final chatId = controller.playground.open();
      expect(state.hostedChatId, chatId);
      expect(state.active.id, chatId);
      expect(state.active.characterId, session.workspace.character.id);
      expect(state.active.messages.single.content, 'You came back.');
      // …and it is in none of the app's own lists.
      expect(state.conversations, isEmpty);

      await state.send('Hello?');
      final mine = controller.playtests.single;
      expect(mine.byUser, isTrue);
      expect(mine.turns.map((t) => t.text),
          ['You came back.', 'Hello?', 'Mind the tide, stranger.']);
      // A real chat request: one system message first, the draft's card in
      // it, no tools, and the notes nowhere.
      final first = bodies.single;
      expect(first.containsKey('tools'), isFalse);
      expect(messagesOf(first).first['role'], 'system');
      expect(messagesOf(first).where((m) => m['role'] == 'system'), hasLength(1));
      expect(jsonEncode(first), contains('DESC_TOKEN'));
      expect(jsonEncode(first), contains('PERSONA_TOKEN'));
      expect(state.active.impersonateId, 'me');
      expect(jsonEncode(first), isNot(contains('NOTES_TOKEN')));

      // The draft as it stands: an edit reaches the very next reply.
      controller.editByHand(
        'Changed the description by hand',
        (ws) => ws.character.description = 'FRESH_TOKEN keeps the light',
      );
      await state.send('Why here?');
      final second = jsonEncode(bodies[1]);
      expect(second, contains('FRESH_TOKEN'));
      expect(second, isNot(contains('DESC_TOKEN')));
      expect(second, contains('Mind the tide, stranger.'));

      // Kept with the session, and not in the app's conversations entry.
      await controller.flush();
      final back = await store.read(session.id);
      expect(back!.playtests.single.chat.messages.map((m) => m.content).last,
          'Then stay a while.');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('conversations') ?? '', isNot(contains('Why here?')));

      // An agent's playtest lands beside it, as a chat of its own.
      await controller.send('Playtest her.');
      await controller.flush();
      expect(controller.notice, isNull);
      final agentTest = controller.playtests.first;
      expect(agentTest.by, kMainAgentEditor);
      expect(agentTest.title, 'Why');
      expect(agentTest.turns.last.text, 'The light needs me.');
      expect(controller.playtests.map((p) => p.id), [agentTest.id, mine.id]);
      // The chat screen can show it: it is a chat with the draft.
      expect(controller.playground.chats.first.characterId,
          session.workspace.character.id);
      expect(state.conversations, isEmpty);

      // A failure lands in the chat as an error turn, never sent back.
      await server.close(force: true);
      await state.send('Still there?');
      expect(mine.turns.last.error, isTrue);
      expect(mine.sendable.last.text, 'Still there?');

      // Deleting the chat on screen moves the screen on to another.
      controller.deletePlaytest(mine.id);
      await Future<void>.delayed(Duration.zero);
      expect(controller.playtests.map((p) => p.id), [agentTest.id]);
      expect(state.hostedChatId, agentTest.chat.id);

      // Leaving hands the screen back to the app's own chats.
      controller.playground.close();
      expect(state.hostedChatId, isNull);
      expect(state.conversations, isEmpty);
    });

    test('a branch of a Playground chat stays in the Playground', () async {
      script = [];
      final state = await boot();
      final session = newStudioSession()
        ..workspace.character.name = 'Maren'
        ..workspace.character.firstMes = 'You came back.';
      final controller =
          StudioController(state: state, store: StudioStore(dir), session: session);
      addTearDown(controller.flush);
      final chatId = controller.playground.open();
      state.active.messages.add(ChatMessage(role: 'user', content: 'Hello?'));
      final fork = await state.forkConversation(chatId, 0);
      expect(fork, startsWith(kHostedChatPrefix));
      expect(state.hostedChatId, fork);
      expect(state.active.messages.single.content, 'You came back.');
      expect(controller.playtests.map((p) => p.chat.id), [fork, chatId]);
      expect(state.conversations, isEmpty);
      // Choosing a chat of the app's own leaves the Playground.
      final own = state.startChatWithCharacter(Character(id: 'o', name: 'Other'));
      expect(state.hostedChatId, isNull);
      expect(state.active.id, own);
      expect(state.conversations.map((c) => c.id), [own]);
    });
  });
}
