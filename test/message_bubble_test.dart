import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/widgets/message_bubble.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 400, height: 800, child: child),
        ),
      );

  /// A host with no scrollable in it, mirroring the settings preview: a
  /// scrollable would take any mostly-vertical drag off the handles for itself,
  /// which is why the real preview does not scroll either.
  Widget dragHost(List<Widget> children) => host(
        Column(mainAxisSize: MainAxisSize.min, children: children),
      );

  // Every placement × bubble mode should lay out without throwing (guards the
  // Row/Column/WidgetSpan layout and the flat-vs-bubble branches).
  for (final placement in TextPlacement.values) {
    for (final bubbles in [true, false]) {
      testWidgets('renders ${placement.name} placement, bubbles=$bubbles',
          (tester) async {
        await tester.pumpWidget(host(
          ListView(
            children: [
              MessageBubble(
                message: ChatMessage(role: 'assistant', content: 'Hello there'),
                ui: ChatInterface(textPlacement: placement, bubbles: bubbles),
              ),
              MessageBubble(
                message: ChatMessage(role: 'user', content: 'Hi back'),
                ui: ChatInterface(textPlacement: placement, bubbles: bubbles),
              ),
            ],
          ),
        ));
        expect(tester.takeException(), isNull);
        expect(find.byType(MessageBubble), findsNWidgets(2));
      });
    }
  }

  // Names stacked with the avatar (above/below) must lay out in every
  // placement, both with the avatar shown and hidden.
  for (final position in NamePosition.values) {
    for (final show in [true, false]) {
      testWidgets('renders name ${position.name}, avatar=$show',
          (tester) async {
        await tester.pumpWidget(host(
          ListView(
            children: [
              for (final placement in TextPlacement.values)
                MessageBubble(
                  message: ChatMessage(role: 'assistant', content: 'Hi'),
                  ui: ChatInterface(
                    textPlacement: placement,
                    showNames: true,
                    botNameStyle: NameStyle(position: position),
                    botAvatar: AvatarStyle(show: show, side: ChatSide.left),
                  ),
                ),
            ],
          ),
        ));
        expect(tester.takeException(), isNull);
        // A "below" label with an avatar to hang under keeps an invisible
        // placeholder for its slot, so the count is per-turn, not per-label.
        expect(find.byType(MessageBubble),
            findsNWidgets(TextPlacement.values.length));
        expect(find.text('Assistant'), findsWidgets);
      });
    }
  }

  testWidgets('interactive avatar reports drag and resize deltas',
      (tester) async {
    Offset? drag;
    double? resize;
    await tester.pumpWidget(dragHost([
      MessageBubble(
        message: ChatMessage(role: 'assistant', content: 'Drag me'),
        ui: const ChatInterface(
          botAvatar: AvatarStyle(size: 60, side: ChatSide.left),
        ),
        interactive: true,
        onAvatarDrag: (d) => drag = d,
        onAvatarResize: (d) => resize = d,
      ),
    ]));

    // Dragging the avatar body reports a movement delta — downwards too, which
    // is the direction a scrollable would otherwise have stolen.
    await tester.drag(
      find.byIcon(Icons.smart_toy_outlined),
      const Offset(6, 40),
    );
    await tester.pump();
    expect(drag, isNotNull);
    expect(drag!.dy, greaterThan(0));

    // Dragging the corner handle reports a resize delta.
    await tester.drag(find.byIcon(Icons.open_in_full), const Offset(24, 24));
    await tester.pump();
    expect(resize, isNotNull);
  });

  group('message action bar', () {
    Widget bubble({
      required bool isUser,
      void Function(MessageAction)? onAction,
      bool streaming = false,
      ChatInterface? ui,
    }) =>
        host(ListView(children: [
          MessageBubble(
            message: ChatMessage(
                role: isUser ? 'user' : 'assistant', content: 'Hi'),
            ui: ui ?? const ChatInterface(),
            onAction: onAction,
            streaming: streaming,
          ),
        ]));

    testWidgets('renders the configured inline actions for a bot turn',
        (tester) async {
      MessageAction? got;
      await tester.pumpWidget(bubble(isUser: false, onAction: (a) => got = a));
      expect(find.byIcon(Icons.refresh), findsOneWidget); // regenerate
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsOneWidget); // overflow

      await tester.tap(find.byIcon(Icons.refresh));
      expect(got, MessageAction.regenerate);
    });

    testWidgets('hides regenerate on a user turn', (tester) async {
      await tester.pumpWidget(bubble(isUser: true, onAction: (_) {}));
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets('overflow menu exposes the menu actions', (tester) async {
      MessageAction? got;
      await tester.pumpWidget(bubble(isUser: false, onAction: (a) => got = a));
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Fork'), findsOneWidget);
      expect(find.text('View prompt'), findsOneWidget);
      expect(find.text('Info'), findsOneWidget);

      await tester.tap(find.text('View prompt'));
      await tester.pumpAndSettle();
      expect(got, MessageAction.prompt);
    });

    testWidgets('mutating actions are disabled while streaming',
        (tester) async {
      await tester.pumpWidget(
          bubble(isUser: false, onAction: (_) {}, streaming: true));
      final regen = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.refresh),
          matching: find.byType(IconButton),
        ),
      );
      expect(regen.onPressed, isNull);
    });

    testWidgets('no bar without a dispatcher or when disabled', (tester) async {
      await tester.pumpWidget(bubble(isUser: false)); // onAction null
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.byIcon(Icons.more_vert), findsNothing);

      await tester.pumpWidget(bubble(
        isUser: false,
        onAction: (_) {},
        ui: const ChatInterface(messageActionsEnabled: false),
      ));
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });
  });

  // Every content width should lay out (esp. document mode / full) without
  // throwing.
  for (final width in ContentWidth.values) {
    for (final bubbles in [true, false]) {
      testWidgets('content width ${width.name}, bubbles=$bubbles',
          (tester) async {
        await tester.pumpWidget(host(
          ListView(children: [
            MessageBubble(
              message:
                  ChatMessage(role: 'assistant', content: 'A longer line of text.'),
              ui: ChatInterface(contentWidth: width, bubbles: bubbles),
            ),
          ]),
        ));
        expect(tester.takeException(), isNull);
        expect(find.byType(MessageBubble), findsOneWidget);
      });
    }
  }

  // Every action-bar placement should lay out without throwing and still show
  // the configured inline actions (regenerate icon present for a bot turn).
  for (final placement in ActionBarPlacement.values) {
    for (final showNames in [true, false]) {
      testWidgets('action placement ${placement.name}, names=$showNames',
          (tester) async {
        await tester.pumpWidget(host(
          ListView(children: [
            MessageBubble(
              message: ChatMessage(role: 'assistant', content: 'A reply.'),
              ui: ChatInterface(
                actionBarPlacement: placement,
                showNames: showNames,
              ),
              onAction: (_) {},
            ),
          ]),
        ));
        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.refresh), findsOneWidget);
        expect(find.byIcon(Icons.more_vert), findsOneWidget);
      });
    }
  }

  group('sender name label', () {
    testWidgets('honours its role size and nudge', (tester) async {
      Future<Offset> topLeftFor(NameStyle style) async {
        await tester.pumpWidget(host(
          ListView(children: [
            MessageBubble(
              message: ChatMessage(role: 'assistant', content: 'Hi'),
              ui: ChatInterface(showNames: true, botNameStyle: style),
            ),
          ]),
        ));
        // A nudged label keeps an invisible placeholder in its old slot; the
        // drawn one is the later of the two.
        return tester.getTopLeft(find.text('Assistant').last);
      }

      final plain = await topLeftFor(const NameStyle(size: 19));
      expect(tester.widget<Text>(find.text('Assistant').last).style?.fontSize,
          19);

      // The nudge moves where the label is actually drawn.
      final nudged =
          await topLeftFor(const NameStyle(size: 19, offsetX: 3, offsetY: 7));
      expect(nudged.dx - plain.dx, closeTo(3, 0.5));
      expect(nudged.dy - plain.dy, closeTo(7, 0.5));
    });

    testWidgets('each role keeps its own label style', (tester) async {
      const ui = ChatInterface(
        showNames: true,
        botNameStyle: NameStyle(size: 20),
        userNameStyle: NameStyle(size: 9),
      );
      await tester.pumpWidget(host(
        ListView(children: [
          MessageBubble(
            message: ChatMessage(role: 'assistant', content: 'Hi'),
            ui: ui,
          ),
          MessageBubble(
            message: ChatMessage(role: 'user', content: 'Hello'),
            ui: ui,
          ),
        ]),
      ));

      expect(tester.widget<Text>(find.text('Assistant')).style?.fontSize, 20);
      expect(tester.widget<Text>(find.text('You')).style?.fontSize, 9);
    });

    testWidgets('is draggable in the preview and reports the delta',
        (tester) async {
      Offset? moved;
      await tester.pumpWidget(dragHost([
        MessageBubble(
          message: ChatMessage(role: 'assistant', content: 'Hi'),
          ui: const ChatInterface(showNames: true),
          interactive: true,
          onNameDrag: (d) => moved = d,
        ),
      ]));

      // Past the pan slop, so the gesture is actually recognised.
      await tester.drag(find.text('Assistant'), const Offset(6, 40));
      await tester.pump();
      expect(moved, isNotNull);
      expect(moved!.dy, greaterThan(0));
    });

    testWidgets('carries its own colour', (tester) async {
      await tester.pumpWidget(host(
        ListView(children: [
          MessageBubble(
            message: ChatMessage(role: 'assistant', content: 'Hi'),
            ui: const ChatInterface(
              showNames: true,
              botNameStyle: NameStyle(color: 0xFF9911EE),
            ),
          ),
        ]),
      ));
      expect(tester.widget<Text>(find.text('Assistant')).style?.color,
          const Color(0xFF9911EE));
    });

    testWidgets('a headline-sized name renders', (tester) async {
      await tester.pumpWidget(host(
        ListView(children: [
          MessageBubble(
            message: ChatMessage(role: 'assistant', content: 'Hi'),
            ui: const ChatInterface(
              showNames: true,
              botNameStyle: NameStyle(size: kMaxNameSize),
            ),
          ),
        ]),
      ));
      expect(tester.takeException(), isNull);
      expect(tester.widget<Text>(find.text('Assistant')).style?.fontSize, 100);
    });

    testWidgets('aligns across the whole row, not just its own message',
        (tester) async {
      Future<double> centreX(NameAlign align) async {
        await tester.pumpWidget(host(
          ListView(children: [
            MessageBubble(
              message: ChatMessage(role: 'assistant', content: 'Hi'),
              ui: ChatInterface(
                showNames: true,
                botNameStyle: NameStyle(align: align),
              ),
            ),
          ]),
        ));
        return tester.getCenter(find.text('Assistant')).dx;
      }

      final left = await centreX(NameAlign.start);
      final centre = await centreX(NameAlign.center);
      final right = await centreX(NameAlign.end);

      // The host is 400 wide and the message is a short left-hand bubble, so a
      // centred name has to leave the bubble behind to reach mid-screen.
      expect(centre, closeTo(200, 6));
      expect(left, lessThan(centre));
      expect(right, greaterThan(300));
    });

    testWidgets('stays grabbable once nudged over its own message',
        (tester) async {
      var total = Offset.zero;
      Widget build(double offsetY) => dragHost([
            MessageBubble(
              message: ChatMessage(role: 'assistant', content: 'Hi'),
              ui: ChatInterface(
                showNames: true,
                botNameStyle: NameStyle(offsetY: offsetY),
              ),
              interactive: true,
              onNameDrag: (d) => total += d,
            ),
          ]);

      await tester.pumpWidget(build(0));
      await tester.drag(find.text('Assistant'), const Offset(0, 40));
      await tester.pump();
      final first = total.dy;
      expect(first, greaterThan(0));

      // The label now sits over the bubble. It must still win the hit test —
      // otherwise a name could be dragged down once and never moved again.
      await tester.pumpWidget(build(40));
      await tester.drag(find.text('Assistant').last, const Offset(0, 30));
      await tester.pump();
      expect(total.dy, greaterThan(first));
    });

    testWidgets('"below" means below the avatar, not below the whole message',
        (tester) async {
      await tester.pumpWidget(host(
        ListView(children: [
          MessageBubble(
            message: ChatMessage(
                role: 'assistant',
                content: 'A reply long enough to run to several lines in this '
                    'narrow host, so its bubble is clearly taller than the '
                    'avatar beside it.'),
            ui: const ChatInterface(
              showNames: true,
              botNameStyle: NameStyle(position: NamePosition.below),
              botAvatar: AvatarStyle(size: 48, side: ChatSide.left),
            ),
          ),
        ]),
      ));

      final avatar = tester.getRect(find.byIcon(Icons.smart_toy_outlined));
      final label = tester.getRect(find.text('Assistant').last);
      // Directly under the avatar — and well above the bottom of the much
      // taller bubble it sits beside.
      expect(label.top, greaterThanOrEqualTo(avatar.bottom - 1));
      final bubble = tester.getRect(find.byType(MessageBubble));
      expect(label.bottom, lessThan(bubble.bottom));
    });

    testWidgets('"below" falls back under the message with no avatar to hang on',
        (tester) async {
      await tester.pumpWidget(host(
        ListView(children: [
          MessageBubble(
            message: ChatMessage(role: 'assistant', content: 'Short'),
            ui: const ChatInterface(
              showNames: true,
              botNameStyle: NameStyle(position: NamePosition.below),
              botAvatar: AvatarStyle(show: false, side: ChatSide.left),
            ),
          ),
        ]),
      ));

      expect(tester.takeException(), isNull);
      final text = tester.getRect(find.text('Short'));
      final label = tester.getRect(find.text('Assistant'));
      expect(label.top, greaterThan(text.top));
    });

    testWidgets('a below-the-avatar label still aligns across the screen',
        (tester) async {
      await tester.pumpWidget(host(
        ListView(children: [
          MessageBubble(
            message: ChatMessage(role: 'assistant', content: 'Hi'),
            ui: const ChatInterface(
              showNames: true,
              botNameStyle: NameStyle(
                position: NamePosition.below,
                align: NameAlign.end,
              ),
              botAvatar: AvatarStyle(size: 48, side: ChatSide.left),
            ),
          ),
        ]),
      ));

      // Right-aligned against the row, even though the avatar it hangs under is
      // on the far left.
      expect(tester.getCenter(find.text('Assistant').last).dx,
          greaterThan(300));
    });

    testWidgets('is not a drag target in the chat itself', (tester) async {
      await tester.pumpWidget(host(
        ListView(children: [
          MessageBubble(
            message: ChatMessage(role: 'assistant', content: 'Hi'),
            ui: const ChatInterface(showNames: true),
          ),
        ]),
      ));
      // No grab frame around the label when it isn't interactive.
      expect(
        find.ancestor(
          of: find.text('Assistant'),
          matching: find.byWidgetPredicate(
              (w) => w is Container && w.decoration is BoxDecoration),
        ),
        findsNothing,
      );
    });
  });

  group('a "below" name goes under the avatar, in every layout', () {
    const long = 'A reply long enough to wrap onto several lines in this narrow '
        'host, so its bubble ends up much taller than the avatar it sits with.';

    Future<void> pump(
      WidgetTester tester, {
      required TextPlacement placement,
      ActionBarPlacement bar = ActionBarPlacement.belowMessage,
      bool actions = false,
      bool showAvatar = true,
    }) =>
        tester.pumpWidget(host(
          ListView(children: [
            MessageBubble(
              message: ChatMessage(role: 'assistant', content: long),
              ui: ChatInterface(
                showNames: true,
                textPlacement: placement,
                botNameStyle: const NameStyle(position: NamePosition.below),
                botAvatar:
                    AvatarStyle(show: showAvatar, size: 48, side: ChatSide.left),
                actionBarPlacement: bar,
                messageActionsEnabled: actions,
              ),
              onAction: actions ? (_) {} : null,
            ),
          ]),
        ));

    Rect avatarRect(WidgetTester tester) =>
        tester.getRect(find.byIcon(Icons.smart_toy_outlined));
    Rect labelRect(WidgetTester tester) =>
        tester.getRect(find.text('Assistant').last);

    // The two layouts that actually have an avatar with a bottom edge to hang
    // from: text beside it, and text under it.
    for (final placement in [TextPlacement.beside, TextPlacement.below]) {
      testWidgets('text ${placement.name}: under the avatar, not the message',
          (tester) async {
        await pump(tester, placement: placement);
        final avatar = avatarRect(tester);
        final label = labelRect(tester);
        final turn = tester.getRect(find.byType(MessageBubble));

        expect(label.top, greaterThanOrEqualTo(avatar.bottom - 1),
            reason: 'below the avatar');
        // And nowhere near the foot of a bubble far taller than the avatar —
        // which is what "below the whole message" would look like.
        expect(label.bottom, lessThan(turn.bottom - 20));
      });
    }

    // The action bar must not change where the name lands, wherever it sits.
    for (final bar in ActionBarPlacement.values) {
      testWidgets('actions ${bar.name}: still under the avatar', (tester) async {
        await pump(tester,
            placement: TextPlacement.beside, bar: bar, actions: true);
        final avatar = avatarRect(tester);
        final label = labelRect(tester);
        expect(label.top, greaterThanOrEqualTo(avatar.bottom - 1));
        if (bar == ActionBarPlacement.besideAvatar) {
          // The bar is hanging under the avatar, so the name clears it.
          expect(label.top, greaterThan(avatar.bottom + 20));
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('an inline avatar (around) has no bottom edge, so it falls back',
        (tester) async {
      await pump(tester, placement: TextPlacement.around);
      expect(tester.takeException(), isNull);
      final turn = tester.getRect(find.byType(MessageBubble));
      final label = labelRect(tester);
      // Under the message, which is the honest answer when the avatar is inline
      // in the text itself.
      expect(label.bottom, closeTo(turn.bottom, 8));
    });

    testWidgets('no avatar at all falls back under the message',
        (tester) async {
      await pump(tester, placement: TextPlacement.beside, showAvatar: false);
      expect(tester.takeException(), isNull);
      final turn = tester.getRect(find.byType(MessageBubble));
      expect(labelRect(tester).bottom, closeTo(turn.bottom, 8));
    });
  });

  group('message spacing', () {
    Future<Iterable<EdgeInsets>> margins(
        WidgetTester tester, ChatInterface ui) async {
      await tester.pumpWidget(host(
        ListView(children: [
          MessageBubble(
            message: ChatMessage(role: 'assistant', content: 'Hi'),
            ui: ui,
          ),
        ]),
      ));
      return tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.margin)
          .whereType<EdgeInsets>();
    }

    testWidgets('splits the configured gap above and below a turn',
        (tester) async {
      final found =
          await margins(tester, const ChatInterface(messageSpacing: 22));
      expect(found.any((m) => m.top == 11 && m.bottom == 11), isTrue);
    });

    testWidgets('the default leaves a clear break between turns',
        (tester) async {
      final found = await margins(tester, const ChatInterface());
      expect(
        found.any((m) =>
            m.top == kDefaultMessageSpacing / 2 &&
            m.bottom == kDefaultMessageSpacing / 2),
        isTrue,
      );
    });

    testWidgets('zero spacing is allowed', (tester) async {
      final found =
          await margins(tester, const ChatInterface(messageSpacing: 0));
      expect(found.any((m) => m.top == 0 && m.bottom == 0), isTrue);
    });
  });

  // Every rounding level should clip without throwing, at a tiny and a large
  // avatar alike.
  testWidgets('every corner rounding level lays out', (tester) async {
    for (final rounding in CornerRounding.values) {
      await tester.pumpWidget(host(
        ListView(children: [
          for (final size in [24.0, 120.0])
            MessageBubble(
              message: ChatMessage(role: 'assistant', content: 'Hi'),
              ui: ChatInterface(
                botAvatar: AvatarStyle(
                  size: size,
                  shape: AvatarShape.rounded,
                  corner: rounding,
                ),
              ),
            ),
        ]),
      ));
      expect(tester.takeException(), isNull);
    }
  });
}
