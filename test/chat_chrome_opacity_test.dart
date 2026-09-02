import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/screens/settings/chat_interface/layout_page.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The two buttons that float over a conversation: the menu **soft square** at
/// the top-left and the jump-to-latest arrow at the bottom-right. Both are half
/// visible by default and both take their opacity from the chat's interface
/// settings — which means the app-wide value *and* a per-chat override have to
/// reach them, and the arrow's own show/hide fade must still win over the
/// setting when it is hidden.
///
/// The matrix driven below: {menu, jump} × {default, app-wide, per-chat} ×
/// {shown, hidden} for the arrow, plus the model's storage and the sliders.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('the model', () {
    test('both buttons start half visible', () {
      const ui = ChatInterface();
      expect(ui.menuButtonOpacity, kDefaultChromeOpacity);
      expect(ui.jumpButtonOpacity, kDefaultChromeOpacity);
      expect(kDefaultChromeOpacity, 0.5);
    });

    test('each opacity survives a round trip', () {
      const ui = ChatInterface(menuButtonOpacity: 0.2, jumpButtonOpacity: 0.9);
      final back = ChatInterface.fromJson(ui.toJson());
      expect(back.menuButtonOpacity, 0.2);
      expect(back.jumpButtonOpacity, 0.9);
      expect(back, ui);
    });

    test('a config saved before the setting existed defaults to half', () {
      final json = const ChatInterface().toJson()
        ..remove('menuButtonOpacity')
        ..remove('jumpButtonOpacity');
      final back = ChatInterface.fromJson(json);
      expect(back.menuButtonOpacity, kDefaultChromeOpacity);
      expect(back.jumpButtonOpacity, kDefaultChromeOpacity);
    });

    test('a stored value out of range is clamped, never invisible', () {
      final low = ChatInterface.fromJson({
        'menuButtonOpacity': 0.0,
        'jumpButtonOpacity': -3,
      });
      expect(low.menuButtonOpacity, kMinChromeOpacity);
      expect(low.jumpButtonOpacity, kMinChromeOpacity);

      final high = ChatInterface.fromJson({
        'menuButtonOpacity': 4,
        'jumpButtonOpacity': 1.5,
      });
      expect(high.menuButtonOpacity, kMaxChromeOpacity);
      expect(high.jumpButtonOpacity, kMaxChromeOpacity);
    });

    test('the two are told apart by equality', () {
      const ui = ChatInterface();
      expect(ui.copyWith(menuButtonOpacity: 0.3) == ui, isFalse);
      expect(ui.copyWith(jumpButtonOpacity: 0.3) == ui, isFalse);
      expect(
        ui.copyWith(menuButtonOpacity: 0.3).hashCode == ui.hashCode,
        isFalse,
      );
      // Changing one leaves the other alone.
      expect(ui.copyWith(menuButtonOpacity: 0.3).jumpButtonOpacity,
          kDefaultChromeOpacity);
      expect(ui.copyWith(jumpButtonOpacity: 0.3).menuButtonOpacity,
          kDefaultChromeOpacity);
    });
  });

  group('the chat screen', () {
    /// A chat with enough turns to scroll back through, so the arrow has a
    /// reason to appear.
    Future<AppState> chat({int turns = 80}) async {
      final state = AppState();
      // The chat screen holds a startup gate until the store has been read.
      await state.init();
      final character = Character.empty()
        ..name = 'Aria'
        ..firstMes = 'Evening.';
      await state.addCharacter(character);
      state.startChatWithCharacter(character);
      for (var i = 0; i < turns; i++) {
        state.active.messages.add(
          ChatMessage(
            role: i.isEven ? 'user' : 'assistant',
            content: 'Message number $i in a long conversation.',
          ),
        );
      }
      return state;
    }

    Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: ChatScreen()),
        );

    Future<void> open(WidgetTester tester, AppState state) async {
      await tester.pumpWidget(host(state));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }

    /// The painted surface of the menu button.
    Material menu(WidgetTester tester) =>
        tester.widget<Material>(find.byKey(chatMenuButtonKey));

    /// The fade the arrow is shown through — its target opacity.
    double arrowOpacity(WidgetTester tester) =>
        tester.widget<AnimatedOpacity>(find.byKey(jumpToLatestKey)).opacity;

    ScrollPosition scroll(WidgetTester tester) => tester
        .widget<ListView>(find.byType(ListView).first)
        .controller!
        .position;

    testWidgets('the menu button is a soft square, not a circle',
        (tester) async {
      await open(tester, await chat());

      final shape = menu(tester).shape;
      expect(shape, isA<RoundedRectangleBorder>(),
          reason: 'the menu button is now a soft square');
      final radius = (shape! as RoundedRectangleBorder).borderRadius
          .resolve(TextDirection.ltr)
          .topLeft
          .x;
      expect(radius, greaterThan(4),
          reason: 'soft: the corners are rounded, not a box');
      expect(radius, lessThan(24),
          reason: 'square: not so round it reads as a circle again');
    });

    testWidgets('both float at half opacity out of the box', (tester) async {
      await open(tester, await chat());

      expect(menu(tester).color!.a,
          moreOrLessEquals(kDefaultChromeOpacity, epsilon: 0.001));
      final icon = tester.widget<Icon>(find.byIcon(Icons.menu));
      expect(icon.color!.a,
          moreOrLessEquals(kDefaultChromeOpacity, epsilon: 0.001),
          reason: 'the whole button fades, icon included');

      // Nothing to jump to yet, so the arrow is faded out entirely.
      expect(arrowOpacity(tester), 0);

      scroll(tester).jumpTo(1000);
      await tester.pump();
      expect(arrowOpacity(tester),
          moreOrLessEquals(kDefaultChromeOpacity, epsilon: 0.001));
    });

    testWidgets('the app-wide setting reaches both buttons', (tester) async {
      final state = await chat();
      await state.updateChatInterface(state.chatInterface
          .copyWith(menuButtonOpacity: 0.25, jumpButtonOpacity: 0.8));

      await open(tester, state);

      expect(menu(tester).color!.a, moreOrLessEquals(0.25, epsilon: 0.001));
      scroll(tester).jumpTo(1000);
      await tester.pump();
      expect(arrowOpacity(tester), moreOrLessEquals(0.8, epsilon: 0.001));
    });

    testWidgets('a chat with its own style is drawn with its own opacity',
        (tester) async {
      final state = await chat();
      await state.updateChatInterface(state.chatInterface
          .copyWith(menuButtonOpacity: 1, jumpButtonOpacity: 1));
      await state.saveChatInterfaceOverride(
        state.active.id,
        state.chatInterface
            .copyWith(menuButtonOpacity: 0.15, jumpButtonOpacity: 0.35),
      );

      await open(tester, state);

      expect(menu(tester).color!.a, moreOrLessEquals(0.15, epsilon: 0.001),
          reason: 'the per-chat override wins over the app-wide value');
      scroll(tester).jumpTo(1000);
      await tester.pump();
      expect(arrowOpacity(tester), moreOrLessEquals(0.35, epsilon: 0.001));
    });

    testWidgets('a fully opaque setting still paints a solid button',
        (tester) async {
      final state = await chat();
      await state.updateChatInterface(state.chatInterface
          .copyWith(menuButtonOpacity: 1, jumpButtonOpacity: 1));

      await open(tester, state);

      expect(menu(tester).color!.a, 1);
      scroll(tester).jumpTo(1000);
      await tester.pump();
      expect(arrowOpacity(tester), 1);
    });

    testWidgets('a hidden arrow is hidden however visible it is set to be',
        (tester) async {
      final state = await chat();
      await state.updateChatInterface(
        state.chatInterface.copyWith(jumpButtonOpacity: 1),
      );

      await open(tester, state);

      // At the newest turn there is nothing to jump to: the setting must not
      // leave a solid button parked over the last message.
      expect(arrowOpacity(tester), 0);
      expect(
        tester
            .widget<IgnorePointer>(find
                .ancestor(
                  of: find.byKey(jumpToLatestKey),
                  matching: find.byType(IgnorePointer),
                )
                .first)
            .ignoring,
        isTrue,
      );

      // Scrolled back it comes in, and tapping it takes the fade away again.
      scroll(tester).jumpTo(1000);
      await tester.pump();
      expect(arrowOpacity(tester), 1);
      await tester.tap(find.byIcon(Icons.arrow_downward));
      await tester.pumpAndSettle();
      expect(arrowOpacity(tester), 0);
    });

    testWidgets('the menu button still opens the drawer at low opacity',
        (tester) async {
      final state = await chat();
      await state.updateChatInterface(
        state.chatInterface.copyWith(menuButtonOpacity: kMinChromeOpacity),
      );

      await open(tester, state);
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();

      expect(find.byType(Drawer), findsOneWidget,
          reason: 'a faint button is still a button');
    });
  });

  group('the settings page', () {
    // The two sliders live on the Layout spoke now: what they control is the
    // layout of a chat, and there were never enough of them to be a section.
    Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: LayoutSpokePage()),
        );

    testWidgets('offers a slider per button, showing its percentage',
        (tester) async {
      final state = AppState();
      await state.init();
      await tester.pumpWidget(host(state));
      await tester.pumpAndSettle();

      final menuRow = find.text('Menu button opacity');
      await tester.scrollUntilVisible(menuRow, 120,
          scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(menuRow);
      await tester.pumpAndSettle();

      expect(menuRow, findsOneWidget);
      expect(find.text('Looks button opacity'), findsOneWidget);
      expect(find.text('Jump-to-latest opacity'), findsOneWidget);
      expect(find.text('50%'), findsNWidgets(3),
          reason: 'all three read out their own current value');

      // Drag the menu slider to its floor and the setting follows.
      final slider = find
          .ancestor(of: menuRow, matching: find.byType(Column))
          .first;
      await tester.drag(
        find.descendant(of: slider, matching: find.byType(Slider)).first,
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();

      expect(state.chatInterface.menuButtonOpacity, kMinChromeOpacity);
      expect(state.chatInterface.jumpButtonOpacity, kDefaultChromeOpacity,
          reason: 'one slider must not move the other buttons');
      expect(state.chatInterface.looksButtonOpacity, kDefaultChromeOpacity);
      expect(find.text('${(kMinChromeOpacity * 100).round()}%'), findsOneWidget);
    });
  });
}
