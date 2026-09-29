import 'package:flutter/material.dart';

import '../../services/studio/studio_controller.dart';
import 'draft/chrome_tabs.dart';
import 'shell/studio_chrome.dart';
import 'draft/draft_character_tab.dart';
import 'draft/draft_documents_tab.dart';
import 'draft/draft_embeddings_tab.dart';
import 'draft/draft_images_tab.dart';
import 'draft/draft_lorebook_tab.dart';
import 'draft/draft_scenarios_tab.dart';

/// The draft as it stands, under browser-style tabs: Character, Images,
/// Lorebook, Embeddings, Documents, Scenarios. The Character tab opens with the
/// character's picture and identity, laid out by the picture's shape; every
/// other tab is only its own part of the draft.
///
/// This is a page *body*: the Studio's shell has no app bar, only a floating
/// menu square at the top left (and the area capsule over the foot), so the
/// tab strip sits in the row beside that square — see [StudioChrome]. Every text can be edited by hand; an edit is recorded as a
/// change like the agent's own — so it can be rewound — and the agent is told
/// about it before it builds on the draft again. Editing waits while the agent
/// works.
class StudioDraftView extends StatelessWidget {
  const StudioDraftView({super.key, required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    // The tabs themselves are built once; each page listens for itself, so a
    // streaming agent repaints the page in view without rebuilding the strip.
    Widget page(Widget Function() build) =>
        ListenableBuilder(listenable: controller, builder: (_, _) => build());
    return ChromeTabbedPages(
      tabs: [
        ChromeTab(
          label: 'Character',
          icon: Icons.person_outline,
          page: page(() => DraftCharacterTab(controller: controller)),
        ),
        ChromeTab(
          label: 'Images',
          icon: Icons.photo_library_outlined,
          page: page(() => DraftImagesTab(controller: controller)),
        ),
        ChromeTab(
          label: 'Lorebook',
          icon: Icons.menu_book_outlined,
          page: page(() => DraftLorebookTab(controller: controller)),
        ),
        ChromeTab(
          label: 'Embeddings',
          icon: Icons.hub_outlined,
          page: page(() => DraftEmbeddingsTab(controller: controller)),
        ),
        ChromeTab(
          label: 'Documents',
          icon: Icons.description_outlined,
          page: page(() => DraftDocumentsTab(controller: controller)),
        ),
        ChromeTab(
          label: 'Scenarios',
          icon: Icons.theaters_outlined,
          page: page(() => DraftScenariosTab(controller: controller)),
        ),
      ],
    );
  }
}
