import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../models/home_layout.dart';
import '../../../services/chat_graph.dart';
import '../../../state/app_state.dart';
import '../home_spec.dart';
import 'chat_card_tile.dart';

/// The latest conversation (or the Nth latest), as a card: avatar, title, a
/// line of its last message, and how long ago it was touched. Tapping opens it.
class RecentChatSpec extends HomeWidgetSpec {
  const RecentChatSpec();

  @override
  HomeWidgetKind get kind => HomeWidgetKind.recentChat;

  @override
  String get title => 'Recent chat';

  @override
  String get description => 'The latest conversation, or one further back';

  @override
  IconData get icon => Icons.chat_bubble_outline;

  @override
  ({int w, int h}) get minSpan => (w: 2, h: 1);

  @override
  List<HomeOption> options(HomeTile tile) => const [
        HomeStepperOption(
          key: 'index',
          label: 'Which chat',
          min: 1,
          max: 5,
          fallback: 1,
          help: '1 = latest, 2 = 2nd latest…',
        ),
        HomeToggleOption(
          key: 'showPreview',
          label: 'Show preview',
          fallback: true,
        ),
      ];

  @override
  String describe(BuildContext context, HomeTile tile) {
    final index = tile.integer('index', 1);
    final ordinal = switch (index) {
      1 => 'latest',
      2 => '2nd latest',
      3 => '3rd latest',
      _ => '${index}th latest',
    };
    return 'Recent chat · $ordinal';
  }

  @override
  Widget build(BuildContext context, HomeTileContext tile) {
    final state = context.watch<AppState>();
    final index = tile.tile.integer('index', 1).clamp(1, 5);
    final showPreview = tile.tile.flag('showPreview', true);
    final chats = state.conversations.where((c) => !c.isEmpty).toList();
    final trees = collapseForks(chats);
    if (trees.length < index) {
      return const HomeEmptyCard(
        icon: Icons.chat_bubble_outline,
        message: 'No chats yet',
      );
    }
    return ChatPreviewCard(
      tree: trees[index - 1],
      editing: tile.editing,
      showPreview: showPreview,
      compact: tile.compact,
    );
  }
}
