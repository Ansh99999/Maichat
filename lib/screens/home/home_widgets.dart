import '../../models/home_layout.dart';
import 'home_spec.dart';
import 'widgets/app_folder_widget.dart';
import 'widgets/character_folder_widget.dart';
import 'widgets/characters_widget.dart';
import 'widgets/clock_widget.dart';
import 'widgets/cost_widget.dart';
import 'widgets/gallery_widget.dart';
import 'widgets/note_widget.dart';
import 'widgets/pinned_chat_widget.dart';
import 'widgets/provider_widget.dart';
import 'widgets/quick_open_widget.dart';
import 'widgets/recent_chat_widget.dart';
import 'widgets/search_widget.dart';
import 'widgets/studio_widget.dart';

/// Every widget the Home screen can hold, by kind.
HomeWidgetSpec specFor(HomeWidgetKind kind) => switch (kind) {
      HomeWidgetKind.recentChat => const RecentChatSpec(),
      HomeWidgetKind.pinnedChat => const PinnedChatSpec(),
      HomeWidgetKind.quickOpen => const QuickOpenSpec(),
      HomeWidgetKind.studio => const StudioSpec(),
      HomeWidgetKind.gallery => const GallerySpec(),
      HomeWidgetKind.characters => const CharactersSpec(),
      HomeWidgetKind.provider => const ProviderSpec(),
      HomeWidgetKind.cost => const CostSpec(),
      HomeWidgetKind.search => const SearchSpec(),
      HomeWidgetKind.clock => const ClockSpec(),
      HomeWidgetKind.note => const NoteSpec(),
      HomeWidgetKind.characterFolder => const CharacterFolderSpec(),
      HomeWidgetKind.appFolder => const AppFolderSpec(),
    };

/// The order the "Add widget" picker lists them in.
const List<HomeWidgetKind> kHomeWidgetOrder = [
  HomeWidgetKind.recentChat,
  HomeWidgetKind.pinnedChat,
  HomeWidgetKind.quickOpen,
  HomeWidgetKind.studio,
  HomeWidgetKind.gallery,
  HomeWidgetKind.characters,
  HomeWidgetKind.provider,
  HomeWidgetKind.cost,
  HomeWidgetKind.search,
  HomeWidgetKind.clock,
  HomeWidgetKind.note,
  HomeWidgetKind.characterFolder,
  HomeWidgetKind.appFolder,
];
