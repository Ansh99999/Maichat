// The screenshot generator. Run it with:
//
//   flutter test test/screenshots/generate.dart --update-goldens
//
// Each shot writes one file in docs/screenshots/, named for what the README
// expects. Replace any of those files with a photograph from a real phone and
// the README needs no edit — see developer notes/screenshots.md.
//
// This file is deliberately not named `*_test.dart`: `flutter test` must not
// collect it, because comparing pixels across machines is a losing game and CI
// has no business failing on a font hint.
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/screens/discover/discover_screen.dart';
import 'package:maichat/screens/gallery/gallery_screen.dart';
import 'package:maichat/screens/providers/provider_edit_screen.dart';
import 'package:maichat/screens/settings/chat_interface_settings_page.dart';

import 'demo_catalogue.dart';
import 'demo_world.dart';
import 'png.dart';
import 'shot.dart';

void main() {
  setUpAll(loadShotFonts);

  testWidgets('01 — a chat', (tester) async {
    usePhone(tester);
    final state = await demoWorld();
    // Names on: a screenshot has to say who is speaking, and it is one switch
    // in Chat Interface. Everything else is the default install.
    await state.updateChatInterface(const ChatInterface(showNames: true));
    seedChat(state);
    await tester.pumpWidget(shotHost(state, const ChatScreen()));
    await tester.pumpAndSettle();
    await shoot(tester, '01-chat');
  });

  testWidgets('02 — the same chat, dressed differently', (tester) async {
    usePhone(tester);
    final state = await demoWorld();
    seedChat(state);
    // Document turns instead of bubbles, big square portraits down one side,
    // names above in their own colour, and a picture behind the thread. Nothing
    // here is a theme preset — every one of these is a control in the app.
    await state.updateChatInterface(const ChatInterface(
      bubbles: false,
      showNames: true,
      contentWidth: ContentWidth.wide,
      fontSize: 15.5,
      messageSpacing: 22,
      botAvatar: AvatarStyle(
        size: 76,
        shape: AvatarShape.rounded,
        corner: CornerRounding.l,
        side: ChatSide.left,
      ),
      userAvatar: AvatarStyle(
        size: 76,
        shape: AvatarShape.rounded,
        corner: CornerRounding.l,
        side: ChatSide.left,
      ),
      syncAvatars: true,
      botNameStyle: NameStyle(
        size: 15,
        position: NamePosition.above,
        align: NameAlign.start,
        color: 0xFF6D4AC4,
      ),
      userNameStyle: NameStyle(
        size: 15,
        position: NamePosition.above,
        align: NameAlign.start,
        color: 0xFF9A5B2E,
      ),
      actionBarPlacement: ActionBarPlacement.besideName,
    ));
    await state.setChatBackground(
      state.active.id,
      demoArtBase64(size: 720, height: 1280, hue: 252),
      opacity: 0.22,
    );
    await tester.pumpWidget(shotHost(state, const ChatScreen()));
    await tester.pumpAndSettle();
    await shoot(tester, '02-chat-styled');
  });

  testWidgets('03 — Discover, browsing a catalogue', (tester) async {
    usePhone(tester);
    final state = await demoWorld();
    await tester.pumpWidget(
      shotHost(state, const DiscoverScreen(sources: [DemoCatalogue()])),
    );
    await tester.pumpAndSettle();
    await shoot(tester, '03-discover');
  });

  testWidgets('04 — the interface, being tuned', (tester) async {
    usePhone(tester);
    final state = await demoWorld();
    await state.updateChatInterface(const ChatInterface(showNames: true));
    seedChat(state);
    await tester.pumpWidget(
      shotHost(state, const ChatInterfaceSettingsPage()),
    );
    await tester.pumpAndSettle();
    await shoot(tester, '04-interface');
  });

  testWidgets('05 — what a provider has cost', (tester) async {
    usePhone(tester);
    final state = await demoWorld();
    await tester.pumpWidget(
      shotHost(state, const ProviderEditScreen(providerId: 'demo-provider')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Costs'));
    await tester.pumpAndSettle();
    await shoot(tester, '05-costs');
  });

  testWidgets('06 — the gallery', (tester) async {
    usePhone(tester);
    final state = await demoWorld();
    await seedGallery(state);
    await tester.pumpWidget(
      shotHost(state, const GalleryScreen(mode: GalleryMode.everything)),
    );
    await tester.pumpAndSettle();
    await shoot(tester, '06-gallery');
  });

  testWidgets('07 — tuning it with the result in front of you', (tester) async {
    usePhone(tester);
    final state = await demoWorld();
    await state.updateChatInterface(const ChatInterface(
      showNames: true,
      botAvatar: AvatarStyle(size: 60, shape: AvatarShape.rounded),
      userAvatar: AvatarStyle(size: 60, shape: AvatarShape.rounded),
      syncAvatars: true,
    ));
    await tester.pumpWidget(
      shotHost(state, const ChatInterfaceSettingsPage()),
    );
    await tester.pumpAndSettle();
    // Through the real route: the eye in the app bar opens the live preview,
    // where an avatar or a name is dragged into place by hand.
    await tester.tap(find.byTooltip('Preview'));
    await tester.pumpAndSettle();
    await shoot(tester, '07-preview');
  });
}
