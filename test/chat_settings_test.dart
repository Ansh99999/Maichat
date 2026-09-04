import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/view_prefs.dart';
import 'package:maichat/screens/chat_settings_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// The Chat settings screen and the per-chat state behind it: a background, a
/// chat style of its own, and character definitions that apply to one chat only.
void main() {
  Future<AppState> boot() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final state = AppState();
    await state.init();
    await state.addProvider(Provider(
      id: 'p',
      name: 'l',
      kind: ProviderKind.openai,
      baseUrl: 'https://example.com/v1',
      model: 'm',
      apiKey: 'k',
    ));
    return state;
  }

  Widget host(AppState state, String chatId) => ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: ChatSettingsScreen(conversationId: chatId),
        ),
      );

  group('per-chat state', () {
    test('the new fields survive a JSON round-trip', () {
      final source = Conversation.empty()
        ..backgroundImage = 'local:bg.png'
        ..backgroundOpacity = 0.4
        ..overrideDefinitions = true
        ..interfaceOverride = const ChatInterface(bubbles: false, fontSize: 21);
      source.characterOverrides['c'] =
          Character(id: 'c', name: 'Chat Aria', description: 'louder');

      final read = Conversation.fromJson(source.toJson());

      expect(read.backgroundImage, 'local:bg.png');
      expect(read.backgroundOpacity, 0.4);
      expect(read.overrideDefinitions, isTrue);
      expect(read.interfaceOverride?.bubbles, isFalse);
      expect(read.interfaceOverride?.fontSize, 21);
      expect(read.characterOverrides['c']?.name, 'Chat Aria');
      expect(read.characterOverrides['c']?.description, 'louder');
    });

    test('a chat with no overrides writes none of the new keys', () {
      final json = Conversation.empty().toJson();
      expect(json.containsKey('backgroundImage'), isFalse);
      expect(json.containsKey('backgroundOpacity'), isFalse);
      expect(json.containsKey('interfaceOverride'), isFalse);
      expect(json.containsKey('overrideDefinitions'), isFalse);
      expect(json.containsKey('characterOverrides'), isFalse);
    });

    test('an override is only honoured while overriding is on', () async {
      final state = await boot();
      final card = Character(id: 'c', name: 'Aria', description: 'calm');
      await state.addCharacter(card);
      final chatId = state.startChatWithCharacter(card);

      await state.saveChatCharacterOverride(
        chatId,
        card.clone()..description = 'furious',
      );
      final chat = state.conversationById(chatId)!;

      // Storing one switches overriding on by itself.
      expect(chat.overrideDefinitions, isTrue);
      expect(state.characterFor(chat, 'c')?.description, 'furious');
      // The roster is untouched — that is the whole point.
      expect(state.characterById('c')?.description, 'calm');

      await state.setOverrideDefinitions(chatId, false);
      expect(state.characterFor(chat, 'c')?.description, 'calm');

      await state.setOverrideDefinitions(chatId, true);
      expect(state.characterFor(chat, 'c')?.description, 'furious');
      await state.clearChatCharacterOverride(chatId, 'c');
      expect(state.characterFor(chat, 'c')?.description, 'calm');
    });

    test('the prompt carries the chat\'s own definition', () async {
      final state = await boot();
      final card = Character(id: 'c', name: 'Aria', description: 'calm');
      await state.addCharacter(card);
      final chatId = state.startChatWithCharacter(card);
      await state.saveChatCharacterOverride(
        chatId,
        card.clone()..description = 'furious',
      );

      final chat = state.conversationById(chatId)!;
      final assembled = state.assemblePromptForMessage(chat, 0);
      final text = assembled.messages.map((m) => m.content).join('\n');

      expect(text, contains('furious'));
      expect(text, isNot(contains('calm')));
    });

    test('a chat style of its own does not follow the app-wide one', () async {
      final state = await boot();
      final chat = state.active;
      expect(state.interfaceFor(chat).fontSize, state.chatInterface.fontSize);

      await state.saveChatInterfaceOverride(
        chat.id,
        state.chatInterface.copyWith(fontSize: 23),
      );
      await state.updateChatInterface(
        state.chatInterface.copyWith(fontSize: 12),
      );

      expect(state.interfaceFor(chat).fontSize, 23);
      expect(state.chatInterface.fontSize, 12);

      await state.clearChatInterfaceOverride(chat.id);
      expect(state.interfaceFor(chat).fontSize, 12);
    });
  });

  group('the screen', () {
    testWidgets('lists the chat title, background, style and who is in it',
        (tester) async {
      final state = await boot();
      final card = Character(id: 'c', name: 'Aria', description: 'calm');
      await state.addCharacter(card);
      final chatId = state.startChatWithCharacter(card);

      await tester.pumpWidget(host(state, chatId));
      await tester.pumpAndSettle();

      expect(find.text('Chat settings'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Aria'), findsOneWidget);
      expect(find.text('Custom background'), findsOneWidget);
      expect(find.text('Custom chat appearance'), findsOneWidget);
      expect(find.text('Characters involved'), findsOneWidget);
      expect(find.text('Enable overriding definitions'), findsOneWidget);
      // The character and the user, one row each.
      expect(find.text('Aria'), findsWidgets);
      expect(find.text('You'), findsOneWidget);
    });

    testWidgets('a group chat lists every member', (tester) async {
      final state = await boot();
      await state
          .updateChatInterface(const ChatInterface(groupChatsEnabled: true));
      final alice = Character(id: 'a', name: 'Alice');
      final bob = Character(id: 'b', name: 'Bob');
      await state.addCharacter(alice);
      await state.addCharacter(bob);
      final chatId = state.startChatWithCharacter(alice);
      await state.addParticipant(chatId, bob);

      await tester.pumpWidget(host(state, chatId));
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsWidgets); // title field + its row
      expect(find.text('Bob'), findsOneWidget);
      // Two members plus the user is one row more than fits the test viewport,
      // so the user's row is scrolled to rather than assumed to be on screen.
      await tester.drag(find.byType(ListView), const Offset(0, -240));
      await tester.pumpAndSettle();
      expect(find.text('You'), findsOneWidget);
    });

    testWidgets('with group chats on, Add opens the sheet, not a refusal',
        (tester) async {
      final state = await boot();
      await state
          .updateChatInterface(const ChatInterface(groupChatsEnabled: true));
      final alice = Character(id: 'a', name: 'Alice');
      final bob = Character(id: 'b', name: 'Bob');
      await state.addCharacter(alice);
      await state.addCharacter(bob);
      final chatId = state.startChatWithCharacter(alice);

      await tester.pumpWidget(host(state, chatId));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add a character'));
      await tester.pumpAndSettle();

      // The add/remove sheet, not the old "one character per chat" refusal.
      expect(find.text('Add characters'), findsOneWidget);
      expect(find.textContaining('One character per chat'), findsNothing);

      // Adding Bob from the sheet turns the thread into a group.
      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(state.conversationById(chatId)!.isGroup, isTrue);
    });

    testWidgets('editing a character needs the overriding toggle on',
        (tester) async {
      final state = await boot();
      final card = Character(id: 'c', name: 'Aria', description: 'calm');
      await state.addCharacter(card);
      final chatId = state.startChatWithCharacter(card);

      await tester.pumpWidget(host(state, chatId));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Needs overriding definitions on'), findsOneWidget);
      // Tapping a disabled item does nothing, so dismiss the menu instead.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Needs overriding definitions on'), findsNothing);
      expect(find.text('Edit'), findsOneWidget);
    });

    testWidgets('the title is only written on Save', (tester) async {
      final state = await boot();
      final card = Character(id: 'c', name: 'Aria');
      await state.addCharacter(card);
      final chatId = state.startChatWithCharacter(card);

      await tester.pumpWidget(host(state, chatId));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'Long night');
      await tester.pumpAndSettle();
      expect(state.conversationById(chatId)!.title, 'Aria');

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();
      expect(state.conversationById(chatId)!.title, 'Long night');
    });

    testWidgets('an edit kept "for this chat" leaves the roster alone',
        (tester) async {
      final state = await boot();
      final card = Character(id: 'c', name: 'Aria', description: 'calm');
      await state.addCharacter(card);
      final chatId = state.startChatWithCharacter(card);

      await tester.pumpWidget(host(state, chatId));
      await tester.pumpAndSettle();

      // Overriding on, then Edit from the character's own menu.
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      // Creator v2, on a draft: saving there writes nothing yet.
      expect(find.text('Scenarios'), findsOneWidget);
      await tester.tap(find.text('Persona'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('creator-description')),
          matching: find.byType(TextField),
        ),
        'furious',
      );
      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();
      expect(state.characterById('c')!.description, 'calm');
      // The note sits under the participant list, past the foot of the viewport.
      await tester.drag(find.byType(ListView), const Offset(0, -240));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 character change waiting'), findsOneWidget);

      // Now Save the screen and send the change to this chat only.
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<CharacterSaveTarget>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('For this chat').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final chat = state.conversationById(chatId)!;
      expect(chat.characterOverrides['c']?.description, 'furious');
      expect(state.characterById('c')!.description, 'calm');
      expect(state.characterFor(chat, 'c')?.description, 'furious');
    });

    testWidgets('the legacy editor collects a draft the same way',
        (tester) async {
      final state = await boot();
      // The whole point of keeping Creator v1 is that it still works everywhere
      // Creator v2 does — including the one route that edits a *draft* rather
      // than the stored card.
      await state.setCreatorVersion(CreatorVersion.v1);
      final card = Character(id: 'c', name: 'Aria', description: 'calm');
      await state.addCharacter(card);
      final chatId = state.startChatWithCharacter(card);

      await tester.pumpWidget(host(state, chatId));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(find.text('Edit character'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Description'),
        'furious',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(state.characterById('c')!.description, 'calm');
      await tester.drag(find.byType(ListView), const Offset(0, -240));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 character change waiting'), findsOneWidget);
    });
  });

  group('the save dialog', () {
    Future<Map<String, CharacterSaveTarget>?> open(
      WidgetTester tester,
      List<Character> edits,
    ) async {
      Map<String, CharacterSaveTarget>? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<Map<String, CharacterSaveTarget>>(
                context: context,
                builder: (_) => CharacterSaveDialog(edits: edits),
              );
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('refuses to finish while a change has no home',
        (tester) async {
      await open(tester, [
        Character(id: 'a', name: 'Aria'),
        Character(id: 'b', name: 'Brenn'),
      ]);

      expect(find.text('You have made changes for 2 characters:'),
          findsOneWidget);
      expect(find.text('Save'), findsWidgets);

      // Answer one row, then try to finish.
      await tester.tap(find.byType(PopupMenuButton<CharacterSaveTarget>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('For this chat').last);
      await tester.pumpAndSettle();
      expect(find.text('Saved for chat'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Address the following changes before saving'),
        findsOneWidget,
      );
      // Still open — nothing was saved.
      expect(find.text('Saved for chat'), findsOneWidget);
    });

    testWidgets('returns a target for every change once each is answered',
        (tester) async {
      Map<String, CharacterSaveTarget>? captured;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              captured = await showDialog<Map<String, CharacterSaveTarget>>(
                context: context,
                builder: (_) => CharacterSaveDialog(edits: [
                  Character(id: 'a', name: 'Aria'),
                  Character(id: 'b', name: 'Brenn'),
                ]),
              );
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<CharacterSaveTarget>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('For this chat').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<CharacterSaveTarget>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Globally').last);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(captured, {
        'a': CharacterSaveTarget.chat,
        'b': CharacterSaveTarget.global,
      });
    });
  });
}
