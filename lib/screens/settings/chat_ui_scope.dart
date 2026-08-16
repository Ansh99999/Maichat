import 'package:flutter/foundation.dart';

import '../../models/chat_interface.dart';

/// What the Chat Interface pages are editing, when it is not the app-wide
/// settings: the per-chat copy owned by the Chat settings screen.
///
/// The draft is a notifier rather than a plain value because the settings page
/// and its live preview are two separate routes editing one thing — a snapshot
/// passed down would leave whichever route is behind showing stale values, and
/// a drag reading a stale snapshot is the bug that made avatar nudging feel
/// dead in v1.10.4.
///
/// A null scope means "edit the app-wide settings", which is the ordinary path
/// through Settings.
class ChatUiScope {
  ChatUiScope({
    required this.draft,
    this.title = 'Chat appearance',
    this.note,
  });

  /// The settings being edited. Writes are held here and only reach storage when
  /// the owning screen saves.
  final ValueNotifier<ChatInterface> draft;

  /// App-bar title, so the page says whose settings these are.
  final String title;

  /// A line shown above the options — used to say that changes apply to this
  /// chat alone.
  final String? note;
}
