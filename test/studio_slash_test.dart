import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/message_image.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/studio/shell/slash_commands.dart';
import 'package:maichat/services/studio/studio_commands.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_memory.dart';
import 'package:maichat/services/studio/studio_skills.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Starters implements StarterSkillSource {
  _Starters(this.skills);
  final Map<String, Map<String, String>> skills;
  @override
  Future<Map<String, Map<String, String>>> load() async => skills;
}

/// `/` commands end to end: a real [AppState] and [StudioController], the
/// real command runner, and a loopback model — asserting what actually goes
/// out on the wire (and that app-only commands send nothing at all).
void main() {
  late HttpServer server;
  late Directory dir;
  late List<Map<String, dynamic>> requests;

  Map<String, dynamic> words(String text) => {
        'choices': [
          {
            'delta': {'content': text},
          },
        ],
      };

  Future<(AppState, StudioController)> boot({
    Map<String, Map<String, String>> skills = const {},
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StudioSkillLibrary.resetShared();
    StudioCommandStore.resetShared();
    StudioMemory.resetShared();
    requests = [];
    dir = await Directory.systemTemp.createTemp('studio_slash');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      requests.add(body);
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode(words('Done.'))}\n\n');
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
      model: 'builder',
      apiKey: 'k',
    ));
    await StudioSkillLibrary.forDirectory(dir, starters: _Starters(skills));
    await StudioCommandStore.forDirectory(dir);
    final controller = StudioController(
      state: state,
      store: StudioStore(dir),
      session: newStudioSession(),
    );
    addTearDown(controller.flush);
    return (state, controller);
  }

  tearDown(() async {
    await server.close(force: true);
    StudioSkillLibrary.resetShared();
    StudioCommandStore.resetShared();
    StudioMemory.resetShared();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  /// The runner as the screen builds it, with its UI actions recorded.
  ({StudioSlashCommands runner, List<String> did}) wire(
    StudioController controller,
  ) {
    final did = <String>[];
    final runner = StudioSlashCommands(
      controller: controller,
      onHelp: () => did.add('help'),
      onSkills: () => did.add('skills'),
      onContext: () => did.add('context'),
      onAgents: () => did.add('agents'),
      onNewSession: () async => did.add('new'),
      onToast: (m) => did.add('toast: $m'),
      onUnknown: (text, images, name) => did.add('unknown: $name'),
    );
    controller.onSlashCommand = runner.handle;
    return (runner: runner, did: did);
  }

  List<Map> messages(Map<String, dynamic> body) =>
      (body['messages'] as List).cast<Map>();

  const voice = {
    'voice': {
      'SKILL.md': '---\nname: voice\ndescription: Sharpens how a character '
          'talks. Use for dialogue work.\n---\n\nVOICE_RULES: one habit per line.',
      'references/samples.md': 'Sample lines.',
    },
  };

  test('a /skill turn carries the skill\'s instructions before the user\'s '
      'words', () async {
    final (_, controller) = await boot(skills: voice);
    wire(controller);
    await controller.send('/voice make her drier');

    expect(requests, hasLength(1));
    final body = requests.single;
    final last = messages(body).last;
    expect(last['role'], 'user');
    final text = last['content'] as String;
    expect(text, contains('<skill_content name="voice">'));
    expect(text, contains('VOICE_RULES: one habit per line.'));
    expect(text, contains('references/samples.md'));
    expect(text.indexOf('VOICE_RULES'), lessThan(text.indexOf('make her drier')));
    expect(text.trim(), endsWith('make her drier'));
    // The system prompt lists the skill, and the tools can load it.
    expect(messages(body).first['content'], contains('- voice: Sharpens'));
    final tools = [
      for (final t in body['tools'] as List) (t as Map)['function']['name'],
    ];
    expect(tools, containsAll(['use_skill', 'read_skill_file']));
    // The transcript keeps it as a skill turn; the title is the user's words.
    final turn = controller.session.transcript.first;
    expect(parseSkillInvocation(turn.text)!.skill, 'voice');
    expect(controller.session.title, 'make her drier');
  });

  test('with no skill on, nothing about skills goes out', () async {
    final (_, controller) = await boot();
    wire(controller);
    await controller.send('Hello there.');
    final body = requests.single;
    expect(messages(body).first['content'], isNot(contains('available_skills')));
    final tools = [
      for (final t in body['tools'] as List) (t as Map)['function']['name'],
    ];
    expect(tools, isNot(contains('use_skill')));
  });

  test('a command of your own sends its filled-in template', () async {
    final (_, controller) = await boot();
    await StudioCommandStore.active!.save(const StudioCommand(
      name: 'villain',
      description: 'Add a villain',
      kind: StudioCommandKind.custom,
      template: 'Add a villain to this story who \$ARGUMENTS.',
    ));
    wire(controller);
    await controller.send('/villain hates the sea');
    expect(messages(requests.single).last['content'],
        'Add a villain to this story who hates the sea.');
  });

  test('/playtest asks the agent to playtest with the given line', () async {
    final (_, controller) = await boot();
    wire(controller);
    await controller.send('/playtest Why do you stay?');
    final text = messages(requests.single).last['content'] as String;
    expect(text, contains('Playtest the draft now'));
    expect(text, contains('"Why do you stay?"'));
  });

  test('app-only commands never reach the model', () async {
    final (state, controller) = await boot();
    final w = wire(controller);
    for (final line in ['/help', '/skills', '/context', '/new', '/stop',
                        '/agents']) {
      await controller.send(line);
    }
    expect(requests, isEmpty);
    expect(controller.session.transcript, isEmpty);
    expect(w.did, [
      'help',
      'skills',
      'context',
      'new',
      'toast: Nothing is running.',
      'toast: No sub-agents in this session yet.',
    ]);

    // /remember writes the memory straight away.
    await controller.send('/remember Prefers third-person present.');
    final memory = await StudioMemory.forDirectory(dir);
    expect(memory.notes, ['Prefers third-person present.']);
    expect(w.did.last, 'toast: Remembered.');
    await state.updateStudioConfig(
      state.studioConfig.copyWith(memoryEnabled: false),
    );
    await controller.send('/remember Likes tea.');
    expect(w.did.last, contains('Memory is off'));
    expect(requests, isEmpty);
    await memory.flush();
  });

  test('an unknown command is handed back, and "send as text" sends it', () async {
    final (_, controller) = await boot();
    final w = wire(controller);
    await controller.send('/wizard do magic');
    expect(requests, isEmpty);
    expect(w.did, ['unknown: wizard']);
    await controller.send('/wizard do magic', asText: true);
    expect(messages(requests.single).last['content'], '/wizard do magic');
  });

  test('pictures sent with a skill command go with it', () async {
    final (_, controller) = await boot(skills: voice);
    wire(controller);
    await controller.send(
      '/voice this face',
      images: const [MessageImage(ref: 'https://example.com/face.png')],
    );
    final content = messages(requests.single).last['content'];
    expect(content, isA<List>());
    expect(jsonEncode(content), contains('https://example.com/face.png'));
  });

  test('/compact summarises the older conversation now', () async {
    final (_, controller) = await boot();
    final w = wire(controller);
    // Too short to be worth it: nothing is sent.
    controller.session.transcript
      ..add(AgentMessage.user('Hello.'))
      ..add(AgentMessage(role: AgentRole.assistant, text: 'Hi.'));
    await controller.send('/compact');
    expect(requests, isEmpty);
    expect(w.did.last, 'toast: Nothing to summarise yet.');

    // A conversation long enough that there is something to summarise.
    for (var i = 0; i < 12; i++) {
      controller.session.transcript
        ..add(AgentMessage.user('Question $i: ${'words ' * 40}'))
        ..add(AgentMessage(
            role: AgentRole.assistant, text: 'Answer $i. ${'more ' * 40}'));
    }
    await controller.send('/compact');
    expect(requests, hasLength(1));
    // The one request is the summariser, not a turn of the conversation.
    expect(messages(requests.single).first['content'],
        contains('summarising your own working session'));
    expect(controller.session.compactions, hasLength(1));
    expect(w.did.last, 'toast: Summarised the older conversation.');
  });
}
