import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/chat_interface.dart';
import '../../../state/app_state.dart';
import '../chat_ui_scope.dart';
import '../chat_interface_preview.dart';

/// The frame shared by the Chat Interface hub and each of its spokes: who the
/// page is editing, the app bar that always offers the live preview, and the
/// list padding.

/// Resolves what a Chat Interface page edits and rebuilds when it changes.
///
/// With no [scope] that is the app-wide settings, watched through [AppState].
/// With one it is that scope's draft, which is a `ValueNotifier` rather than a
/// snapshot because a page and its preview are two separate routes over one
/// value — a snapshot would leave whichever route is behind showing stale
/// numbers, and a drag reading a stale snapshot is the bug that made avatar
/// nudging feel dead in v1.10.4.
class ChatUiBuilder extends StatelessWidget {
  const ChatUiBuilder({super.key, required this.scope, required this.builder});

  final ChatUiScope? scope;
  final Widget Function(
    BuildContext context,
    ChatInterface ui,
    void Function(ChatInterface) update,
  ) builder;

  @override
  Widget build(BuildContext context) {
    final scope = this.scope;
    if (scope == null) {
      final state = context.watch<AppState>();
      return builder(context, state.chatInterface, state.updateChatInterface);
    }
    return ValueListenableBuilder<ChatInterface>(
      valueListenable: scope.draft,
      builder: (context, ui, _) =>
          builder(context, ui, (next) => scope.draft.value = next),
    );
  }
}
/// One spoke of the Chat Interface section: an app bar carrying the preview eye,
/// a scrolling list of [children], and — when [onReset] is given — the button
/// that puts just this spoke's settings back to their defaults.
///
/// The eye keeps its `Preview` tooltip on every page, because that tooltip is
/// how the screenshot generator reaches the live preview.
class SpokeScaffold extends StatelessWidget {
  const SpokeScaffold({
    super.key,
    required this.title,
    required this.scope,
    required this.children,
    this.onReset,
    this.resetLabel,
  });

  final String title;
  final ChatUiScope? scope;
  final List<Widget> children;

  /// Writes this spoke's fields back to their out-of-the-box values.
  final VoidCallback? onReset;
  final String? resetLabel;

  @override
  Widget build(BuildContext context) {
    final reset = onReset;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'Preview',
            icon: const Icon(Icons.visibility_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ChatInterfacePreviewPage(scope: scope),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          8,
          8,
          8,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          ...children,
          if (reset != null) ...[
            const SizedBox(height: 8),
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: reset,
                  icon: const Icon(Icons.restart_alt),
                  label: Text(resetLabel ?? 'Reset to defaults'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

