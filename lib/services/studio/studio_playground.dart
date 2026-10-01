import '../../models/character.dart';
import '../../models/conversation.dart';
import '../../models/lorebook.dart';
import '../../models/studio.dart';
import '../../models/studio_revisions.dart';
import '../../state/app_state.dart';
import 'studio_controller.dart';

/// The Studio's Playground as a [ChatHost]: the session's playtests, each a
/// real chat with the draft, shown in the app's own chat screen.
///
/// - **Where the chats live:** in the session file, as [StudioPlaytest.chat] —
///   never in the app's `conversations` entry, so they are in no chat list,
///   go wherever the session goes, and are gone with it when it is deleted.
///   Applying the draft leaves them where they are.
/// - **Who the character is:** the draft, as it stands. [character] hands the
///   chat screen and the prompt a copy of the workspace's character taken at
///   the current [StudioSession.draftVersion], so an edit (by an agent, by
///   hand, or a rewind) is what the next reply is written from — and a copy,
///   so nothing the chat does (its own per-chat definitions, an avatar pool)
///   writes into the draft behind the Studio's back.
class StudioPlayground implements ChatHost {
  StudioPlayground(this.controller) {
    controller.addListener(_onController);
  }

  final StudioController controller;

  StudioSession get session => controller.session;
  AppState get state => controller.state;

  /// The playtests newest first, and what they were when the list was taken.
  List<StudioPlaytest>? _sorted;
  int _sortedLength = -1;
  StudioPlaytest? _sortedLast;

  /// The copy of the draft the chats see, and which version it was taken at.
  Character? _character;
  final Map<String, Lorebook> _books = <String, Lorebook>{};
  int _version = -1;
  StudioWorkspace? _workspace;

  /// What the attached chat screen last saw: the draft's version and how long
  /// the chat on screen was.
  int _seenVersion = -1;
  int _seenLength = -1;

  /// The playtests, newest first: what the Playground's drawer lists.
  List<StudioPlaytest> get playtests {
    final all = session.playtests;
    if (_sorted == null ||
        _sortedLength != all.length ||
        !identical(_sortedLast, all.isEmpty ? null : all.last)) {
      _sorted = all.reversed.toList(growable: false);
      _sortedLength = all.length;
      _sortedLast = all.isEmpty ? null : all.last;
    }
    return _sorted!;
  }

  /// The playtest whose chat is [chatId].
  StudioPlaytest? playtestFor(String chatId) {
    for (final p in session.playtests) {
      if (p.chat.id == chatId) return p;
    }
    return null;
  }

  @override
  List<Conversation> get chats {
    _refresh();
    final draft = session.workspace.character;
    return [
      for (final p in playtests) _bind(p.chat, draft),
    ];
  }

  /// Every chat here is a chat with the draft. An agent's playtest is filed
  /// without one named, and the draft can be renamed: both are settled here.
  Conversation _bind(Conversation chat, Character draft) {
    if (chat.characterId != draft.id ||
        chat.characterName != draft.displayName) {
      chat
        ..characterId = draft.id
        ..characterName = draft.displayName;
    }
    return chat;
  }

  /// Takes a fresh copy of the draft when it has changed since the last one.
  void _refresh() {
    final ws = session.workspace;
    if (_version == session.draftVersion && identical(_workspace, ws)) return;
    _version = session.draftVersion;
    _workspace = ws;
    final copy = ws.character.clone();
    _character = copy;
    _books
      ..clear()
      ..addEntries(ws.lorebooks.map((b) => MapEntry(b.id, b.copyWith())));
    // The stored persona is what a chat with no preset (or a card that has
    // gone) sends; it follows the draft too.
    final persona = copy.composedSystemPrompt();
    for (final p in session.playtests) {
      p.chat.systemPrompt = persona;
    }
  }

  @override
  Character? character(String id) {
    _refresh();
    final c = _character;
    return c != null && c.id == id ? c : null;
  }

  @override
  Lorebook? lorebook(String id) {
    _refresh();
    return _books[id];
  }

  /// A hosted chat's avatar action is a hand edit of the draft: it shows in
  /// Changes, can be rewound, and reaches the library only when applied.
  @override
  void editCharacter(
    String id,
    String summary,
    void Function(Character c) change,
  ) {
    if (session.workspace.character.id != id) return;
    controller.editByHand(summary, (ws) => change(ws.character));
  }

  /// Starts a chat of the user's with the draft, opening on its greeting
  /// [greetingIndex], the way any new chat with a character starts.
  StudioPlaytest startChat({int greetingIndex = 0}) {
    _refresh();
    final stamp = '${DateTime.now().microsecondsSinceEpoch}';
    final chat = state.newChatWith(
      _character ?? session.workspace.character,
      id: '$kHostedChatPrefix$stamp',
    );
    if (chat.messages.isNotEmpty && greetingIndex > 0) {
      chat.messages[0] = chat.messages[0].withSwipe(greetingIndex);
    }
    final test = StudioPlaytest(
      id: stamp,
      by: kUserEditor,
      greetingIndex: chat.messages.isEmpty ? 0 : chat.messages[0].swipeIndex,
      chat: chat,
    );
    session.addPlaytest(test);
    controller.playgroundChanged();
    return test;
  }

  @override
  Conversation newChat() => startChat().chat;

  @override
  void adopt(Conversation chat) {
    final id = chat.id.startsWith(kHostedChatPrefix)
        ? chat.id.substring(kHostedChatPrefix.length)
        : chat.id;
    session.addPlaytest(StudioPlaytest(
      id: id,
      by: kUserEditor,
      title: chat.title,
      chat: chat,
    ));
    controller.playgroundChanged();
  }

  @override
  void remove(String id) {
    session.playtests.removeWhere((p) => p.chat.id == id);
    controller.playgroundChanged();
  }

  /// Files chats read from a file (any format the app imports) as the user's
  /// chats with the draft — the Playground's Import. A system prompt the file
  /// carried is kept under the draft's persona, as an import into the app's
  /// list keeps it under the character's.
  void importChats(List<Conversation> imported) {
    _refresh();
    final persona = (_character ?? session.workspace.character)
        .composedSystemPrompt();
    final base = DateTime.now().microsecondsSinceEpoch;
    for (var i = 0; i < imported.length; i++) {
      final stamp = '${base + i}';
      final extra = imported[i].systemPrompt.trim();
      final chat = imported[i].copyAs(id: '$kHostedChatPrefix$stamp')
        ..systemPrompt = extra.isEmpty ? persona : '$persona\n\n$extra';
      session.addPlaytest(StudioPlaytest(
        id: stamp,
        by: kUserEditor,
        title: chat.title,
        chat: chat,
      ));
    }
    controller.playgroundChanged();
  }

  @override
  void save() => controller.playgroundChanged();

  /// Shows the Playground's chat [chatId] — or its newest, or a new one when
  /// it has none — in the chat screen.
  String open([String? chatId]) {
    var id = chatId;
    // Coming back to the Playground finds the chat it was left on.
    if (id == null && identical(state.chatHost, this)) id = state.hostedChatId;
    if (id == null || playtestFor(id) == null) {
      id = playtests.isEmpty ? startChat().chat.id : playtests.first.chat.id;
    }
    state.hostChats(this, id);
    _seenVersion = session.draftVersion;
    _seenLength = state.active.messages.length;
    return id;
  }

  /// Hands the chat screen back to the app's own chats.
  void close() => state.leaveHostedChats(this);

  /// The draft changing, or an agent's playtest growing the chat on screen,
  /// is news to the chat screen, which listens to the app and not to the
  /// Studio. Told once per change, never per streamed word.
  void _onController() {
    if (!identical(state.chatHost, this)) return;
    final version = session.draftVersion;
    final length = state.active.messages.length;
    if (version == _seenVersion && length == _seenLength) return;
    _seenVersion = version;
    _seenLength = length;
    state.hostedChatsChanged();
  }

  void dispose() {
    controller.removeListener(_onController);
    close();
  }
}
