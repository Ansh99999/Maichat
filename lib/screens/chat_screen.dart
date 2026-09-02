import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/conversation.dart';
import '../models/character.dart';
import '../models/chat_interface.dart';
import '../models/message.dart';
import '../models/message_image.dart';
import '../models/provider.dart';
import '../services/chat_client.dart';
import '../services/chat_graph.dart';
import '../services/jank_logger.dart';
import '../state/app_state.dart';
import '../widgets/avatar_image.dart';
import '../widgets/avatar_swipe_sheet.dart';
import '../widgets/character_avatar.dart';
import '../widgets/floating_images_layer.dart';
import '../widgets/message_bubble.dart';
import '../widgets/message_info_sheet.dart';
import '../widgets/picture_viewer.dart';
import '../widgets/startup_screen.dart';
import 'characters_screen.dart';
import 'chat_export.dart';
import 'chat_graph_screen.dart';
import 'chat_memory_panel.dart';
import 'chat_settings_screen.dart';
import 'chats_screen.dart';
import 'gallery/chat_gallery_screen.dart';
import 'gallery/gallery_picker_sheet.dart';
import 'group_add_sheet.dart';
import 'image_gen/image_gen_sheet.dart';
import 'prompt_view_screen.dart';
import 'presets/chat_preset_panel.dart';
import 'presets/preset_pickers.dart';
import 'section_screen.dart';
import 'settings_screen.dart';

/// The two buttons that float over a conversation. Named so a test can reach
/// the painted surface whose look is a setting — [ChatInterface.menuButtonOpacity]
/// and [ChatInterface.jumpButtonOpacity] — rather than guess at which of the
/// several `Material`s or fades around them is the one that carries it.
const Key chatMenuButtonKey = ValueKey('chat-menu-button');
const Key jumpToLatestKey = ValueKey('jump-to-latest');

/// A single conversation: the thread and a composer. The chat is deliberately
/// chrome-light — instead of a full app bar it carries a single translucent,
/// non-intrusive soft square at the top-left that opens the chat sidebar, where
/// every option lives (provider/model, edit, export, restart, delete, and the
/// jumps to the other sections).
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// The index of the message currently being edited in place, or null.
  int? _editingIndex;

  /// The text of the turn being edited. One controller for the whole screen: only
  /// one turn is ever edited at a time, and a long-lived controller cannot be
  /// disposed out from under the field that is still using it.
  final TextEditingController _edit = TextEditingController();

  /// The last summary-notice sequence shown, so a completed background summary
  /// toasts exactly once (see [AppState.summaryNoticeSeq]).
  int _lastSummarySeq = 0;

  /// Whether the "jump to latest" affordance is showing. It appears once the
  /// thread is scrolled a screenful or so above the bottom, so a long scroll
  /// back doesn't have to be undone by hand.
  bool _showJumpToEnd = false;

  /// Whether new content should keep the view pinned to the newest message.
  /// True while the reader sits at (or near) the bottom; it flips false the
  /// instant they scroll up, so a streaming reply never yanks them back down.
  bool _stick = true;

  /// New turns that landed while the reader was scrolled away — surfaced as a
  /// count badge on the jump-to-latest button, cleared on return to the bottom.
  int _unread = 0;

  /// The message count last seen for [_lastConvId], to notice a turn arriving.
  int _lastMessageCount = 0;

  /// The conversation the counters above belong to; a switch resets them.
  String? _lastConvId;

  /// How far, in logical pixels, the thread must sit above its bottom before
  /// the jump-to-latest button appears.
  static const double _jumpButtonThreshold = 320;

  /// Within this many pixels of the bottom still counts as "at the bottom", so
  /// a reply keeps following; scroll past it and following stops.
  static const double _stickThreshold = 48;

  /// Whether the composer's operations strip (the three-dot symbols) is open.
  bool _showOps = false;

  /// Whether the group participant bar is shown above the composer. Opened from
  /// the operations strip's group symbol, dismissed by its own ✕.
  bool _showGroupBar = false;

  /// Whether the attachment tray is showing above the composer: the two ways to
  /// choose a picture, and then the preview of what is about to be sent. Opened
  /// from the operations strip's picture symbol.
  bool _showAttachBar = false;

  /// Whether the response-hint box is showing above the operations strip. Its ✕
  /// only *closes* it: the hint itself stays, and stays in force, until the
  /// reader erases it — see [_hint].
  bool _showHintBar = false;

  /// The response hint for the chat on screen, held here while the box is open so
  /// typing into it costs nothing but a rebuild of the box. Loaded from
  /// [AppState.responseHint] when the chat changes and pushed back on every
  /// change; written to disk only at the points where it could be lost (see
  /// [_saveHint]).
  final TextEditingController _hint = TextEditingController();

  /// Which chat [_hint] was loaded for, so switching chats swaps the hint over
  /// rather than carrying one thread's steering into another.
  String? _hintConvId;

  /// Whether a hint is currently in force — drives the lit symbol in the strip,
  /// which is the only sign a *closed* box leaves that the next reply is being
  /// steered. Kept as state rather than read off [_hint] in build, so the symbol
  /// can update without a listener rebuilding the whole screen per keystroke.
  bool _hintActive = false;

  /// Pictures already chosen for the next send, in the order they were picked.
  final List<MessageImage> _attachments = <MessageImage>[];

  /// The text the newest turn had when the reader scrolled away from the bottom
  /// mid-stream, and how far the thread had grown by then.
  ///
  /// The thread is a *reversed* list, so its newest turn is the one anchored to
  /// the bottom and everything older is measured from it: every time that turn
  /// gains (or, when a half-written markdown fence reflows, loses) a line, every
  /// message above it moves by that much. Somebody reading three screens back
  /// therefore watched the page twitch on every token. While they are away the
  /// newest turn is drawn with the text it had when they left, so the thread holds
  /// perfectly still; it catches up the moment they return to the bottom.
  String? _frozenTail;
  String _frozenTailReasoning = '';

  /// The held-still copy of the newest turn, made once per freeze rather than on
  /// every repaint. A fresh copy each time would look like a changed message to
  /// [_bubbles] and rebuild the bubble the freeze exists to leave alone.
  ChatMessage? _frozenCopy;

  /// Bubbles already built, by message position — see [_CachedBubble].
  final Map<int, _CachedBubble> _bubbles = <int, _CachedBubble>{};

  /// A cap on [_bubbles]; a screenful is well under this, and going over means a
  /// long scroll has been through, so the whole lot is dropped rather than aged.
  static const int _bubbleCacheMax = 64;

  @override
  void initState() {
    super.initState();
    JankLogger.instance.breadcrumb('chat screen opened');
    _scroll.addListener(_onScroll);
    // Never pop the soft keyboard just because the chat opened — drop any focus
    // carried in from the previous screen once the first frame is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      JankLogger.instance.breadcrumb('chat first frame built');
      if (mounted) FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    // Leaving the chat is one of the points a hint must survive; the box may well
    // still be open with something typed in it.
    _flushHint();
    _hint.dispose();
    _edit.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Reads [conversationId]'s hint into the box, when it is not already the one
  /// showing. Called from build, so it only touches the controller and the two
  /// fields that track it — never [setState].
  void _adoptHint(AppState state, String conversationId) {
    if (_hintConvId == conversationId) return;
    _hintConvId = conversationId;
    final text = state.responseHint(conversationId);
    _hint.text = text;
    _hintActive = text.trim().isNotEmpty;
  }

  /// Records what has been typed and, when the box has just become (or stopped
  /// being) empty, relights the strip's symbol.
  void _onHintChanged(AppState state, String text) {
    final id = _hintConvId;
    if (id == null) return;
    state.setResponseHint(id, text);
    final active = text.trim().isNotEmpty;
    if (active != _hintActive) setState(() => _hintActive = active);
  }

  /// Writes the hint out. Called where losing it would matter — closing the box,
  /// sending, and leaving the chat — rather than on every keystroke, which would
  /// be a preferences write per character typed.
  void _flushHint() => _persistHints?.call();

  /// [AppState.saveResponseHints], bound during build.
  ///
  /// Held as a closure so [dispose] can write the hint out without reaching for
  /// the provider — by then this element is on its way out of the tree and a
  /// lookup is no longer allowed. The state outlives the screen, so the bound
  /// method stays good.
  Future<void> Function()? _persistHints;

  /// Shows or hides the jump-to-latest button as the thread is scrolled, and
  /// tracks whether the reader is at the bottom (so streaming keeps following)
  /// or has scrolled up (so it stops). The list is reversed, so the newest
  /// message sits at offset 0 and scrolling *up* into older turns moves
  /// [ScrollPosition.pixels] away from it.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pixels = _scroll.position.pixels;
    final show = pixels > _jumpButtonThreshold;
    final stick = pixels <= _stickThreshold;
    var changed = false;
    if (show != _showJumpToEnd) {
      _showJumpToEnd = show;
      changed = true;
    }
    if (stick != _stick) {
      _stick = stick;
      changed = true;
    }
    // Back at the bottom: the reader has caught up, so drop the unread badge.
    if (stick && _unread != 0) {
      _unread = 0;
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  Future<void> _send(AppState state) async {
    final text = _input.text;
    final images = List<MessageImage>.of(_attachments);
    if ((text.trim().isEmpty && images.isEmpty) || state.streaming) return;
    if (!state.isConfigured) {
      _openSettings();
      return;
    }
    _input.clear();
    setState(() {
      _attachments.clear();
      _showAttachBar = false;
    });
    // Sending never clears the hint — it goes out with this reply and stays for
    // the next — but it is a good moment to make sure it has reached disk.
    _flushHint();
    _stickToLatest();
    await state.send(text, images: images);
    _stickToLatest();
  }

  /// Picks a picture out of the app's own gallery for the next send.
  Future<void> _attachFromGallery(AppState state) async {
    final ref = await showGalleryPickerSheet(
      context,
      title: 'Send a picture',
      characterId: state.active.characterId,
    );
    if (ref == null || !mounted) return;
    setState(() => _attachments
        .add(MessageImage(ref: ref, mime: mimeForRef(ref))));
  }

  /// Picks pictures off the device for the next send. The bytes are written into
  /// the pictures directory straight away, so the message holds a reference like
  /// every other picture in the app rather than a blob.
  Future<void> _attachFromDevice(AppState state) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: true,
        withData: true,
      );
    } catch (_) {
      result = null;
    }
    if (result == null || result.files.isEmpty || !mounted) return;
    final chosen = <MessageImage>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) continue;
      final image = await state.storeAttachment(bytes);
      if (image != null) chosen.add(image);
    }
    if (!mounted) return;
    if (chosen.isEmpty) {
      _toast('Those pictures could not be read.');
      return;
    }
    setState(() => _attachments.addAll(chosen));
  }

  /// Opens the image studio over the chat — the 75%-height sheet where pictures
  /// are made. [prompt] seeds the prompt box, which is how a message's "Generate
  /// image" action hands its own text over.
  void _openImageStudio({String prompt = ''}) => showImageStudio(
        context,
        conversationId: context.read<AppState>().active.id,
        prompt: prompt,
      );

  void _openSettings() => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
      );

  void _openSection(String title, IconData icon) => Navigator.of(context).push(
        MaterialPageRoute<void>(
            builder: (_) => SectionScreen(title: title, icon: icon)),
      );

  /// The fork tree this chat belongs to. Selecting a branch there pops back
  /// here, and this screen already rebuilds off the active chat, so it shows
  /// the branch that was picked.
  void _openChatGraph(String conversationId) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatGraphScreen(conversationId: conversationId),
        ),
      );

  void _openCharacters() => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const CharactersScreen()),
      );

  /// Back to the landing Home screen (the first route).
  void _goHome() => Navigator.of(context).popUntil((route) => route.isFirst);

  /// Home first, then open the full Chats list, so Back is predictable.
  void _goChats() {
    _goHome();
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ChatsScreen()),
    );
  }

  void _openQuickSettings() => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => _QuickSettingsSheet(onManage: () {
          Navigator.of(context).pop();
          _openSettings();
        }),
      );

  /// Opens the chat's own settings: title, background, a style of its own, and
  /// the characters taking part. Replaces the old rename-only dialog — renaming
  /// is now the first field on that screen.
  void _editChat(AppState state) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatSettingsScreen(conversationId: state.active.id),
        ),
      );

  /// Hands the thread to the export flow, which offers the shapes and then the
  /// file / clipboard chooser.
  Future<void> _exportChat(AppState state) async {
    final conversation = state.active;
    if (conversation.isEmpty) {
      _toast('Nothing to export yet.');
      return;
    }
    await exportChat(context, conversation);
  }

  Future<void> _restartChat(AppState state) async {
    final ok = await _confirm(
      title: 'Restart chat?',
      body: 'This clears every message in this chat but keeps it around.',
      action: 'Restart',
    );
    if (ok) {
      await state.restartConversation();
      _stickToLatest();
    }
  }

  Future<void> _deleteChat(AppState state) async {
    final ok = await _confirm(
      title: 'Delete chat?',
      body: '"${state.active.title}" will be removed permanently.',
      action: 'Delete',
    );
    if (!ok) return;
    await state.deleteConversation(state.active.id);
    if (mounted) _goHome();
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _toast(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  /// Returns to the newest message. The list is reversed, so "the end" is
  /// offset 0: [animated] glides there (the jump-to-latest button), otherwise it
  /// snaps, which is what streaming and sending want.
  ///
  /// A snap deliberately gives way to the reader. `jumpTo` calls `goIdle`, which
  /// throws away whatever activity the position was running — so a snap fired
  /// while a finger is on the thread kills the drag outright, and one fired
  /// during a fling stops it dead. Streaming asks for this on every repaint, so
  /// the first few pixels of every scroll-back used to be cancelled again and
  /// again until the reader had dragged past the stick threshold. It is also
  /// simply unnecessary at rest: in a reversed list, offset 0 pins the *bottom*
  /// of the newest turn to the bottom of the viewport, so a growing reply follows
  /// itself with no scrolling at all.
  void _scrollToEnd({bool animated = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final position = _scroll.position;
      if (animated) {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        );
        return;
      }
      // Already there: nothing to do, and nothing to interrupt.
      if (position.pixels.abs() < 0.5) return;
      // The reader has hold of the thread — leave it in their hands.
      if (position.userScrollDirection != ScrollDirection.idle) return;
      _scroll.jumpTo(0);
    });
  }

  /// Re-arms the follow-the-newest behaviour and clears the unread badge, then
  /// scrolls to the bottom. Used by every action where the reader has asked to
  /// be at the latest message (sending, regenerating, the jump button, …), as
  /// opposed to the passive follow that streaming does only while already stuck.
  void _stickToLatest({bool animated = false}) {
    _stick = true;
    _unread = 0;
    _scrollToEnd(animated: animated);
  }

  // --- a turn without typing one -------------------------------------------

  /// Carries the newest reply on from where it stopped. The strip is put away
  /// first: what happens next happens in the thread, and it needs the room.
  Future<void> _continueReply(AppState state) async {
    setState(() => _showOps = false);
    _stickToLatest();
    await state.continueReply();
    if (mounted) _stickToLatest();
  }

  /// Asks for another reply with nothing typed.
  Future<void> _respondAgain(AppState state) async {
    setState(() => _showOps = false);
    _stickToLatest();
    await state.respondAgain();
    if (mounted) _stickToLatest();
  }

  /// Has the model write the user's next line into the composer, where it can be
  /// read, edited or thrown away before it is sent. It arrives as it is written,
  /// and the send button is a Stop button throughout, so a line going the wrong
  /// way can be cut short.
  Future<void> _writeForMe(AppState state) async {
    setState(() => _showOps = false);
    final before = _input.text;
    try {
      final written = await state.writeForUser(onProgress: _fillComposer);
      if (!mounted) return;
      if (written == null) {
        // Nothing came back: leave the box exactly as it was found.
        _fillComposer(before);
        _toast('The model wrote nothing back.');
        return;
      }
      _fillComposer(written);
    } on ChatApiException catch (e) {
      if (!mounted) return;
      _fillComposer(before);
      _toast(e.message);
    }
  }

  /// Puts [text] in the composer with the caret after it, ready to be sent or
  /// carried on from.
  void _fillComposer(String text) {
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
// APPEND-MARKER-1

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.ready) return const StartupScreen();
    // A background summary finished with notifications on: toast it once.
    if (state.summaryNoticeSeq != _lastSummarySeq) {
      _lastSummarySeq = state.summaryNoticeSeq;
      final notice = state.summaryNotice;
      if (notice != null) {
        state.consumeSummaryNotice();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _toast(notice);
        });
      }
    }
    final conversation = state.active;
    // The hint belongs to the chat on screen, and [dispose] needs a way to write
    // it out; both are settled here, before anything draws.
    _persistHints = state.saveResponseHints;
    _adoptHint(state, conversation.id);
    // Follow new content, but only for a reader who is already at the bottom.
    // Someone scrolled up to re-read stays put; a turn that arrives while they
    // are away bumps the unread badge on the jump-to-latest button instead of
    // dragging them down. Reference-only: no setState — this all runs inside a
    // build already triggered by the state change that grew the thread.
    final count = conversation.messages.length;
    // An editor cannot outlive what it is editing: a chat switched away from, or a
    // turn deleted (or rolled back by a regenerate) out from under it, closes it.
    if (_editingIndex != null &&
        (conversation.id != _lastConvId || _editingIndex! >= count)) {
      _editingIndex = null;
    }
    if (conversation.id != _lastConvId) {
      _lastConvId = conversation.id;
      _lastMessageCount = count;
      _unread = 0;
      _stick = true;
      // Another chat's bubbles are no use here, and their closures point at the
      // thread they were built for.
      _bubbles.clear();
      _scrollToEnd();
    } else if (count != _lastMessageCount) {
      final grew = count > _lastMessageCount;
      _lastMessageCount = count;
      if (grew) {
        if (_stick) {
          _scrollToEnd();
        } else {
          _unread += 1;
        }
      } else if (_unread != 0) {
        // Turns were removed (delete/regenerate rollback): the count no longer
        // maps to anything unread.
        _unread = 0;
      }
    }
    // Keep pinned to the newest text as a reply streams in — but only while the
    // reader is at the bottom, so scrolling up during a stream is never undone.
    if (state.streaming && _stick) _scrollToEnd();
    // Away from the bottom mid-stream: hold the newest turn at the text it had
    // when they left, so the thread they are reading does not twitch on every
    // token — see [_frozenTail].
    if (state.streaming && !_stick && !conversation.isEmpty) {
      final tail = conversation.messages.last;
      if (_frozenTail == null) {
        _frozenTail = tail.content;
        _frozenTailReasoning = tail.reasoning;
        _frozenCopy = null;
      }
    } else if (_frozenTail != null) {
      _frozenTail = null;
      _frozenTailReasoning = '';
      _frozenCopy = null;
    }

    // The status-bar inset, read from **viewPadding** rather than padding. They
    // are the same number here, but `padding` shrinks as the soft keyboard rises
    // (it is `viewPadding` minus the keyboard's insets), so depending on it made
    // every frame of the keyboard's animation rebuild this whole screen — the
    // composer, the thread and all — which is exactly the grain the reader feels
    // when tapping into the box. `viewPadding` does not move when the keyboard
    // does, so the keyboard now only *relayouts* the chat instead of rebuilding
    // it, and the subtrees below are handed back unchanged.
    final topInset = MediaQuery.viewPaddingOf(context).top;
    // A chat can carry chat-style settings of its own; otherwise the app-wide
    // ones apply.
    final ui = state.interfaceFor(conversation);
    final bg = ui.backgroundColor != null ? Color(ui.backgroundColor!) : null;

    return Scaffold(
      backgroundColor: bg,
      drawer: _ChatDrawer(
        onProfile: _goHome,
        onCharacters: _openCharacters,
        onChats: _goChats,
        onGallery: () => openChatGallery(context, conversation.id),
        onEditChat: () => _editChat(state),
        onChatGraph: () => _openChatGraph(conversation.id),
        onProviderModel: _openQuickSettings,
        onSettings: _openSettings,
        onImageGen: _openImageStudio,
        onExport: () => _exportChat(state),
        onRestart: () => _restartChat(state),
        onDelete: () => _deleteChat(state),
        onNotifications: () =>
            _openSection('Notifications', Icons.notifications_outlined),
      ),
      body: Stack(
        children: [
          // This chat's own picture, behind everything and behind nothing else's.
          if (conversation.backgroundImage != null)
            Positioned.fill(
              child: _ChatBackground(
                image: conversation.backgroundImage!,
                opacity: conversation.backgroundOpacity,
              ),
            ),
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: conversation.isEmpty
                      ? _EmptyState(
                          configured: state.isConfigured,
                          onSettings: _openSettings,
                        )
                      : Stack(
                          children: [
                            // The thread is its own retained layer, so moving a
                            // floating picture over it re-composites that one
                            // cached layer instead of re-recording the whole
                            // message viewport (every visible bubble) on the UI
                            // thread each frame. Without this boundary a float's
                            // repaint bubbles past the list to a far ancestor and
                            // re-records it — the drag/pinch stutter on a busy
                            // chat. Scrolling still repaints the list as normal;
                            // this only isolates it from its siblings.
                            RepaintBoundary(
                              child: _messageList(conversation, state, topInset),
                            ),
                            // Pictures pinned over the thread. Above the messages
                            // and below the composer, so a float can be moved
                            // anywhere in the conversation without ever covering
                            // the send bar.
                            Positioned.fill(
                              child: FloatingImagesLayer(
                                conversationId: conversation.id,
                              ),
                            ),
                            // Sits at the bottom-right of the thread, just above
                            // the composer, and only while scrolled well up.
                            Positioned(
                              right: 12,
                              bottom: 12,
                              child: _JumpToLatestButton(
                                visible: _showJumpToEnd || _unread > 0,
                                unread: _unread,
                                opacity: ui.jumpButtonOpacity,
                                // A reply is still being written down there, and
                                // while the reader is away the newest turn is held
                                // still on purpose — so the button says so rather
                                // than letting a frozen turn read as a stalled
                                // one.
                                live: state.streaming && !_stick,
                                onTap: () =>
                                    setState(() => _stickToLatest(animated: true)),
                              ),
                            ),
                          ],
                        ),
                ),
                // The participant bar slides up from the composer when opened
                // and collapses back into it when hidden. Anchored to the
                // bottom so the growth reads as rising out of the send bar, the
                // Android way; at rest it settles to the bar's full height so
                // every chip keeps its hit region.
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.bottomCenter,
                  child: (_showGroupBar && conversation.isGroup)
                      ? _GroupBar(
                          conversation: conversation,
                          participants: state.participantsOf(conversation),
                          user: state.impersonationFor(conversation),
                          ui: ui,
                          onChip: (id) {
                            state.speakAs(id);
                            _stickToLatest();
                          },
                          onUser: () => _openImpersonatePicker(state),
                          onRemove: (id) =>
                              state.removeParticipant(conversation.id, id),
                          onResponder: (value) =>
                              state.toggleGroupResponder(conversation.id, value),
                          onClose: () => setState(() => _showGroupBar = false),
                        )
                      : const SizedBox(width: double.infinity),
                ),
                // Its own retained layer. The caret in the message box blinks
                // twice a second and the strips above it animate open and shut;
                // without a boundary each of those repaints re-records the layer
                // it shares with the chat's background picture and everything
                // floating over the thread.
                RepaintBoundary(child: _composer(state)),
              ],
            ),
          ),
          // The one piece of chrome: a translucent soft square that floats over
          // the thread without boxing it in.
          Positioned(
            top: topInset + 6,
            left: 8,
            child: Builder(
              builder: (ctx) => _ChatMenuButton(
                opacity: ui.menuButtonOpacity,
                onTap: () => Scaffold.of(ctx).openDrawer(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _messageList(Conversation conversation, AppState state, double top) {
    final ui = state.interfaceFor(conversation);
    final character = state.characterFor(conversation, conversation.characterId);
    final persona = state.impersonationFor(conversation);
    return ListView.builder(
      controller: _scroll,
      // Reversed so the newest turn sits at the bottom (offset 0) and the list
      // builds outward from it. A forward list jumped to its bottom forces
      // RenderSliverList to build *every* message in one pass — a several-second
      // freeze at 900 turns and an out-of-memory crash past ~3000. Reversed, only
      // the visible turns are ever built, so a huge chat opens as fast as a small
      // one. Display index 0 is the last message; map it back to walk forwards.
      reverse: true,
      // Let scrolled-past turns be released rather than pinned alive: the
      // markdown/HTML renderers cache parsed output, so a turn rebuilds cheaply
      // when it scrolls back on. Keeps a 3000-message thread's memory bounded.
      addAutomaticKeepAlives: false,
      // Leave room so the first bubble clears the floating hamburger.
      padding: EdgeInsets.fromLTRB(0, top + 56, 0, 8),
      itemCount: conversation.messages.length,
      itemBuilder: (context, index) {
        final msgIndex = conversation.messages.length - 1 - index;
        final isLast = index == 0;
        var message = conversation.messages[msgIndex];
        // The newest turn, held at the text it had when the reader scrolled away
        // mid-stream. Everything else about the turn is live.
        if (isLast && _frozenTail != null) {
          message = _frozenCopy ??= message.copyWith(
            content: _frozenTail,
            reasoning: _frozenTailReasoning,
          );
        }
        // Being edited: the very same bubble, with the words editable in place —
        // see [MessageBubble.editing]. Never the cache: the editor holds a live
        // controller, and a cached widget would hand it to the wrong turn.
        final editing = msgIndex == _editingIndex;
        // In a group, a turn is spoken by whoever it names; in a one-to-one chat
        // the bound character and the impersonated persona apply throughout.
        final speaker = conversation.isGroup && message.speakerId != null
            ? (state.characterFor(conversation, message.speakerId) ?? character)
            : character;
        final userSpeaker =
            conversation.isGroup && message.isUser && message.speakerId != null
                ? (state.characterFor(conversation, message.speakerId) ?? persona)
                : persona;
        // The picture each side wears *in this thread*, resolved in the one
        // place that decides it. Read here rather than inside the bubble so a
        // per-chat choice cannot be honoured here and forgotten elsewhere — and
        // so it is part of what tells this bubble apart from the one already
        // built below.
        final avatarOverride =
            speaker == null ? null : state.avatarRefFor(conversation, speaker);
        final userAvatarOverride = userSpeaker == null
            ? null
            : state.avatarRefFor(conversation, userSpeaker);
        // The waiting state belongs to a reply landing in the thread. A line
        // being written for the *composer* is a request too, but nothing in the
        // transcript is waiting on it.
        final pending = isLast && state.streaming && !state.writingForUser;
        // Everything the bubble is drawn from. Unchanged since the last build
        // means the bubble is unchanged, and handing back the very same widget
        // lets Flutter skip the subtree — see [_CachedBubble].
        final signature = <Object?>[
          message,
          ui,
          speaker,
          userSpeaker,
          avatarOverride,
          userAvatarOverride,
          pending,
          state.streaming,
        ];
        final cached = editing ? null : _bubbles[msgIndex];
        if (cached != null && listEquals(cached.signature, signature)) {
          return cached.widget;
        }
        final bubble = MessageBubble(
          key: editing ? ValueKey('edit-${conversation.id}-$msgIndex') : null,
          message: message,
          ui: ui,
          character: speaker,
          userPersona: userSpeaker,
          avatarOverride: avatarOverride,
          userAvatarOverride: userAvatarOverride,
          onAvatarTap: (isUser) =>
              _openAvatar(state, conversation, isUser ? userSpeaker : speaker),
          onImageTap: (at) => showPictureViewer(
            context,
            refs: [for (final image in message.images) image.ref],
            index: at,
          ),
          pending: pending,
          streaming: state.streaming,
          editing: editing,
          editController: editing ? _edit : null,
          onEditCancel: _stopEditing,
          onEditSave: () => _saveEdit(state, conversation, msgIndex),
          onAction: (action) =>
              _runMessageAction(state, conversation, msgIndex, action),
          onSwipe: (swipe) => state.setSwipe(conversation.id, msgIndex, swipe),
          onLongPress: message.content.isEmpty
              ? null
              : () => _showMessageActions(state, conversation, msgIndex),
        );
        if (editing) return bubble;
        if (_bubbles.length >= _bubbleCacheMax) _bubbles.clear();
        _bubbles[msgIndex] = _CachedBubble(signature, bubble);
        return bubble;
      },
    );
  }

  /// Starts editing the turn at [index] in place: its own bubble becomes the
  /// editor (avatar, name, pictures and layout all untouched) and its action bar
  /// becomes ✕/✓.
  void _startEditing(Conversation conversation, int index) {
    if (index < 0 || index >= conversation.messages.length) return;
    _edit.value = TextEditingValue(
      text: conversation.messages[index].content,
    );
    setState(() => _editingIndex = index);
  }

  /// Leaves the editor, keeping nothing.
  void _stopEditing() {
    if (_editingIndex == null) return;
    setState(() => _editingIndex = null);
  }

  /// Commits what was typed and leaves the editor.
  Future<void> _saveEdit(
      AppState state, Conversation conversation, int index) async {
    final text = _edit.text;
    _stopEditing();
    await state.editMessage(conversation.id, index, text);
  }

  /// Opens [who]'s picture full size, with their other pictures to swipe through.
  ///
  /// Nothing happens when there is no character behind the avatar (a plain chat,
  /// or the user speaking as themself) or when they have no picture at all — a
  /// blank screen is not worth a route.
  void _openAvatar(AppState state, Conversation conversation, Character? who) {
    if (who == null) return;
    if (!hasAvatarToShow(state, conversation, who)) return;
    showAvatarSwipeSheet(
      context,
      character: who,
      conversationId: conversation.id,
    );
  }

  /// Dispatches an inline/overflow message action to the matching handler.
  void _runMessageAction(
    AppState state,
    Conversation conversation,
    int index,
    MessageAction action,
  ) {
    switch (action) {
      case MessageAction.regenerate:
        state.regenerateMessage(conversation.id, index);
        _stickToLatest();
      case MessageAction.edit:
        _startEditing(conversation, index);
      case MessageAction.delete:
        _deleteMessage(state, conversation, index);
      case MessageAction.copy:
        Clipboard.setData(
            ClipboardData(text: conversation.messages[index].content));
        _toast('Copied');
      case MessageAction.fork:
        _forkFrom(state, conversation, index);
      case MessageAction.prompt:
        _openPromptView(state, conversation, index);
      case MessageAction.info:
        _openMessageInfo(state, conversation, index);
      case MessageAction.imagine:
        _openImageStudio(prompt: conversation.messages[index].content);
    }
  }

  /// Confirms a message delete, and — when there are turns after it — asks which
  /// of the two deletes was meant.
  ///
  /// A turn is never removed on one tap: a mistap on a bar of small symbols used
  /// to take a message out of the transcript with nothing to undo it. And a turn
  /// from the middle of a conversation is rarely wanted on its own — deleting it
  /// usually means undoing the direction the chat took, of which the replies that
  /// answered it are part. So the dialog offers both, the way Agnai's does:
  /// "Delete one" beside "delete the last N", with the sweeping one marked as the
  /// destructive choice. The tail of the conversation has nothing to follow it, so
  /// there it is a plain confirmation.
  Future<void> _deleteMessage(
    AppState state,
    Conversation conversation,
    int index,
  ) async {
    if (index < 0 || index >= conversation.messages.length) return;
    // Everything from this turn to the end, this one included — the count the
    // sweeping button offers to remove.
    final span = conversation.messages.length - index;
    final scheme = Theme.of(context).colorScheme;
    final choice = await showDialog<_DeleteScope>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Delete message?'),
        content: Text(
          span <= 1
              ? 'This message will be removed permanently.'
              : 'There ${span - 1 == 1 ? 'is' : 'are'} ${span - 1} '
                  '${span - 1 == 1 ? 'message' : 'messages'} after this one. '
                  'Delete this message on its own, or everything from here to '
                  'the end of the chat?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: const Text('Cancel'),
          ),
          if (span > 1)
            TextButton(
              key: const Key('delete-this-only'),
              onPressed: () =>
                  Navigator.of(dialog).pop(_DeleteScope.thisMessage),
              child: const Text('This one only'),
            ),
          FilledButton(
            key: const Key('delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(dialog).pop(
                span > 1 ? _DeleteScope.fromHere : _DeleteScope.thisMessage),
            child: Text(span > 1 ? 'Delete $span' : 'Delete'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (choice == _DeleteScope.thisMessage) {
      await state.deleteMessage(conversation.id, index);
      return;
    }
    await state.deleteMessagesFrom(conversation.id, index);
  }

  Future<void> _forkFrom(
      AppState state, Conversation conversation, int index) async {    await state.forkConversation(conversation.id, index);
    if (!mounted) return;
    // The fork joins this chat's tree rather than becoming a separate row in the
    // lists, so the toast points at where it can be found.
    _toast('Branched — see Chat Graph');
    _stickToLatest();
  }

  /// Opens the full assembled prompt behind [index] — exactly what the model
  /// receives — in a scrollable inspector.
  void _openPromptView(AppState state, Conversation conversation, int index) {
    final assembled = state.assemblePromptForMessage(conversation, index);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PromptViewScreen(assembled: assembled),
      ),
    );
  }

  /// Opens the message info sheet: position, tokens, and a context breakdown.
  void _openMessageInfo(AppState state, Conversation conversation, int index) {
    final assembled = state.assemblePromptForMessage(conversation, index);
    final message = conversation.messages[index];
    // An exact provider-side count only exists for Anthropic; fetched lazily so
    // it never blocks opening the sheet.
    final exact = state.activeProvider?.kind == ProviderKind.anthropic
        ? state.exactTokenCount(assembled)
        : null;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => MessageInfoSheet(
        assembled: assembled,
        messageNumber: index + 1,
        messageCount: conversation.messages.length,
        message: message,
        messageTokens: state.estimateTokens(message.content),
        exactCount: exact,
      ),
    );
  }

  /// The per-message action sheet: copy, edit, regenerate (assistant turns),
  /// fork from here, or delete.
  void _showMessageActions(
    AppState state,
    Conversation conversation,
    int index,
  ) {
    final message = conversation.messages[index];
    final isAssistant = !message.isUser;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Copy'),
              onTap: () {
                Navigator.of(sheet).pop();
                Clipboard.setData(ClipboardData(text: message.content));
                _toast('Copied');
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.of(sheet).pop();
                _startEditing(conversation, index);
              },
            ),
            if (isAssistant)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Regenerate'),
                enabled: !state.streaming,
                onTap: () {
                  Navigator.of(sheet).pop();
                  state.regenerateMessage(conversation.id, index);
                  _scrollToEnd();
                },
              ),
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('Generate image'),
              subtitle: const Text('Open the studio with this message as the '
                  'prompt'),
              onTap: () {
                Navigator.of(sheet).pop();
                _openImageStudio(prompt: message.content);
              },
            ),
            ListTile(
              leading: const Icon(Icons.call_split),
              title: const Text('Branch from here'),
              subtitle: const Text('Carry on differently, in this chat\'s graph'),
              onTap: () async {
                Navigator.of(sheet).pop();
                await state.forkConversation(conversation.id, index);
                _toast('Branched — see Chat Graph');
                _scrollToEnd();
              },
            ),
            if (isAssistant)
              ListTile(
                leading: const Icon(Icons.terminal),
                title: const Text('View prompt'),
                subtitle: const Text('Inspect the exact request sent'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _openPromptView(state, conversation, index);
                },
              ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Info'),
              subtitle: const Text('Tokens and context breakdown'),
              onTap: () {
                Navigator.of(sheet).pop();
                _openMessageInfo(state, conversation, index);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(sheet).colorScheme.error),
              title: const Text('Delete'),
              enabled: !state.streaming,
              onTap: () {
                Navigator.of(sheet).pop();
                _deleteMessage(state, conversation, index);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _composer(AppState state) {
    final scheme = Theme.of(context).colorScheme;
    final persona = state.impersonationFor(state.active);
    final conversation = state.active;
    final groupEnabled = state.groupChatsEnabled;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The attachment tray sits **above** the operations strip, not between
          // it and the send bar: what is about to be sent belongs at the top of
          // the stack, with the controls that change it underneath, so a growing
          // pile of pictures pushes away from the thumb rather than shoving the
          // symbols around. Grows out of the strip below it.
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomCenter,
            child: !_showAttachBar
                ? const SizedBox(width: double.infinity)
                : _AttachBar(
                    attachments: _attachments,
                    onGallery: () => _attachFromGallery(state),
                    onDevice: () => _attachFromDevice(state),
                    onRemove: (i) => setState(() => _attachments.removeAt(i)),
                    onClose: () => setState(() => _showAttachBar = false),
                  ),
          ),
          // The response-hint box: above the operations strip that opens it, so
          // the steering for the next reply reads as part of what is about to be
          // sent rather than as another control. Below the attachment tray for
          // the same reason the tray is where it is — pictures pile up, and they
          // grow away from the thumb.
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomCenter,
            child: !(_showHintBar && state.responseHintEnabled)
                ? const SizedBox(width: double.infinity)
                : _HintBar(
                    controller: _hint,
                    depth: state.responseHintDepth,
                    onChanged: (text) => _onHintChanged(state, text),
                    onClose: () {
                      _flushHint();
                      setState(() => _showHintBar = false);
                    },
                  ),
          ),
          // The operations strip: one row of symbols opened by the composer's ⋯
          // button. Sending a picture, the image studio, group chat when the
          // feature is switched on, and the three ways to get a turn without
          // typing one.
          //
          // AnimatedSize expands it open/closed. It is anchored top-right so the
          // strip grows straight down from under the ⋯ button (which lives at the
          // right, beside Send) and its content sits inside the clip the whole
          // way — the earlier animated attempt used the default centre alignment,
          // which clipped the group symbol mid-grow and left it untappable. At
          // rest the size settles to the strip's natural size, so each symbol
          // keeps its full hit region.
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topRight,
            child: !_showOps
                ? const SizedBox(width: double.infinity)
                // Full width on purpose, like the closed state: the composer's
                // Column centres a child that shrink-wraps, so the strip has to
                // fill the width and let its own contents settle to the right —
                // under the ⋯ button they belong to. It also leaves AnimatedSize
                // animating the height alone.
                : SizedBox(
                    width: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6, right: 4),
                      // Seven symbols is more than a narrow phone can fit at a
                      // full 48dp touch target each, and a Row that overflows
                      // simply clips whatever hangs off the end. Anchored to the
                      // right (`reverse`), so the tools keep their places under
                      // the ⋯ and it is the far end that can be slid into view
                      // rather than lost.
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        reverse: true,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Asking for a turn: kept together, and to the left
                            // of the tools so those stay exactly where they have
                            // always been.
                            _TurnActions(
                              busy: state.streaming,
                              canContinue:
                                  state.continuableIndex(conversation) != null,
                              canRespond: state.canRespondAgain(conversation),
                              onContinue: () => _continueReply(state),
                              onRespondAgain: () => _respondAgain(state),
                              onWriteForMe: () => _writeForMe(state),
                            ),
                            // Two families of action, told apart by a hairline
                            // rather than by guesswork.
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: SizedBox(
                                height: 24,
                                child: VerticalDivider(
                                  width: 1,
                                  thickness: 1,
                                  color: scheme.outlineVariant,
                                ),
                              ),
                            ),
                            // Steering for the next reply. Placed at the left of
                            // the tools rather than the right: the strip is
                            // anchored to the ⋯ button, so growing it leftwards
                            // leaves every symbol that was already here exactly
                            // where the thumb learned to find it.
                            if (state.responseHintEnabled)
                              IconButton(
                                key: const Key('composer-hint-button'),
                                tooltip: 'Response hint',
                                isSelected: _showHintBar,
                                onPressed: () => setState(() {
                                  _showHintBar = !_showHintBar;
                                  if (!_showHintBar) _flushHint();
                                }),
                                // Lit when something is typed, so a closed box
                                // still says the next reply is being steered.
                                icon: Icon(_hintActive
                                    ? Icons.tips_and_updates
                                    : Icons.tips_and_updates_outlined),
                              ),
                            IconButton(
                              key: const Key('composer-image-button'),
                              tooltip: 'Send a picture',
                              isSelected: _showAttachBar,
                              onPressed: () => setState(
                                  () => _showAttachBar = !_showAttachBar),
                              icon: const Icon(Icons.image_outlined),
                            ),
                            IconButton(
                              key: const Key('composer-imagegen-button'),
                              tooltip: 'Image studio',
                              onPressed: () => _openImageStudio(),
                              icon: const Icon(Icons.auto_awesome_outlined),
                            ),
                            if (groupEnabled)
                              IconButton(
                                key: const Key('composer-group-button'),
                                tooltip: conversation.isGroup
                                    ? 'Group participants'
                                    : 'Start a group chat',
                                isSelected: _showGroupBar,
                                onPressed: () => _toggleGroupBar(state),
                                icon: const Icon(Icons.groups_outlined),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // The impersonate avatar sits alone on the left, so the send bar
              // stays a single row tall.
              _ImpersonateButton(
                persona: persona,
                onTap: () => _openImpersonatePicker(state),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const Key('composer-field'),
                  controller: _input,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    hintText:
                        persona == null ? 'Message' : 'Message as ${persona.displayName}',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // The operations button — a permanent home for per-chat actions,
              // grouped with Send on the right so it never adds height to the
              // send bar. Group chat is the first, and it shows whether or not
              // group chats are switched on.
              IconButton(
                key: const Key('composer-ops-button'),
                tooltip: 'More',
                visualDensity: VisualDensity.compact,
                isSelected: _showOps,
                onPressed: () => setState(() => _showOps = !_showOps),
                icon: const Icon(Icons.more_horiz),
              ),
              _sendButton(state),
            ],
          ),
        ],
      ),
    );
  }

  /// Toggles the group bar from the operations strip. When the thread is not yet
  /// a group, this opens the add sheet instead so there is something to show.
  void _toggleGroupBar(AppState state) {
    final conversation = state.active;
    if (!conversation.isGroup) {
      showGroupAddSheet(context, conversationId: conversation.id);
      setState(() => _showGroupBar = true);
      return;
    }
    setState(() => _showGroupBar = !_showGroupBar);
  }

  /// Opens the impersonation picker (search + character list) and, on a pick,
  /// confirms before switching the active identity.
  Future<void> _openImpersonatePicker(AppState state) async {
    final current = state.impersonationFor(state.active);
    final choice = await showModalBottomSheet<_ImpersonationChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ImpersonatePicker(
        characters: state.characters,
        currentId: current?.id,
      ),
    );
    if (choice == null || !mounted) return;

    if (choice.character == null) {
      // "Yourself" — clear any impersonation.
      if (current != null) {
        await state.setImpersonation(null);
        if (mounted) _toast('Impersonation cleared — back to yourself.');
      }
      return;
    }

    final character = choice.character!;
    final ok = await _confirm(
      title: 'Impersonate?',
      body: 'Do you want to impersonate ${character.displayName}? Your messages '
          'will be sent as this character.',
      action: 'Impersonate',
    );
    if (!ok || !mounted) return;
    await state.setImpersonation(character);
    if (mounted) _toast('Now impersonating ${character.displayName}.');
  }

  /// Doubles as the stop control while a reply is streaming.
  Widget _sendButton(AppState state) {
    final scheme = Theme.of(context).colorScheme;
    if (state.streaming) {
      return IconButton.filled(
        tooltip: 'Stop',
        onPressed: state.stop,
        style: IconButton.styleFrom(
          backgroundColor: scheme.error,
          foregroundColor: scheme.onError,
        ),
        icon: const Icon(Icons.stop),
      );
    }
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _input,
      builder: (context, value, _) => IconButton.filled(
        tooltip: 'Send',
        // A picture on its own is a message: Send stays live with an empty box
        // as long as something is attached.
        onPressed: value.text.trim().isEmpty && _attachments.isEmpty
            ? null
            : () => _send(state),
        icon: const Icon(Icons.arrow_upward),
      ),
    );
  }
}
// APPEND-MARKER-2

/// Which delete the reader picked in the confirmation — see [_deleteMessage].
enum _DeleteScope {
  /// The one turn they long-pressed, leaving what follows in place.
  thisMessage,

  /// That turn and every turn after it.
  fromHere,
}

/// A bubble already built, and the inputs it was built from.
///
/// A streaming reply repaints the chat about twenty times a second, and every
/// visible turn used to be rebuilt each time even though only the newest one had
/// changed — the cost of a repaint grew with how much of the conversation was on
/// screen. When nothing a bubble is drawn from has changed, handing back the
/// *same widget instance* lets Flutter skip that subtree outright (an identical
/// widget short-circuits `Element.updateChild`), so a repaint costs one bubble
/// instead of a screenful. Anything the bubble reads from its context — the
/// theme, the app state — still reaches it, because that path marks the element
/// itself dirty rather than going through its parent.
class _CachedBubble {
  const _CachedBubble(this.signature, this.widget);

  final List<Object?> signature;
  final Widget widget;
}

/// The composer's three "no typing needed" actions, as symbols in the operations
/// strip alongside the tools.
///
/// Symbols rather than labelled chips: three named chips took a row of their own
/// and wrapped onto a second line on a narrow phone, which is a lot of furniture
/// over the conversation for three occasional actions. The name is a long press
/// away on each — Material's own tooltip — and a tap just does the thing. Each is
/// offered only when it means something: nothing to continue in an empty chat,
/// and nothing at all while a reply is in flight.
class _TurnActions extends StatelessWidget {
  const _TurnActions({
    required this.busy,
    required this.canContinue,
    required this.canRespond,
    required this.onContinue,
    required this.onRespondAgain,
    required this.onWriteForMe,
  });

  final bool busy;
  final bool canContinue;
  final bool canRespond;
  final VoidCallback onContinue;
  final VoidCallback onRespondAgain;
  final VoidCallback onWriteForMe;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('turn-continue'),
          tooltip: 'Continue',
          icon: const Icon(Icons.fast_forward_outlined),
          onPressed: busy || !canContinue ? null : onContinue,
        ),
        IconButton(
          key: const Key('turn-respond-again'),
          tooltip: 'Respond again',
          icon: const Icon(Icons.add_comment_outlined),
          onPressed: busy || !canRespond ? null : onRespondAgain,
        ),
        IconButton(
          key: const Key('turn-write-for-me'),
          tooltip: 'Generate for me',
          icon: const Icon(Icons.edit_note_outlined),
          onPressed: busy ? null : onWriteForMe,
        ),
      ],
    );
  }
}

/// The composer's response-hint box: a line of steering for the reply that is
/// about to be written, sitting directly above the operations strip that opens
/// it.
///
/// A strip rather than a dialog, for the reason the attachment tray is one too —
/// what is about to be sent belongs beside the conversation it is being sent to,
/// not over it. The ✕ **closes** the box and nothing else: the hint keeps
/// steering every reply until it is erased, which is how Agnai's own response
/// hint behaves, so a sheet that looked like a one-off prompt would be a lie
/// about what it does.
///
/// Deliberately quiet: no heading, no symbol, no panel of its own. What the
/// reader sees is a **prompt box** — an outlined field with a ✕ beside it — over
/// whatever the chat's own background is, rather than a tinted card announcing a
/// mode being entered; the symbol in the strip it grows out of already says what
/// it is. Under the field sits where the hint lands, in as few words as it takes,
/// because that is a setting made somewhere else entirely.
class _HintBar extends StatelessWidget {
  const _HintBar({
    required this.controller,
    required this.depth,
    required this.onChanged,
    required this.onClose,
  });

  final TextEditingController controller;

  /// How many messages from the newest end the hint is injected at — the
  /// app-wide Chat Interface setting, echoed here so the box says what it does.
  final int depth;

  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faded = theme.colorScheme.onSurfaceVariant;
    return Container(
      key: const Key('hint-box'),
      width: double.infinity,
      // No fill and no frame of its own: the box is the field's own outline, and
      // behind it is the same background the rest of the chat has.
      margin: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              key: const Key('hint-field'),
              controller: controller,
              onChanged: onChanged,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.newline,
              keyboardType: TextInputType.multiline,
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                hintText: 'Guide the next reply…',
                isDense: true,
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                // Where the hint lands, as the field's own helper line — so it
                // lines up under the words it belongs to without a layout of its
                // own, and the box does not change height when the depth does.
                helperText: depth == 0
                    ? 'Just before the reply'
                    : '$depth ${depth == 1 ? 'message' : 'messages'} back',
                helperStyle: theme.textTheme.bodySmall
                    ?.copyWith(color: faded.withValues(alpha: 0.8)),
              ),
            ),
          ),
          IconButton(
            key: const Key('hint-close'),
            tooltip: 'Close',
            visualDensity: VisualDensity.compact,
            color: faded,
            onPressed: onClose,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

/// The composer's attachment tray: a strip that rises above the operations strip
/// showing exactly what is about to be sent — a **tall** band of thumbnails, each
/// with its own ✕ — over a row carrying the two places a picture can come from.
///
/// Deliberately a strip rather than a sheet: choosing a picture should not cover
/// the conversation it is being sent to, and the preview has to sit where the
/// message is being typed. The pictures go above the controls rather than below
/// them so that adding a fifth one grows the tray upwards, away from the thumb,
/// instead of pushing the composer around.
class _AttachBar extends StatelessWidget {
  const _AttachBar({
    required this.attachments,
    required this.onGallery,
    required this.onDevice,
    required this.onRemove,
    required this.onClose,
  });

  final List<MessageImage> attachments;
  final VoidCallback onGallery;
  final VoidCallback onDevice;
  final ValueChanged<int> onRemove;
  final VoidCallback onClose;

  /// Height of the picture band. Tall enough to actually see what is queued —
  /// the point of the preview — while leaving the thread visible above it.
  static const double _bandHeight = 116;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The tray belongs to the composer it grows out of, so it is drawn on the
    // theme's own raised surface — a step up from the send bar behind it, dark in
    // a dark theme and light in a light one. It used to be blended out of
    // `inverseSurface` to read like a photo strip, which inverts with the theme
    // rather than following it: in a dark theme that is a near-white tray, which
    // is what the app looked like it was doing wrong.
    final background = scheme.surfaceContainerHigh;
    final foreground = scheme.onSurfaceVariant;

    return Container(
      key: const Key('attach-tray'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 10, 4, 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (attachments.isNotEmpty)
            Padding(
              // Room on the right for a thumbnail's ✕, which hangs over its
              // corner, and clearance from the controls below.
              padding: const EdgeInsets.only(right: 8, bottom: 8),
              child: SizedBox(
                height: _bandHeight,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  // The ✕ sits outside the thumbnail; without the inset the first
                  // one is clipped by the list's own edge.
                  padding: const EdgeInsets.only(top: 6, right: 6),
                  itemCount: attachments.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => _AttachPreview(
                    image: attachments[i],
                    side: _bandHeight - 6,
                    onRemove: () => onRemove(i),
                  ),
                ),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: attachments.isEmpty
                    ? Row(
                        children: [
                          _AttachChoice(
                            key: const Key('attach-from-gallery'),
                            icon: Icons.photo_library_outlined,
                            label: 'From gallery',
                            onTap: onGallery,
                          ),
                          const SizedBox(width: 6),
                          _AttachChoice(
                            key: const Key('attach-from-device'),
                            icon: Icons.add_photo_alternate_outlined,
                            label: 'From device',
                            onTap: onDevice,
                          ),
                        ],
                      )
                    // Something is queued: one control to add to it, without
                    // leaving the tray.
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: _AttachChoice(
                          key: const Key('attach-another'),
                          icon: Icons.add,
                          label: 'Add',
                          onTap: onGallery,
                        ),
                      ),
              ),
              IconButton(
                tooltip: 'Close',
                visualDensity: VisualDensity.compact,
                color: foreground,
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One of the tray's two sources, as a tappable pill — an M3 tonal surface, so
/// it reads as a control on the tray it sits on in either theme.
class _AttachChoice extends StatelessWidget {
  const _AttachChoice({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = scheme.onSecondaryContainer;
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text(
                label,
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A thumbnail of a picture queued for the next send, with its own remove button.
class _AttachPreview extends StatelessWidget {
  const _AttachPreview({
    required this.image,
    required this.side,
    required this.onRemove,
  });

  final MessageImage image;

  /// Edge of the square thumbnail, set by the tray's band height.
  final double side;

  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final provider = avatarImage(
      image.ref,
      displaySize: side,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: side,
            height: side,
            // No picture to show: a plain themed tile, not a black one — this
            // stands in for the photograph rather than sitting on top of it.
            child: provider == null
                ? ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: Center(
                      child: Icon(Icons.broken_image_outlined,
                          size: 20, color: scheme.onSurfaceVariant),
                    ),
                  )
                : Image(image: provider, fit: BoxFit.cover),
          ),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: IconButton(
            tooltip: 'Remove',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            style: IconButton.styleFrom(
              backgroundColor: Colors.black54,
              foregroundColor: Colors.white,
            ),
            onPressed: onRemove,
            icon: const Icon(Icons.close),
          ),
        ),
      ],
    );
  }
}

/// The picture behind one chat, drawn edge to edge under the thread.
///
/// [opacity] is the point of the whole thing: a photograph at full strength
/// behind running text is unreadable, so the picture is faded towards whatever
/// the chat's background colour is. A reference that no longer resolves (the
/// file was swept, the URL went away) draws nothing rather than an error box.
class _ChatBackground extends StatelessWidget {
  const _ChatBackground({required this.image, required this.opacity});

  final String image;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final provider = avatarImage(
      image,
      displaySize: size.longestSide,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    if (provider == null) return const SizedBox.shrink();
    return RepaintBoundary(
      // Its own layer, so moving a floating picture over the chat re-records the
      // body's display list without re-rasterising this background every frame.
      child: IgnorePointer(
        // The fade is applied through Image's own `opacity` (a paint-level alpha
        // on the bitmap), NOT an `Opacity` widget — the widget forces an
        // offscreen save-layer for the whole full-screen image, which is the
        // expensive way to fade. Same look, cheaper to draw.
        child: Image(
          image: provider,
          fit: BoxFit.cover,
          opacity: AlwaysStoppedAnimation<double>(opacity.clamp(0.0, 1.0)),
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
    );
  }
}

/// The group participant bar shown above the composer: a fixed-height strip of
/// tappable character chips (tap to let that character speak, long-press to
/// remove), the impersonated "you" chip, and a persistent ✕ to hide it. Adding
/// a character is deliberately *not* here — that goes through the one flow that
/// owns it, Chat settings › Characters involved › +. Its height and background
/// come from the chat's [ChatInterface], so both are tunable app-wide and per
/// chat.
class _GroupBar extends StatelessWidget {
  const _GroupBar({
    required this.conversation,
    required this.participants,
    required this.user,
    required this.ui,
    required this.onChip,
    required this.onUser,
    required this.onRemove,
    required this.onResponder,
    required this.onClose,
  });

  final Conversation conversation;
  final List<Character> participants;
  final Character? user;
  final ChatInterface ui;
  final ValueChanged<String> onChip;
  final VoidCallback onUser;
  final ValueChanged<String> onRemove;

  /// Sets (or, when the tapped value is already current, clears) who replies
  /// automatically: a member's [Character.id] or [kGroupResponderRandom].
  final ValueChanged<String> onResponder;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = ui.groupBarColor != null
        ? Color(ui.groupBarColor!)
        : scheme.surfaceContainerHigh;
    final image = ui.groupBarImage == null
        ? null
        : avatarImage(ui.groupBarImage!, displaySize: 600, devicePixelRatio: 1);
    final responder = conversation.groupResponder;
    return Container(
      height: ui.groupBarHeight.clamp(kMinGroupBarHeight, kMaxGroupBarHeight),
      decoration: BoxDecoration(
        color: bg,
        image: image == null
            ? null
            : DecorationImage(image: image, fit: BoxFit.cover),
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (user != null)
                    _GroupChip(
                      label: user!.displayName,
                      character: user,
                      highlight: true,
                      onTap: onUser,
                    ),
                  for (final c in participants)
                    _GroupChip(
                      label: c.displayName,
                      character: c,
                      // Mark the member who now answers every send, so "from
                      // then on Bob replies" is visible at a glance.
                      responder: responder == c.id,
                      onTap: () => onChip(c.id),
                      onLongPress: () => onRemove(c.id),
                    ),
                ],
              ),
            ),
          ),
          _ResponderMenu(
            participants: participants,
            current: responder,
            onSelected: onResponder,
          ),
          IconButton(
            tooltip: 'Hide participants',
            onPressed: onClose,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

/// The participant bar's "who answers automatically" menu — a small popup of
/// 🎲 Random and each member, with a check on the current choice. Selecting the
/// current one again clears it (back to manual, nobody), which the parent
/// handles via [AppState.toggleGroupResponder].
class _ResponderMenu extends StatelessWidget {
  const _ResponderMenu({
    required this.participants,
    required this.current,
    required this.onSelected,
  });

  final List<Character> participants;
  final String? current;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget trailingCheck(bool on) => on
        ? Icon(Icons.check, size: 18, color: scheme.primary)
        : const SizedBox(width: 18);
    return PopupMenuButton<String>(
      tooltip: 'Auto-reply',
      icon: Icon(
        // A filled marker when someone is on auto, so the bar shows at a glance
        // that sends won't wait for a chip tap.
        current == null ? Icons.record_voice_over_outlined : Icons.record_voice_over,
        color: current == null ? null : scheme.primary,
      ),
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: kGroupResponderRandom,
          child: Row(
            children: [
              const Icon(Icons.casino_outlined, size: 20),
              const SizedBox(width: 12),
              const Expanded(child: Text('Random')),
              trailingCheck(current == kGroupResponderRandom),
            ],
          ),
        ),
        const PopupMenuDivider(),
        for (final c in participants)
          PopupMenuItem<String>(
            value: c.id,
            child: Row(
              children: [
                CharacterAvatar(character: c, radius: 10),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(c.displayName, overflow: TextOverflow.ellipsis),
                ),
                trailingCheck(current == c.id),
              ],
            ),
          ),
      ],
    );
  }
}

/// One chip in the [_GroupBar] — an avatar (or leading icon) with a name.
class _GroupChip extends StatelessWidget {
  const _GroupChip({
    required this.label,
    this.character,
    this.highlight = false,
    this.responder = false,
    required this.onTap,
    this.onLongPress,
  });

  final String label;
  final Character? character;
  final bool highlight;

  /// The member who answers every send: drawn with a primary outline and a
  /// small auto-reply glyph, distinct from the user chip's [highlight] fill.
  final bool responder;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget leading = character != null
        ? CharacterAvatar(character: character!, radius: 12)
        : Icon(Icons.person, size: 18, color: scheme.onSecondaryContainer);
    return Material(
      color: highlight
          ? scheme.primaryContainer
          : scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      shape: responder
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: scheme.primary, width: 1.5),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              leading,
              const SizedBox(width: 6),
              Text(label,
                  style: Theme.of(context).textTheme.labelLarge),
              if (responder) ...[
                const SizedBox(width: 6),
                Icon(Icons.record_voice_over, size: 15, color: scheme.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The lone bit of chat chrome: a small, semi-transparent **soft square** that
/// carries the menu icon. How visible it is comes from the chat's own interface
/// settings ([ChatInterface.menuButtonOpacity]) — translucent by default, so it
/// never boxes the conversation in.
class _ChatMenuButton extends StatelessWidget {
  const _ChatMenuButton({required this.onTap, required this.opacity});

  final VoidCallback onTap;

  /// 0..1, from the chat's interface settings.
  final double opacity;

  /// The corner radius that makes a 48-pixel square read as *soft* rather than
  /// as a box or as a circle.
  static const double _radius = 15;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final alpha = opacity.clamp(kMinChromeOpacity, kMaxChromeOpacity);
    // The opacity is folded into each colour rather than wrapped in an
    // `Opacity`, and the fill is a plain colour — deliberately **not** a
    // `BackdropFilter`. The frosted version re-ran a full backdrop blur, with a
    // framebuffer readback that stalls mobile GPUs, on *every composited frame*.
    // So it janked every drag, pinch and even a scroll for as long as they
    // produced frames — this button, always on screen, was the per-frame cost
    // behind the floating pictures never feeling smooth however cheap their own
    // painting became. Alpha in the colours reads the same at a glance and costs
    // nothing per frame, not even an offscreen layer.
    return Material(
      key: chatMenuButtonKey,
      color: scheme.surface.withValues(alpha: alpha),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(_radius)),
      ),
      elevation: 2,
      // The shadow fades with the button; a solid drop shadow under a barely
      // visible square is what gives a ghost button away.
      shadowColor: Colors.black.withValues(alpha: 0.3 * alpha),
      child: IconButton(
        tooltip: 'Menu',
        icon: Icon(Icons.menu, color: scheme.onSurface.withValues(alpha: alpha)),
        onPressed: onTap,
      ),
    );
  }
}

/// A small floating "jump to latest" affordance for the bottom-right of the
/// thread. It fades and scales in only when the conversation is scrolled well
/// above its newest message, so a deep scroll back doesn't have to be undone by
/// dragging. Tapping it glides straight to the last message. How visible it is
/// while shown is the chat's own [ChatInterface.jumpButtonOpacity].
class _JumpToLatestButton extends StatelessWidget {
  const _JumpToLatestButton({
    required this.visible,
    required this.onTap,
    required this.opacity,
    this.unread = 0,
    this.live = false,
  });

  final bool visible;
  final VoidCallback onTap;

  /// 0..1 while [visible], from the chat's interface settings.
  final double opacity;

  /// Turns that arrived while scrolled away; shown as a count badge when > 0.
  final int unread;

  /// Whether a reply is being written right now, out of sight below.
  final bool live;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedScale(
        scale: visible ? 1 : 0.6,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          // The setting rides the fade that was already here: showing the button
          // animates it to the reader's chosen opacity instead of to solid, and
          // hiding it still goes to nothing. The badge fades with the button —
          // half an unread marker over a solid arrow would read as a glitch.
          key: jumpToLatestKey,
          opacity: visible
              ? opacity.clamp(kMinChromeOpacity, kMaxChromeOpacity)
              : 0,
          duration: const Duration(milliseconds: 160),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              FloatingActionButton.small(
                heroTag: null,
                tooltip:
                    live ? 'A reply is coming in — jump to it' : 'Jump to latest',
                elevation: 2,
                backgroundColor: live
                    ? scheme.primaryContainer
                    : scheme.secondaryContainer,
                foregroundColor: live
                    ? scheme.onPrimaryContainer
                    : scheme.onSecondaryContainer,
                onPressed: onTap,
                child: const Icon(Icons.arrow_downward),
              ),
              // A response arrived while the reader was up-thread: a small red
              // count badge on the button, the familiar chat unread marker.
              if (unread > 0)
                Positioned(
                  top: -4,
                  right: -4,
                  child: Container(
                    constraints:
                        const BoxConstraints(minWidth: 18, minHeight: 18),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(
                      color: scheme.error,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: scheme.surface, width: 1.5),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      style: TextStyle(
                        color: scheme.onError,
                        fontSize: 11,
                        height: 1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Which face the chat sidebar is showing: its menu, or one of the panels that
/// live *inside* the drawer. They replace the menu rather than being pushed as
/// routes, so backing out of one returns to the menu with the drawer still open.
enum _DrawerPanel { menu, presets, memory }
/// The chat sidebar. Mirrors agnai's chat menu: an editable chat title on top,
/// jumps to the other sections, provider/model, and a utility row of chat
/// actions (settings, image gen, export, restart, delete, notifications).
/// "Preset" and "Memory" open in-drawer panels rather than navigating away.
class _ChatDrawer extends StatefulWidget {
  const _ChatDrawer({
    required this.onProfile,
    required this.onCharacters,
    required this.onChats,
    required this.onGallery,
    required this.onEditChat,
    required this.onChatGraph,
    required this.onProviderModel,
    required this.onSettings,
    required this.onImageGen,
    required this.onExport,
    required this.onRestart,
    required this.onDelete,
    required this.onNotifications,
  });

  final VoidCallback onProfile;
  final VoidCallback onCharacters;
  final VoidCallback onChats;
  final VoidCallback onGallery;
  final VoidCallback onEditChat;
  final VoidCallback onChatGraph;
  final VoidCallback onProviderModel;
  final VoidCallback onSettings;
  final VoidCallback onImageGen;
  final VoidCallback onExport;
  final VoidCallback onRestart;
  final VoidCallback onDelete;
  final VoidCallback onNotifications;

  @override
  State<_ChatDrawer> createState() => _ChatDrawerState();
}

class _ChatDrawerState extends State<_ChatDrawer> {
  _DrawerPanel _panel = _DrawerPanel.menu;

  /// Which way the last panel change drilled — into a sub-panel (true) or back
  /// to the menu (false) — so the switch slides in the matching direction.
  bool _forward = true;

  /// Runs [action] after the drawer has closed, so the drawer does not sit
  /// open behind whatever the action pushes or shows.
  void _close(BuildContext context, VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }

  void _show(_DrawerPanel panel) => setState(() {
        _forward = panel != _DrawerPanel.menu;
        _panel = panel;
      });

  @override
  Widget build(BuildContext context) {
    final Widget body;
    switch (_panel) {
      case _DrawerPanel.presets:
        body = ChatPresetPanel(onBack: () => _show(_DrawerPanel.menu));
      case _DrawerPanel.memory:
        body = ChatMemoryPanel(onBack: () => _show(_DrawerPanel.menu));
      case _DrawerPanel.menu:
        body = _menu(context);
    }

    // Slide + fade between the menu and a sub-panel so drilling in/out reads as
    // one fluid movement instead of a hard cut. StackFit.expand hands each child
    // the drawer's full, bounded size — the panels are Columns with Expanded, so
    // an unconstrained Stack child would otherwise overflow.
    return Drawer(
      child: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            final incoming = child.key == ValueKey(_panel);
            final dir = _forward ? 1.0 : -1.0;
            final begin = Offset((incoming ? dir : -dir) * 0.12, 0);
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(begin: begin, end: Offset.zero)
                    .animate(animation),
                child: child,
              ),
            );
          },
          layoutBuilder: (currentChild, previousChildren) => Stack(
            fit: StackFit.expand,
            alignment: Alignment.topCenter,
            children: [
              ...previousChildren,
              ?currentChild,
            ],
          ),
          child: KeyedSubtree(key: ValueKey(_panel), child: body),
        ),
      ),
    );
  }

  Widget _menu(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final conversation = state.active;
    final active = state.activeProvider;
    final model = active?.model.trim() ?? '';
    final providerSubtitle = active == null
        ? 'No provider yet'
        : '${active.displayName}${model.isEmpty ? '' : ' · $model'}';
    final presetName = state.presetFor(conversation)?.displayName ?? 'Default';
    // How much memory this chat is carrying, so the user can see it without
    // opening the panel. Resolved through AppState so a deleted book is not
    // counted.
    final memoryCount = state.lorebooksFor(conversation).length;
    final memorySubtitle =
        memoryCount == 0 ? 'None' : '$memoryCount active';
    // How many chats are in this one's fork tree, so the drawer says whether
    // there is a graph worth opening before the user taps.
    final treeSize =
        buildFamilyTree(state.conversations, conversation.id)?.subtreeSize ?? 1;
    final graphSubtitle = treeSize <= 1
        ? 'No branches'
        : '$treeSize chats · ${treeSize - 1} '
            '${treeSize == 2 ? 'branch' : 'branches'}';

    return Column(
          children: [
            // Editable chat title, like agnai's "edit character" header.
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: InkWell(
                onTap: () => _close(context, widget.onEditChat),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined, size: 18, color: scheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          conversation.isEmpty ? 'New chat' : conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                children: [
                  _ChatNavItem(
                    icon: Icons.person_outline,
                    label: 'Profile',
                    onTap: () => _close(context, widget.onProfile),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: _BackNavButton(
                            label: 'Characters',
                            onTap: () => _close(context, widget.onCharacters),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _BackNavButton(
                            label: 'Chats',
                            onTap: () => _close(context, widget.onChats),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _ChatNavItem(
                    icon: Icons.photo_library_outlined,
                    label: 'Gallery',
                    onTap: () => _close(context, widget.onGallery),
                  ),
                  _ChatNavItem(
                    icon: Icons.edit_note_outlined,
                    label: 'Edit Chat',
                    onTap: () => _close(context, widget.onEditChat),
                  ),
                  _ChatNavItem(
                    icon: Icons.tune_outlined,
                    label: 'Preset',
                    subtitle: presetName,
                    onTap: () => _show(_DrawerPanel.presets),
                  ),
                  _ChatNavItem(
                    icon: Icons.book_outlined,
                    label: 'Memory',
                    subtitle: memorySubtitle,
                    onTap: () => _show(_DrawerPanel.memory),
                  ),
                  _ChatNavItem(
                    icon: Icons.account_tree_outlined,
                    label: 'Chat Graph',
                    subtitle: graphSubtitle,
                    onTap: () => _close(context, widget.onChatGraph),
                  ),
                  const SizedBox(height: 4),
                  _ChatNavItem(
                    icon: Icons.dns_outlined,
                    label: 'Provider & model',
                    subtitle: providerSubtitle,
                    onTap: () => _close(context, widget.onProviderModel),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            _ChatDrawerFooter(
              onSettings: () => _close(context, widget.onSettings),
              onImageGen: () => _close(context, widget.onImageGen),
              onExport: () => _close(context, widget.onExport),
              onRestart: () => _close(context, widget.onRestart),
              onDelete: () => _close(context, widget.onDelete),
              onNotifications: () => _close(context, widget.onNotifications),
            ),
          ],
        );
  }
}
// APPEND-MARKER-3

/// A single rounded destination in the chat sidebar, optionally with a quiet
/// second line (used to show the active provider and model).
class _ChatNavItem extends StatelessWidget {
  const _ChatNavItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        leading: Icon(icon, color: scheme.onSurfaceVariant),
        title: Text(
          label,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w500),
        ),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onTap: onTap,
      ),
    );
  }
}

/// One half of the "← Characters / ← Chats" back-navigation pair.
class _BackNavButton extends StatelessWidget {
  const _BackNavButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.chevron_left, size: 18),
      label: Text(label, overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

/// The utility strip pinned to the bottom of the chat sidebar: icon-only chat
/// actions, echoing agnai's footer row.
class _ChatDrawerFooter extends StatelessWidget {
  const _ChatDrawerFooter({
    required this.onSettings,
    required this.onImageGen,
    required this.onExport,
    required this.onRestart,
    required this.onDelete,
    required this.onNotifications,
  });

  final VoidCallback onSettings;
  final VoidCallback onImageGen;
  final VoidCallback onExport;
  final VoidCallback onRestart;
  final VoidCallback onDelete;
  final VoidCallback onNotifications;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Wrap(
        alignment: WrapAlignment.spaceEvenly,
        children: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: onSettings,
          ),
          IconButton(
            tooltip: 'Image generation',
            icon: const Icon(Icons.add_photo_alternate_outlined),
            onPressed: onImageGen,
          ),
          IconButton(
            tooltip: 'Export chat',
            icon: const Icon(Icons.download_outlined),
            onPressed: onExport,
          ),
          IconButton(
            tooltip: 'Restart chat',
            icon: const Icon(Icons.restart_alt),
            onPressed: onRestart,
          ),
          IconButton(
            tooltip: 'Delete chat',
            icon: Icon(Icons.delete_outline, color: scheme.error),
            onPressed: onDelete,
          ),
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_outlined),
            onPressed: onNotifications,
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.configured, required this.onSettings});

  final bool configured;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              configured ? Icons.forum_outlined : Icons.key_outlined,
              size: 44,
              color: scheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              configured
                  ? 'Say something to get started.'
                  : 'Add a provider with a model to start chatting.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            if (!configured) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: onSettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Open settings'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
// APPEND-MARKER-4

/// The chat-screen quick picker: switch the active provider and choose its
/// model without leaving the conversation. "Manage providers" drops into the
/// full settings for adding, editing or deleting.
class _QuickSettingsSheet extends StatefulWidget {
  const _QuickSettingsSheet({required this.onManage});

  final VoidCallback onManage;

  @override
  State<_QuickSettingsSheet> createState() => _QuickSettingsSheetState();
}

class _QuickSettingsSheetState extends State<_QuickSettingsSheet> {
  Future<void> _browseModels(AppState state, Provider active) async {
    final chosen = await showSearchPicker(
      context: context,
      title: 'Choose model',
      entries: [
        for (final m in state.cachedModels(active.id)) PickerEntry(id: m, title: m),
      ],
      selectedId: active.model.trim(),
      allowCustom: true,
      onRefresh: () async {
        try {
          final models = await state.refreshModels(active);
          return [for (final m in models) PickerEntry(id: m, title: m)];
        } on ChatApiException catch (e) {
          throw PickerRefreshException(e.message);
        }
      },
      refreshOnEmpty: state.cachedModels(active.id).isEmpty,
    );
    if (chosen == null || !mounted) return;
    await state.setActiveModel(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final providers = state.providers;
    final active = state.activeProvider;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                'Provider',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (providers.isEmpty)
              const ListTile(
                leading: Icon(Icons.dns_outlined),
                title: Text('No providers yet'),
                subtitle: Text('Add one to start chatting'),
              )
            else
              Flexible(
                child: RadioGroup<String>(
                  groupValue: active?.id,
                  onChanged: (id) {
                    if (id != null) state.selectProvider(id);
                  },
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final provider in providers)
                        RadioListTile<String>(
                          value: provider.id,
                          title: Text(
                            provider.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            provider.kind.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            const Divider(height: 1),
            if (active != null)
              ListTile(
                leading: const Icon(Icons.memory_outlined),
                title: const Text('Model'),
                subtitle: Text(
                  active.model.trim().isEmpty ? 'None selected' : active.model,
                ),
                trailing: const Icon(Icons.expand_more),
                onTap: () => _browseModels(state, active),
              ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Manage providers'),
              onTap: widget.onManage,
            ),
          ],
        ),
      ),
    );
  }
}

/// The small circular avatar on the far left of the composer. Shows the
/// impersonated character's picture when the user has assumed an identity,
/// otherwise a plain person glyph. Tapping it opens the impersonation picker.
class _ImpersonateButton extends StatelessWidget {
  const _ImpersonateButton({required this.persona, required this.onTap});

  final Character? persona;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const double diameter = 40;
    final impersonating = persona != null;
    return Tooltip(
      message: impersonating
          ? 'Impersonating ${persona!.displayName}'
          : 'Impersonate a character',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: impersonating ? scheme.primary : scheme.outlineVariant,
              width: impersonating ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: impersonating
              ? CharacterAvatar(character: persona!, size: diameter)
              : Icon(Icons.person_outline,
                  color: scheme.onSurfaceVariant, size: 22),
        ),
      ),
    );
  }
}

/// The result of the impersonation picker: a chosen character, or a null
/// character meaning "be yourself" (clear impersonation).
class _ImpersonationChoice {
  const _ImpersonationChoice(this.character);
  final Character? character;
}

/// A bottom sheet to pick who to impersonate: a search field over a scrollable
/// list of saved characters, plus a "Yourself" entry at the top to step back
/// out of any active impersonation.
class _ImpersonatePicker extends StatefulWidget {
  const _ImpersonatePicker({required this.characters, this.currentId});

  final List<Character> characters;
  final String? currentId;

  @override
  State<_ImpersonatePicker> createState() => _ImpersonatePickerState();
}

class _ImpersonatePickerState extends State<_ImpersonatePicker> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Character> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.characters;
    return widget.characters
        .where((c) =>
            c.name.toLowerCase().contains(q) ||
            c.blurb.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.viewInsetsOf(context).bottom +
        MediaQuery.paddingOf(context).bottom;
    final results = _visible;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Text('Impersonate',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _search,
                autofocus: false,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Search characters',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.secondaryContainer,
                      child: Icon(Icons.person_outline,
                          color: scheme.onSecondaryContainer),
                    ),
                    title: const Text('Yourself'),
                    subtitle: const Text('Stop impersonating'),
                    trailing: widget.currentId == null
                        ? Icon(Icons.check, color: scheme.primary)
                        : null,
                    onTap: () => Navigator.of(context)
                        .pop(const _ImpersonationChoice(null)),
                  ),
                  if (widget.characters.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: Text('No characters yet — import or create one '
                            'to impersonate.'),
                      ),
                    )
                  else if (results.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('No characters match that')),
                    )
                  else
                    for (final c in results)
                      ListTile(
                        leading: CharacterAvatar(character: c, radius: 20),
                        title: Text(c.displayName,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: c.blurb.isEmpty
                            ? null
                            : Text(c.blurb,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: widget.currentId == c.id
                            ? Icon(Icons.check, color: scheme.primary)
                            : null,
                        onTap: () => Navigator.of(context)
                            .pop(_ImpersonationChoice(c)),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}


