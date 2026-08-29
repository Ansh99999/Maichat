import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';

void main() {
  test('defaults survive a JSON round trip', () {
    final restored = ChatInterface.fromJson(const ChatInterface().toJson());
    expect(restored, const ChatInterface());
    // Defaults put the bot on the left and the user on the right.
    expect(restored.botAvatar.side, ChatSide.left);
    expect(restored.userAvatar.side, ChatSide.right);
  });

  test('a fully customised config round trips, per-role and colours', () {
    const original = ChatInterface(
      botAvatar: AvatarStyle(
        show: true,
        size: 96,
        shape: AvatarShape.rounded,
        fit: AvatarFit.free,
        side: ChatSide.left,
        offsetX: 10,
        offsetY: -4,
      ),
      userAvatar: AvatarStyle(
        show: false,
        size: 40,
        shape: AvatarShape.square,
        fit: AvatarFit.contain,
        side: ChatSide.left,
      ),
      syncAvatars: false,
      textPlacement: TextPlacement.around,
      bubbles: false,
      fontSize: 20,
      bubbleOpacity: 0.5,
      showNames: true,
      userName: 'Ansh',
      markdown: false,
      userTextColor: 0xFF112233,
      botBubbleColor: 0xFFAABBCC,
      backgroundColor: 0xFF010203,
      emphasisColor: 0xFF00FF00,
      quoteColor: 0xFF123456,
    );

    final restored = ChatInterface.fromJson(original.toJson());

    expect(restored, original);
    expect(restored.botAvatar.fit, AvatarFit.free);
    expect(restored.userAvatar.side, ChatSide.left);
    expect(restored.userName, 'Ansh');
    expect(restored.markdown, isFalse);
    expect(restored.emphasisColor, 0xFF00FF00);
    expect(restored.quoteColor, 0xFF123456);
    expect(restored.botAvatar.offset.dx, 10);
  });

  test('name typography + alignment round trip', () {
    const original = ChatInterface(
      showNames: true,
      syncNames: true,
      botNameStyle: NameStyle(
        size: 18,
        align: NameAlign.center,
        position: NamePosition.below,
        fontFamily: 'Roboto Slab',
        offsetX: 6,
        offsetY: -12,
      ),
      userNameStyle: NameStyle(size: 9, align: NameAlign.end),
    );
    final restored = ChatInterface.fromJson(original.toJson());
    expect(restored, original);
    expect(restored.botNameStyle.size, 18);
    expect(restored.userNameStyle.size, 9);
    expect(restored.botNameStyle.align, NameAlign.center);
    expect(restored.userNameStyle.align, NameAlign.end);
    expect(restored.botNameStyle.position, NamePosition.below);
    expect(restored.userNameStyle.position, NamePosition.above);
    expect(restored.botNameStyle.fontFamily, 'Roboto Slab');
    expect(restored.botNameStyle.offset, const Offset(6, -12));
    expect(restored.syncNames, isTrue);
  });

  test('an unset name font is omitted from JSON and cleared via the sentinel',
      () {
    expect(const NameStyle().toJson().containsKey('fontFamily'), isFalse);
    const styled = NameStyle(fontFamily: 'Inter');
    expect(styled.copyWith().fontFamily, 'Inter');
    expect(styled.copyWith(fontFamily: null).fontFamily, isNull);
    expect(styled.copyWith(size: 20).fontFamily, 'Inter');
  });

  test('nameFor picks the right role and isNudged tracks the offset', () {
    const ui = ChatInterface(
      botNameStyle: NameStyle(size: 15),
      userNameStyle: NameStyle(size: 21, offsetY: 4),
    );
    expect(ui.nameFor(false).size, 15);
    expect(ui.nameFor(true).size, 21);
    expect(ui.nameFor(false).isNudged, isFalse);
    expect(ui.nameFor(true).isNudged, isTrue);
  });

  test('withName respects the sync flag', () {
    const independent = ChatInterface(syncNames: false);
    final one = independent.withName(
        false, independent.botNameStyle.copyWith(size: 20));
    expect(one.botNameStyle.size, 20);
    expect(one.userNameStyle.size, 12);

    const synced = ChatInterface(syncNames: true);
    final both =
        synced.withName(true, synced.userNameStyle.copyWith(fontFamily: 'Lato'));
    expect(both.userNameStyle.fontFamily, 'Lato');
    expect(both.botNameStyle.fontFamily, 'Lato');
  });

  test('the pre-nested flat name keys migrate onto both styles', () {
    final legacy = {
      'showNames': true,
      'botNameSize': 17.0,
      'botNameAlign': 'center',
      'botNamePosition': 'below',
      'userNameSize': 10.0,
      'userNameAlign': 'end',
    };

    final migrated = ChatInterface.fromJson(legacy);

    expect(migrated.botNameStyle.size, 17);
    expect(migrated.botNameStyle.align, NameAlign.center);
    expect(migrated.botNameStyle.position, NamePosition.below);
    expect(migrated.userNameStyle.size, 10);
    expect(migrated.userNameStyle.align, NameAlign.end);
    expect(migrated.userNameStyle.position, NamePosition.above);
    // Nothing was stored for the new fields, so they take their defaults.
    expect(migrated.botNameStyle.fontFamily, isNull);
    expect(migrated.botNameStyle.isNudged, isFalse);
    expect(migrated.syncNames, isFalse);
  });

  test('name defaults fall back sensibly', () {
    const ui = ChatInterface();
    expect(ui.botNameStyle, const NameStyle());
    // Each name starts over its own side of the thread: bot left, user right.
    expect(ui.userNameStyle, const NameStyle(align: NameAlign.end));
    expect(ui.botNameStyle.size, 12);
    expect(ui.botNameStyle.align, NameAlign.start);
    expect(ui.botNameStyle.position, NamePosition.above);
    expect(ui.botNameStyle.fontFamily, isNull);
    expect(ui.botNameStyle.color, isNull);
    expect(NameAlign.byName('nonsense'), NameAlign.start);
    expect(NameAlign.byName('center'), NameAlign.center);
    expect(NameAlign.center.textAlign, TextAlign.center);
    expect(NamePosition.byName('nonsense'), NamePosition.above);
    expect(NamePosition.byName('below'), NamePosition.below);
  });

  test('alignment maps onto the full-width band, screen-relative', () {
    // Left/Center/Right, not "wherever the bubble happens to end".
    expect(NameAlign.start.label, 'Left');
    expect(NameAlign.center.label, 'Center');
    expect(NameAlign.end.label, 'Right');
    expect(NameAlign.start.alignment, Alignment.centerLeft);
    expect(NameAlign.center.alignment, Alignment.center);
    expect(NameAlign.end.alignment, Alignment.centerRight);
  });

  test('a name colour round trips, is omitted when unset, and clears', () {
    expect(const NameStyle().toJson().containsKey('color'), isFalse);

    const original = ChatInterface(
      botNameStyle: NameStyle(color: 0xFF9911EE),
      userNameStyle: NameStyle(align: NameAlign.end, color: 0xFF00CCAA),
    );
    final restored = ChatInterface.fromJson(original.toJson());
    expect(restored, original);
    expect(restored.botNameStyle.color, 0xFF9911EE);
    expect(restored.userNameStyle.color, 0xFF00CCAA);

    const coloured = NameStyle(color: 0xFF123456);
    expect(coloured.copyWith().color, 0xFF123456);
    expect(coloured.copyWith(size: 30).color, 0xFF123456);
    expect(coloured.copyWith(color: null).color, isNull);
  });

  test('a name can be as large as a headline', () {
    expect(kMaxNameSize, 100);
    const big = ChatInterface(botNameStyle: NameStyle(size: 96));
    expect(ChatInterface.fromJson(big.toJson()).botNameStyle.size, 96);
  });

  group('avatar corner rounding', () {
    test('a level scales with the frame and round trips', () {
      const original = ChatInterface(
        botAvatar: AvatarStyle(shape: AvatarShape.rounded, corner: CornerRounding.xs),
        userAvatar: AvatarStyle(shape: AvatarShape.rounded, corner: CornerRounding.xxl),
      );
      final restored = ChatInterface.fromJson(original.toJson());
      expect(restored, original);
      expect(restored.botAvatar.corner, CornerRounding.xs);
      expect(restored.userAvatar.corner, CornerRounding.xxl);

      // The radius is a fraction of the short side, so a level looks the same
      // at any size.
      expect(restored.botAvatar.radiusFor(100), closeTo(7, 0.001));
      expect(restored.userAvatar.radiusFor(50), closeTo(16, 0.001));
    });

    test('circle and square ignore the level', () {
      const circle =
          AvatarStyle(shape: AvatarShape.circle, corner: CornerRounding.none);
      const square =
          AvatarStyle(shape: AvatarShape.square, corner: CornerRounding.xxl);
      expect(circle.radiusFor(64), 32);
      expect(square.radiusFor(64), 0);
      expect(circle.cornerLabel, 'Circle');
      expect(square.cornerLabel, 'Square');
    });

    test('the default is a restrained M, and junk falls back to it', () {
      const style = AvatarStyle(shape: AvatarShape.rounded);
      expect(style.corner, CornerRounding.m);
      expect(style.cornerLabel, 'Rounded · M');
      expect(CornerRounding.byName('nonsense'), CornerRounding.m);
      expect(CornerRounding.byName('xxs'), CornerRounding.xxs);
      // Softer than the single hardcoded "rounded" look it replaces (0.24).
      expect(style.radiusFor(100), lessThan(24));
      expect(CornerRounding.none.factor, 0);
      // The scale climbs monotonically from none to xxl.
      for (var i = 1; i < CornerRounding.values.length; i++) {
        expect(CornerRounding.values[i].factor,
            greaterThan(CornerRounding.values[i - 1].factor));
      }
    });
  });

  test('message spacing defaults, clamps into range and round trips', () {
    const ui = ChatInterface();
    expect(ui.messageSpacing, kDefaultMessageSpacing);
    // Wider than the 8 px gap it replaces, so two avatars never touch.
    expect(kDefaultMessageSpacing, greaterThan(8));

    const custom = ChatInterface(messageSpacing: 32);
    final restored = ChatInterface.fromJson(custom.toJson());
    expect(restored, custom);
    expect(restored.messageSpacing, 32);

    // A config saved before the setting existed reads as the default.
    expect(ChatInterface.fromJson(<String, dynamic>{}).messageSpacing,
        kDefaultMessageSpacing);
  });

  test('copyWith clears a colour to null (follow theme) via the sentinel', () {
    const withColour = ChatInterface(userTextColor: 0xFF112233);
    expect(withColour.copyWith().userTextColor, 0xFF112233);
    expect(withColour.copyWith(userTextColor: null).userTextColor, isNull);
    expect(withColour.copyWith(userTextColor: null).userName, 'You');
  });

  test('unset colours are omitted from JSON, not written as null', () {
    final json = const ChatInterface().toJson();
    expect(json.containsKey('userTextColor'), isFalse);
    expect(json.containsKey('backgroundColor'), isFalse);
  });

  test('enum byName falls back sensibly for junk', () {
    expect(AvatarShape.byName('nonsense'), AvatarShape.circle);
    expect(AvatarFit.byName(null), AvatarFit.cover);
    expect(TextPlacement.byName(''), TextPlacement.beside);
    expect(ChatSide.byName('x', fallback: ChatSide.right), ChatSide.right);
  });

  test('migrates the old single-avatar shape onto both roles', () {
    // The pre-split JSON had flat avatar fields and one offset.
    final legacy = {
      'showAvatars': true,
      'avatarSize': 72.0,
      'avatarShape': 'rounded',
      'avatarFit': 'contain',
      'textPlacement': 'below',
      'bubbles': false,
      'fontSize': 18.0,
      'avatarOffsetX': 5.0,
      'avatarOffsetY': 6.0,
      'userTextColor': 0xFF445566,
    };

    final migrated = ChatInterface.fromJson(legacy);

    // Both avatars pick up the old look; only the default side differs.
    expect(migrated.botAvatar.size, 72);
    expect(migrated.userAvatar.size, 72);
    expect(migrated.botAvatar.shape, AvatarShape.rounded);
    expect(migrated.userAvatar.fit, AvatarFit.contain);
    expect(migrated.botAvatar.side, ChatSide.left);
    expect(migrated.userAvatar.side, ChatSide.right);
    expect(migrated.bubbles, isFalse);
    expect(migrated.textPlacement, TextPlacement.below);
    expect(migrated.userTextColor, 0xFF445566);
  });

  test('withAvatar respects the sync flag', () {
    const base = ChatInterface(syncAvatars: false);

    // Unsynced: editing the bot leaves the user untouched.
    final unsynced = base.withAvatar(false, base.botAvatar.copyWith(size: 100));
    expect(unsynced.botAvatar.size, 100);
    expect(unsynced.userAvatar.size, 44);

    // Synced: the look mirrors to both, but each keeps its own side.
    const synced = ChatInterface(syncAvatars: true);
    final next =
        synced.withAvatar(false, synced.botAvatar.copyWith(size: 100));
    expect(next.botAvatar.size, 100);
    expect(next.userAvatar.size, 100);
    expect(next.botAvatar.side, ChatSide.left);
    expect(next.userAvatar.side, ChatSide.right);
  });

  group('message actions', () {
    test('defaults: regenerate/edit/delete inline, the rest in the menu', () {
      const ui = ChatInterface();
      expect(ui.messageActionsEnabled, isTrue);
      expect(ui.inlineActions,
          [MessageAction.regenerate, MessageAction.edit, MessageAction.delete]);
      expect(ui.overflowActions, [
        MessageAction.copy,
        MessageAction.fork,
        MessageAction.prompt,
        MessageAction.info,
        MessageAction.imagine,
      ]);
    });

    test('a customised placement round trips', () {
      final custom = const ChatInterface().copyWith(
        messageActionsEnabled: false,
        messageActions: const [
          MessageActionPref(MessageAction.prompt, inline: true),
          MessageActionPref(MessageAction.info, inline: true),
          MessageActionPref(MessageAction.regenerate),
          MessageActionPref(MessageAction.edit),
          MessageActionPref(MessageAction.delete),
          MessageActionPref(MessageAction.copy),
          MessageActionPref(MessageAction.fork),
          MessageActionPref(MessageAction.imagine),
        ],
      );
      final restored = ChatInterface.fromJson(custom.toJson());
      expect(restored, custom);
      expect(restored.messageActionsEnabled, isFalse);
      expect(restored.inlineActions,
          [MessageAction.prompt, MessageAction.info]);
    });

    test('absent config migrates to defaults', () {
      final restored = ChatInterface.fromJson(const {});
      expect(restored.messageActions, kDefaultMessageActions);
      expect(restored.messageActionsEnabled, isTrue);
    });

    test('an unknown action is dropped and a missing one appended as menu', () {
      final restored = ChatInterface.fromJson({
        'messageActions': [
          {'action': 'edit', 'inline': true},
          {'action': 'telepathy', 'inline': true}, // unknown → dropped
          {'action': 'delete', 'inline': false},
        ],
      });
      // Known ones kept in order…
      expect(restored.messageActions.first.action, MessageAction.edit);
      expect(restored.messageActions.first.inline, isTrue);
      // …unknown dropped…
      expect(restored.messageActions.length, MessageAction.values.length);
      // …and every action is present exactly once (missing ones appended).
      expect(
        restored.messageActions.map((p) => p.action).toSet(),
        MessageAction.values.toSet(),
      );
      // An appended (previously missing) action defaults to the overflow menu.
      final regen = restored.messageActions
          .firstWhere((p) => p.action == MessageAction.regenerate);
      expect(regen.inline, isFalse);
    });

    test('role gating: regenerate/prompt are assistant-only', () {
      expect(MessageAction.regenerate.appliesTo(true), isFalse); // user turn
      expect(MessageAction.regenerate.appliesTo(false), isTrue); // bot turn
      expect(MessageAction.prompt.appliesTo(true), isFalse);
      expect(MessageAction.edit.appliesTo(true), isTrue);
      expect(MessageAction.delete.appliesTo(true), isTrue);
    });

    test('action bar placement defaults to below and round trips', () {
      expect(const ChatInterface().actionBarPlacement,
          ActionBarPlacement.belowMessage);
      for (final p in ActionBarPlacement.values) {
        final custom = const ChatInterface().copyWith(actionBarPlacement: p);
        final restored = ChatInterface.fromJson(custom.toJson());
        expect(restored.actionBarPlacement, p);
        expect(restored, custom);
      }
    });
  });

  group('content width', () {
    test('defaults to medium and round trips', () {
      expect(const ChatInterface().contentWidth, ContentWidth.medium);
      final custom =
          const ChatInterface().copyWith(contentWidth: ContentWidth.full);
      final restored = ChatInterface.fromJson(custom.toJson());
      expect(restored.contentWidth, ContentWidth.full);
      expect(restored, custom);
    });

    test('maxWidthFor caps bounded modes and fills for full', () {
      // On a wide screen the bounded modes keep their readable caps…
      expect(ContentWidth.narrow.maxWidthFor(1200), 560);
      expect(ContentWidth.medium.maxWidthFor(1200), 720);
      expect(ContentWidth.full.maxWidthFor(1200), 1200 - 24);
      // …and on a narrow screen every mode is clamped to what's available.
      expect(ContentWidth.wide.maxWidthFor(360), 360 - 24);
    });
  });

  group('text wrapping rules', () {
    const angle = TextWrapRule(start: '<', end: '>', color: 0xFFFFCC00);

    test('none by default, and none written to JSON', () {
      expect(const ChatInterface().textWrapRules, isEmpty);
      expect(const ChatInterface().toJson().containsKey('textWrapRules'),
          isFalse);
    });

    test('rules round trip, in order', () {
      final custom = const ChatInterface().copyWith(textWrapRules: const [
        angle,
        TextWrapRule(start: '((', end: '))', hideMarkers: false),
      ]);
      final restored = ChatInterface.fromJson(custom.toJson());
      expect(restored, custom);
      expect(restored.textWrapRules.first.start, '<');
      expect(restored.textWrapRules.last.hideMarkers, isFalse);
    });

    test('a rule differing only in colour is a different config', () {
      final a = const ChatInterface().copyWith(textWrapRules: const [angle]);
      final b = const ChatInterface()
          .copyWith(textWrapRules: [angle.copyWith(color: 0xFF00FF00)]);
      expect(a, isNot(b));
      expect(a.hashCode, isNot(b.hashCode));
    });

    test('a stored rule with a missing marker is dropped, not fatal', () {
      final json = const ChatInterface().toJson()
        ..['textWrapRules'] = [
          {'start': '', 'end': '>'},
          {'start': '[', 'end': ']'},
        ];
      final restored = ChatInterface.fromJson(json);
      expect(restored.textWrapRules, hasLength(1));
      expect(restored.textWrapRules.single.start, '[');
    });

    test('activeTextWrapRules drops the disabled ones', () {
      final ui = const ChatInterface().copyWith(textWrapRules: [
        angle,
        angle.copyWith(start: '~', end: '~', enabled: false),
      ]);
      expect(ui.textWrapRules, hasLength(2));
      expect(ui.activeTextWrapRules, hasLength(1));
    });

    test('a colour clears back to "follows the text"', () {
      expect(angle.copyWith(color: null).color, isNull);
      // …and a copyWith that says nothing about the colour keeps it.
      expect(angle.copyWith(hideMarkers: false).color, 0xFFFFCC00);
    });
  });
}
