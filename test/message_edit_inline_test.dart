import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/message_image.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/character_avatar.dart';
import 'package:maichat/widgets/message_bubble.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// Editing a turn **in place**: the avatar, the sender name, the pictures, the
/// bubble and every layout choice stay exactly where they were, the words become
/// editable where they sit, and the only thing that changes is the action bar —
/// ✕ and ✓ take its place. The turn used to be replaced wholesale by a boxed
/// editor, which meant the avatar and the name vanished the moment Edit was
/// tapped.
class _FakeClient extends ChatClient {
  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    yield const ChatDelta(text: 'Gulls, mostly.');
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const ['m'];
}

void main() {
  Character card() => Character(
        id: 'alice',
        name: 'Alice',
        description: 'Curious.',
      );

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SizedBox(width: 420, height: 700, child: child)),
      );

  group('the bubble in edit mode', () {
    Widget bubble({
      required bool editing,
      ChatInterface ui = const ChatInterface(),
      ChatMessage? message,
      TextEditingController? controller,
    }) =>
        MessageBubble(
          message: message ??
              ChatMessage(role: 'assistant', content: 'Gulls, mostly.'),
          ui: ui,
          character: card(),
          editing: editing,
          editController: controller,
          onEditSave: () {},
          onEditCancel: () {},
          onAction: (_) {},
          onSwipe: (_) {},
        );

    testWidgets('everything but the action bar survives the switch',
        (tester) async {
      // A line comfortably short of the thread's width: a message that ends
      // within a caret's width of the edge is the one case where the editor has
      // to rewrap it, and that is not what this test is about.
      final controller = TextEditingController(text: 'Gulls, mostly.');
      const ui = ChatInterface(showNames: true);

      await tester.pumpWidget(host(bubble(editing: false, ui: ui)));
      expect(find.text('Alice'), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget,
          reason: 'the action bar is there to begin with');
      final avatarBefore = tester.getRect(find.byType(CharacterAvatar));
      final nameBefore = tester.getRect(find.text('Alice'));

      await tester.pumpWidget(
          host(bubble(editing: true, ui: ui, controller: controller)));
      await tester.pump();

      // The picture and the name have not moved a pixel.
      expect(tester.getRect(find.byType(CharacterAvatar)), avatarBefore);
      expect(tester.getRect(find.text('Alice')), nameBefore);
      // The words are editable, and they are the words that were there.
      expect(find.byKey(const Key('message-editor')), findsOneWidget);
      expect(controller.text, 'Gulls, mostly.');
      // ✕ and ✓ stand where the action bar stood, and it is out of reach — it is
      // still measured, invisibly, which is what keeps the slot the size it was.
      expect(find.byKey(const Key('edit-cancel')), findsOneWidget);
      expect(find.byKey(const Key('edit-save')), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined).hitTestable(), findsNothing);
      expect(find.byIcon(Icons.refresh).hitTestable(), findsNothing);
    });

    testWidgets('a short turn keeps its bubble, rather than filling the row',
        (tester) async {
      final short = ChatMessage(role: 'assistant', content: 'Aye.');
      await tester.pumpWidget(host(bubble(editing: false, message: short)));
      final before = tester.getSize(find.byType(MessageBubble)).width;

      await tester.pumpWidget(host(bubble(
        editing: true,
        message: short,
        controller: TextEditingController(text: 'Aye.'),
      )));
      await tester.pump();
      final after = tester.getSize(find.byType(MessageBubble)).width;

      expect(after, closeTo(before, 12),
          reason: 'a bare TextField would stretch to the whole thread width');
    });

    testWidgets('the pictures on the turn stay put', (tester) async {
      final withImage = ChatMessage(
        role: 'assistant',
        content: 'Here.',
        images: const [MessageImage(ref: 'local:missing.png', mime: 'image/png')],
      );
      await tester.pumpWidget(host(bubble(
        editing: true,
        message: withImage,
        controller: TextEditingController(text: 'Here.'),
      )));
      await tester.pump();
      expect(find.byKey(const Key('message-editor')), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget,
          reason: 'the attachment row is still drawn while editing');
    });

    testWidgets("the swipe control stays, and stays out of the editor's way",
        (tester) async {
      final swiped = ChatMessage(role: 'assistant', content: 'first')
          .addSwipe(const MessageVariant(content: 'second'));
      await tester.pumpWidget(host(bubble(
        editing: true,
        message: swiped,
        controller: TextEditingController(text: 'second'),
      )));
      await tester.pump();

      expect(find.text('2 / 2'), findsOneWidget);
      final back = tester.widget<IconButton>(find.ancestor(
        of: find.byIcon(Icons.chevron_left),
        matching: find.byType(IconButton),
      ));
      expect(back.onPressed, isNull,
          reason: 'swapping the text under a live editor is nobody\'s intent');
    });

    testWidgets('✕/✓ land in every action-bar placement, in every layout',
        (tester) async {
      // The bar has five homes and the text three placements, and each
      // combination assembles the turn differently — a fallback that quietly
      // dropped the bar would leave an editor with no way out.
      for (final placement in ActionBarPlacement.values) {
        for (final text in TextPlacement.values) {
          for (final names in [true, false]) {
            final ui = ChatInterface(
              actionBarPlacement: placement,
              textPlacement: text,
              showNames: names,
            );
            await tester.pumpWidget(host(bubble(
              editing: true,
              ui: ui,
              controller: TextEditingController(text: 'Gulls, mostly.'),
            )));
            await tester.pump();
            final where = '$placement / $text / names=$names';
            expect(tester.takeException(), isNull, reason: where);
            expect(find.byKey(const Key('edit-cancel')), findsOneWidget,
                reason: where);
            expect(find.byKey(const Key('edit-save')), findsOneWidget,
                reason: where);
            expect(find.byKey(const Key('message-editor')), findsOneWidget,
                reason: where);
          }
        }
      }
    });

    testWidgets('the way out is there even with message actions switched off',
        (tester) async {
      await tester.pumpWidget(host(bubble(
        editing: true,
        ui: const ChatInterface(messageActionsEnabled: false),
        controller: TextEditingController(text: 'Gulls, mostly.'),
      )));
      await tester.pump();
      expect(find.byKey(const Key('edit-cancel')), findsOneWidget);
      expect(find.byKey(const Key('edit-save')), findsOneWidget);
    });
  });

  group('through the chat screen', () {
    late _FakeClient client;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      client = _FakeClient();
    });

    Future<AppState> boot() async {
      final state = AppState(client: client);
      await state.init();
      await state.addProvider(Provider(
        id: 'p',
        name: 'local',
        kind: ProviderKind.openai,
        baseUrl: 'https://host.tld/v1',
        model: 'm',
        apiKey: 'k',
      ));
      final alice = card();
      await state.addCharacter(alice);
      state.startChatWithCharacter(alice);
      state.active.messages
        ..clear()
        ..add(ChatMessage(role: 'user', content: 'Where are we?'))
        ..add(ChatMessage(role: 'assistant', content: 'Gulls, mostly.'));
      await state.updateChatInterface(
          state.chatInterface.copyWith(showNames: true));
      return state;
    }

    Widget chat(AppState state) => ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: ChatScreen()),
        );

    /// Taps Edit on the reply (the inline pencil on the newest turn).
    Future<void> startEditing(WidgetTester tester) async {
      // The thread is a reversed list, so the newest turn — the reply — is the
      // first bubble in the tree.
      await tester.tap(find.byIcon(Icons.edit_outlined).first);
      await tester.pumpAndSettle();
    }

    testWidgets('the reply is edited where it sits, name and all',
        (tester) async {
      final state = await boot();
      await tester.pumpWidget(chat(state));
      await tester.pumpAndSettle();

      final nameBefore = tester.getRect(find.text('Alice'));
      await startEditing(tester);

      expect(find.byKey(const Key('message-editor')), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(tester.getRect(find.text('Alice')), nameBefore,
          reason: 'the sender label has not moved');

      await tester.enterText(
          find.byKey(const Key('message-editor')), 'Terns, mostly.');
      await tester.tap(find.byKey(const Key('edit-save')));
      await tester.pumpAndSettle();

      expect(state.active.messages.last.content, 'Terns, mostly.');
      expect(find.byKey(const Key('message-editor')), findsNothing);
      expect(find.text('Terns, mostly.'), findsOneWidget);
    });

    testWidgets('✕ leaves the turn as it was', (tester) async {
      final state = await boot();
      await tester.pumpWidget(chat(state));
      await tester.pumpAndSettle();

      await startEditing(tester);
      await tester.enterText(
          find.byKey(const Key('message-editor')), 'something else');
      await tester.tap(find.byKey(const Key('edit-cancel')));
      await tester.pumpAndSettle();

      expect(state.active.messages.last.content, 'Gulls, mostly.');
      expect(find.byKey(const Key('message-editor')), findsNothing);
    });

    testWidgets('deleting the turn being edited closes the editor',
        (tester) async {
      final state = await boot();
      await tester.pumpWidget(chat(state));
      await tester.pumpAndSettle();

      await startEditing(tester);
      expect(find.byKey(const Key('message-editor')), findsOneWidget);

      await state.deleteMessage(state.active.id, 1);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('message-editor')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching chats closes the editor', (tester) async {
      final state = await boot();
      await tester.pumpWidget(chat(state));
      await tester.pumpAndSettle();

      await startEditing(tester);
      state.newConversation();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('message-editor')), findsNothing);
    });
  });
}
