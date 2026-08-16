import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/services/chat_codec.dart';

/// A SillyTavern chat file: the header line SillyTavern's own importer checks
/// for, then one turn per line, with the character's second turn swiped.
String _tavernJsonl() => [
      jsonEncode({
        'user_name': 'unused',
        'character_name': 'unused',
        'create_date': '2026-08-16@10h00m00s000ms',
        'chat_metadata': {
          'integrity': 'abc',
          'variables': {'mood': 'calm'},
        },
      }),
      jsonEncode({
        'name': 'Mai',
        'is_user': false,
        'send_date': '2026-08-16T10:00:00.000Z',
        'mes': 'Hello there.',
        'extra': {'token_count': 3},
      }),
      jsonEncode({
        'name': 'Ubuntu',
        'is_user': true,
        'send_date': '2026-08-16T10:01:00.000Z',
        'mes': 'Hi Mai.',
        'extra': {},
      }),
      jsonEncode({
        'name': 'Mai',
        'is_user': false,
        'send_date': '2026-08-16T10:02:00.000Z',
        'mes': 'Second try.',
        'swipe_id': 1,
        'swipes': ['First try.', 'Second try.'],
        'swipe_info': [
          {'extra': <String, dynamic>{}},
          {
            'extra': {
              'reasoning': 'thinking hard',
              'reasoning_duration': 1200,
              'reasoning_type': 'model',
            },
          },
        ],
        'extra': {'reasoning': 'thinking hard', 'reasoning_duration': 1200},
      }),
      jsonEncode({
        'name': 'System',
        'is_user': false,
        'is_system': true,
        'mes': 'Group generation is disabled.',
      }),
    ].join('\n');

/// Agnai's "Export Chat" output: the four strings its importer requires, then
/// turns keyed `msg`, the user's marked by `userId`, alternatives in `retries`
/// (newest first, the live text kept in `msg`).
String _agnaiJson() => jsonEncode({
      'name': 'Exported',
      'greeting': 'Welcome back.',
      'scenario': 'A quiet library.',
      'sampleChat': '',
      'treeLeafId': 'abc12345',
      'messages': [
        {
          '_id': 'aaaa1111',
          'msg': 'Good evening.',
          'characterId': 'imported',
          'name': 'Mai',
          'handle': 'Mai',
          'createdAt': '2026-08-16T10:00:00.000Z',
        },
        {
          '_id': 'bbbb2222',
          'msg': 'Evening!',
          'userId': 'user-1',
          'handle': 'Ubuntu',
          'createdAt': '2026-08-16T10:01:00.000Z',
        },
        {
          '_id': 'cccc3333',
          'msg': 'The newest reply.',
          'characterId': 'imported',
          'handle': 'Mai',
          'createdAt': '2026-08-16T10:02:00.000Z',
          'retries': ['The middle reply.', 'The oldest reply.'],
        },
      ],
    });

/// A thread with everything this app can hold on a turn: swipes, thinking, a
/// live variant that is not the last one, and chat-scoped variables.
Conversation _richChat() => Conversation(
      id: 'c1',
      title: 'Tea with Mai',
      updatedAt: DateTime.parse('2026-08-16T12:00:00.000Z'),
      characterName: 'Mai',
      systemPrompt: 'You are Mai.',
      variables: {'mood': 'calm'},
      lorebookIds: ['lore-1'],
      messages: [
        ChatMessage(role: 'assistant', content: 'Tea?'),
        ChatMessage(role: 'user', content: 'Please.'),
        ChatMessage(
          role: 'assistant',
          swipes: const [
            MessageVariant(content: 'Earl Grey.'),
            MessageVariant(
              content: 'Sencha.',
              reasoning: 'she prefers green',
              thinkingMs: 900,
            ),
            MessageVariant(content: 'Chamomile.'),
          ],
          swipeIndex: 1,
        ),
      ],
    );

void main() {
  group('SillyTavern chats', () {
    test('reads the header, the turns and the swipes', () {
      final chats = ChatCodec.parse(_tavernJsonl(), fileName: 'Mai - 2026');
      expect(chats, hasLength(1));
      final imported = chats.single;
      expect(imported.format, ChatFormat.sillyTavern);
      final c = imported.conversation;
      // The interface notice is not a turn and must not become one.
      expect(c.messages, hasLength(3));
      expect(c.messages[0].role, 'assistant');
      expect(c.messages[0].content, 'Hello there.');
      expect(c.messages[1].role, 'user');
      expect(c.characterName, 'Mai');
      expect(imported.userName, 'Ubuntu');
      expect(c.variables['mood'], 'calm');
      // A header with no name of its own leaves the file name as the title.
      expect(c.title, 'Mai - 2026');
      expect(c.updatedAt, DateTime.parse('2026-08-16T10:02:00.000Z'));

      final swiped = c.messages[2];
      expect(swiped.swipeCount, 2);
      expect(swiped.swipeIndex, 1);
      expect(swiped.content, 'Second try.');
      expect(swiped.reasoning, 'thinking hard');
      expect(swiped.thinkingMs, 1200);
      expect(swiped.swipes.first.content, 'First try.');
      expect(swiped.swipes.first.reasoning, isEmpty);
    });

    test('reads a file with no header line', () {
      final text = [
        jsonEncode({'name': 'Mai', 'is_user': false, 'mes': 'Alone.'}),
        jsonEncode({'name': 'You', 'is_user': true, 'mes': 'Indeed.'}),
      ].join('\n');
      final c = ChatCodec.parse(text, fileName: 'orphan').single.conversation;
      expect(c.messages, hasLength(2));
      expect(c.messages.first.content, 'Alone.');
    });
  });
  group('Agnai chats', () {
    test('reads its export, puts the greeting back and unwinds retries', () {
      final imported = ChatCodec.parse(_agnaiJson(), fileName: 'chat-ab').single;
      expect(imported.format, ChatFormat.agnai);
      final c = imported.conversation;
      // The greeting lives on the chat, not in the log, so it has to be put back
      // as the opening turn — four messages out of three logged.
      expect(c.messages, hasLength(4));
      expect(c.messages.first.role, 'assistant');
      expect(c.messages.first.content, 'Welcome back.');
      expect(c.messages[2].role, 'user');
      expect(c.messages[2].content, 'Evening!');
      // Agnai's literal "Exported" says nothing, so the file name wins.
      expect(c.title, 'chat-ab');
      expect(c.characterName, 'Mai');
      expect(imported.userName, 'Ubuntu');
      // The scenario is prompt text with nowhere else to go.
      expect(c.systemPrompt, 'A quiet library.');

      final swiped = c.messages.last;
      expect(swiped.swipeCount, 3);
      // Oldest first here, and the live one is the text Agnai kept in `msg`.
      expect(
        swiped.swipes.map((s) => s.content).toList(),
        ['The oldest reply.', 'The middle reply.', 'The newest reply.'],
      );
      expect(swiped.content, 'The newest reply.');
    });
  });

  group('other ecosystems', () {
    test('text-generation-webui pairs', () {
      final text = jsonEncode({
        'data_visible': [
          ['Hi.', 'Hello.'],
          ['', 'A reply with no question.'],
        ],
      });
      final c = ChatCodec.parse(text, fileName: 'ooba').single;
      expect(c.format, ChatFormat.ooba);
      expect(c.conversation.messages, hasLength(3));
      expect(c.conversation.messages[1].role, 'assistant');
      expect(c.conversation.messages[2].content, 'A reply with no question.');
    });

    test('Character.AI dumps yield one chat per history', () {
      final text = jsonEncode({
        'histories': {
          'histories': [
            {
              'msgs': [
                {
                  'src': {'is_human': true, 'name': 'Ubuntu'},
                  'text': 'Hey.',
                },
                {
                  'src': {'is_human': false, 'name': 'Mai'},
                  'text': 'Hey yourself.',
                },
              ],
            },
            {
              'msgs': [
                {
                  'src': {'is_human': false, 'name': 'Mai'},
                  'text': 'A second history.',
                },
              ],
            },
            {'msgs': <dynamic>[]},
          ],
        },
      });
      final chats = ChatCodec.parse(text, fileName: 'cai');
      // The empty history is skipped rather than failing the file.
      expect(chats, hasLength(2));
      expect(chats.first.format, ChatFormat.cai);
      expect(chats.first.conversation.characterName, 'Mai');
      expect(chats.last.conversation.messages.single.content,
          'A second history.');
    });
  });
  group('other ecosystems, continued', () {
    test('RisuAI', () {
      final text = jsonEncode({
        'type': 'risuChat',
        'data': {
          'name': 'Risu talk',
          'message': [
            {'role': 'char', 'data': 'From Risu.', 'time': 1755000000000},
            {'role': 'user', 'data': 'To Risu.', 'name': 'Ubuntu'},
          ],
        },
      });
      final imported = ChatCodec.parse(text, fileName: 'risu').single;
      expect(imported.format, ChatFormat.risu);
      expect(imported.conversation.title, 'Risu talk');
      expect(imported.conversation.messages.first.role, 'assistant');
      expect(
        imported.conversation.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(1755000000000),
      );
    });

    test('KoboldAI Lite marks the speaker inside the text', () {
      final text = jsonEncode({
        'savedsettings': {
          'chatname': 'Ubuntu',
          'chatopponent': r'Mai||$||A calm librarian',
        },
        'prompt': '{{[INPUT]}} Are you there?',
        'actions': ['{{[OUTPUT]}} I am.', '{{[INPUT]}} Good.'],
      });
      final imported = ChatCodec.parse(text, fileName: 'kobold').single;
      expect(imported.format, ChatFormat.koboldLite);
      expect(imported.userName, 'Ubuntu');
      expect(imported.conversation.characterName, 'Mai');
      final roles =
          imported.conversation.messages.map((m) => m.role).toList();
      expect(roles, ['user', 'assistant', 'user']);
      expect(imported.conversation.messages.first.content, 'Are you there?');
    });

    test('a plain role/content log, with the system turn lifted out', () {
      final text = jsonEncode([
        {'role': 'system', 'content': 'You are helpful.'},
        {'role': 'user', 'content': 'Ping.'},
        {'role': 'assistant', 'content': 'Pong.'},
      ]);
      final imported = ChatCodec.parse(text, fileName: 'log').single;
      expect(imported.format, ChatFormat.plain);
      expect(imported.conversation.systemPrompt, 'You are helpful.');
      expect(imported.conversation.messages, hasLength(2));
    });

    test("Chub's nested message objects are flattened", () {
      final text = [
        jsonEncode({'user_name': 'Ubuntu', 'chat_metadata': {}}),
        jsonEncode({
          'name': 'Mai',
          'is_user': false,
          'mes': {'message': 'Nested text.'},
          'swipes': [
            {'message': 'Nested text.'},
            {'message': 'Another nest.'},
          ],
          'swipe_id': 0,
        }),
      ].join('\n');
      final c = ChatCodec.parse(text, fileName: 'chub').single.conversation;
      expect(c.messages.single.content, 'Nested text.');
      expect(c.messages.single.swipes.last.content, 'Another nest.');
    });

    test('an empty or unrecognised file explains itself', () {
      expect(() => ChatCodec.parse('   '), throwsA(isA<FormatException>()));
      expect(
        () => ChatCodec.parse(jsonEncode({'hello': 'world'})),
        throwsA(isA<FormatException>()),
      );
    });
  });
  group('export', () {
    test('the native file round trips without losing anything', () {
      final source = _richChat();
      final imported = ChatCodec.parse(
        ChatExportFormat.native.write(source),
        fileName: 'ignored',
      ).single;
      expect(imported.format, ChatFormat.native);
      final c = imported.conversation;
      // A fresh id, so importing the same file twice gives two threads.
      expect(c.id, isNot(source.id));
      expect(c.title, source.title);
      expect(c.characterName, 'Mai');
      expect(c.systemPrompt, 'You are Mai.');
      expect(c.variables, {'mood': 'calm'});
      expect(c.lorebookIds, ['lore-1']);
      expect(c.updatedAt, source.updatedAt);
      expect(c.messages, hasLength(3));
      final swiped = c.messages.last;
      expect(swiped.swipeIndex, 1);
      expect(
        swiped.swipes.map((s) => s.content).toList(),
        ['Earl Grey.', 'Sencha.', 'Chamomile.'],
      );
      expect(swiped.reasoning, 'she prefers green');
      expect(swiped.thinkingMs, 900);
    });

    test('our SillyTavern file reads back as the same thread', () {
      final source = _richChat();
      final text = ChatExportFormat.sillyTavern.write(source);
      final c = ChatCodec.parse(text, fileName: 'file name').single.conversation;
      // The title rides in the metadata, so the file name does not have to.
      expect(c.title, 'Tea with Mai');
      expect(c.characterName, 'Mai');
      expect(c.systemPrompt, 'You are Mai.');
      expect(c.variables, {'mood': 'calm'});
      expect(c.messages.map((m) => m.content).toList(),
          ['Tea?', 'Please.', 'Sencha.']);
      final swiped = c.messages.last;
      expect(swiped.swipeCount, 3);
      expect(swiped.swipeIndex, 1);
      expect(swiped.reasoning, 'she prefers green');
      expect(swiped.thinkingMs, 900);
    });

    test('our Agnai file reads back, retries and all', () {
      final source = _richChat();
      final c = ChatCodec.parse(
        ChatExportFormat.agnai.write(source, characterName: 'Mai'),
        fileName: 'agnai',
      ).single.conversation;
      expect(c.messages.map((m) => m.content).toList(),
          ['Tea?', 'Please.', 'Sencha.']);
      final swiped = c.messages.last;
      expect(swiped.swipeCount, 3);
      expect(swiped.content, 'Sencha.');
      // Agnai has no home for per-swipe thinking, and we do not invent one.
      expect(swiped.reasoning, isEmpty);
    });

    test('plain text is the transcript SillyTavern writes', () {
      final text = ChatExportFormat.text.write(
        _richChat(),
        userName: 'Ubuntu',
      );
      expect(text, 'Mai: Tea?\n\nUbuntu: Please.\n\nMai: Sencha.');
    });
  });
  // Each of these mirrors the other app's real check, so a change here fails
  // loudly instead of producing a file that app silently refuses.
  group('what the other apps will accept', () {
    test("SillyTavern's .jsonl import accepts our SillyTavern file", () {
      final lines = ChatExportFormat.sillyTavern
          .write(_richChat())
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      // src/endpoints/chats.js: the header must define at least one of
      // user_name / name / chat_metadata, or the import is refused.
      final head = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(
        head['user_name'] != null ||
            head['name'] != null ||
            head['chat_metadata'] != null,
        isTrue,
      );
      // Every other line must parse, and swipe_id has to index into swipes or
      // SillyTavern's swipe control reads past the end.
      for (final line in lines.skip(1)) {
        final turn = jsonDecode(line) as Map<String, dynamic>;
        expect(turn['mes'], isA<String>());
        expect(turn['is_user'], isA<bool>());
        expect(turn['send_date'], isA<String>());
        final swipes = turn['swipes'];
        if (swipes is List) {
          expect(turn['swipe_id'], isA<int>());
          expect(turn['swipe_id'] as int, lessThan(swipes.length));
          expect((turn['swipe_info'] as List).length, swipes.length);
        }
      }
    });

    test("Agnai's importer accepts our SillyTavern file as a TavernAI log", () {
      // web/pages/Character/ImportChat.tsx: it drops line 1, then JSON.parses
      // every remaining line and takes String(line.mes) and line.is_user.
      final lines = ChatExportFormat.sillyTavern
          .write(_richChat())
          .split('\n')
          .skip(1)
          .where((l) => l.trim().isNotEmpty);
      expect(lines, isNotEmpty);
      for (final line in lines) {
        final turn = jsonDecode(line) as Map<String, dynamic>;
        expect(turn['mes'], isA<String>());
      }
    });

    test("Agnai's importer accepts our native and Agnai files", () {
      for (final format in [ChatExportFormat.native, ChatExportFormat.agnai]) {
        final json =
            jsonDecode(format.write(_richChat())) as Map<String, dynamic>;
        // Its validator wants these four as strings — not optional — and every
        // message to carry a string msg.
        for (final key in ['name', 'greeting', 'scenario', 'sampleChat']) {
          expect(json[key], isA<String>(), reason: '$format is missing $key');
        }
        final messages = json['messages'] as List;
        expect(messages, isNotEmpty);
        for (final turn in messages.cast<Map<String, dynamic>>()) {
          expect(turn['msg'], isA<String>());
          if (turn['userId'] != null) expect(turn['userId'], isA<String>());
          if (turn['characterId'] != null) {
            expect(turn['characterId'], isA<String>());
          }
        }
      }
    });

    test("SillyTavern's JSON import reads our native and Agnai files", () {
      for (final format in [ChatExportFormat.native, ChatExportFormat.agnai]) {
        final json =
            jsonDecode(format.write(_richChat())) as Map<String, dynamic>;
        // src/endpoints/chats.js picks importAgnaiChat for any object with a
        // messages array, and decides the speaker with `!!message.userId`.
        expect(json['messages'], isA<List>());
        final messages = (json['messages'] as List).cast<Map<String, dynamic>>();
        final roles = messages
            .map((m) => (m['userId'] != null) ? 'user' : 'assistant')
            .toList();
        expect(roles, ['assistant', 'user', 'assistant']);
        // `characterId: 'imported'` is the marker Agnai swaps for the real
        // character on the way in.
        expect(messages.first['characterId'], 'imported');
      }
    });
  });
// APPEND-MARKER
}
