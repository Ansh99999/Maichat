import 'package:flutter/foundation.dart';

import '../models/appearance.dart';
import '../models/character.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../models/provider.dart';
import '../services/chat_client.dart';
import '../services/storage.dart';

/// Single source of truth for providers, threads and the in-flight reply.
class AppState extends ChangeNotifier {
  AppState({Storage? storage, ChatClient? client})
      : _storage = storage ?? Storage(),
        _client = client ?? ChatClient();

  final Storage _storage;
  final ChatClient _client;

  final List<Conversation> _conversations = <Conversation>[];
  final List<Provider> _providers = <Provider>[];
  final List<Character> _characters = <Character>[];
  String? _activeProviderId;
  Appearance _appearance = const Appearance();
  String? _activeId;
  bool _ready = false;
  bool _streaming = false;
  bool _stopRequested = false;

  List<Conversation> get conversations => List.unmodifiable(_conversations);
  List<Provider> get providers => List.unmodifiable(_providers);
  List<Character> get characters => List.unmodifiable(_characters);
  Appearance get appearance => _appearance;
  bool get ready => _ready;
  bool get streaming => _streaming;

  /// The provider chat and model listing talk to, or null when none is set up.
  Provider? get activeProvider {
    final id = _activeProviderId;
    if (id != null) {
      for (final provider in _providers) {
        if (provider.id == id) return provider;
      }
    }
    return _providers.isEmpty ? null : _providers.first;
  }

  /// Whether there is an active provider ready to send.
  bool get isConfigured => activeProvider?.isConfigured ?? false;


  /// The visible thread, creating one on first run.
  Conversation get active {
    final id = _activeId;
    if (id != null) {
      for (final conversation in _conversations) {
        if (conversation.id == id) return conversation;
      }
    }
    if (_conversations.isEmpty) {
      final fresh = Conversation.empty();
      _conversations.add(fresh);
      _activeId = fresh.id;
      return fresh;
    }
    _activeId = _conversations.first.id;
    return _conversations.first;
  }

  Future<void> init() async {
    final providerState = await _storage.loadProviders();
    _providers
      ..clear()
      ..addAll(providerState.providers);
    _activeProviderId = providerState.activeId;
    _appearance = await _storage.loadAppearance();
    _characters
      ..clear()
      ..addAll(await _storage.loadCharacters());
    final stored = await _storage.loadConversations()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _conversations
      ..clear()
      ..addAll(stored);
    _activeId = await _storage.loadActiveId();
    _ready = true;
    notifyListeners();
  }

  Future<void> _persistProviders() =>
      _storage.saveProviders(ProviderState(_providers, _activeProviderId));

  /// Adds [provider] and makes it the active one.
  Future<void> addProvider(Provider provider) async {
    _providers.add(provider);
    _activeProviderId = provider.id;
    notifyListeners();
    await _persistProviders();
  }

  /// Replaces the stored provider that shares [provider]'s id.
  Future<void> updateProvider(Provider provider) async {
    final index = _providers.indexWhere((p) => p.id == provider.id);
    if (index == -1) return;
    _providers[index] = provider;
    notifyListeners();
    await _persistProviders();
  }

  /// Removes a provider, moving the active pointer to another if it was active.
  Future<void> deleteProvider(String id) async {
    _providers.removeWhere((p) => p.id == id);
    if (_activeProviderId == id) {
      _activeProviderId = _providers.isEmpty ? null : _providers.first.id;
    }
    notifyListeners();
    await _persistProviders();
  }

  Future<void> selectProvider(String id) async {
    if (_activeProviderId == id) return;
    _activeProviderId = id;
    notifyListeners();
    await _persistProviders();
  }

  /// Sets the model on the active provider — the quick-switch path.
  Future<void> setActiveModel(String model) async {
    final active = activeProvider;
    if (active == null) return;
    await updateProvider(active.copyWith(model: model));
  }

  Future<void> updateAppearance(Appearance next) async {
    if (next == _appearance) return;
    _appearance = next;
    notifyListeners();
    await _storage.saveAppearance(next);
  }

  // --- Characters ----------------------------------------------------------

  Future<void> _persistCharacters() => _storage.saveCharacters(_characters);

  Character? characterById(String? id) {
    if (id == null) return null;
    for (final c in _characters) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Adds [character] to the top of the roster.
  Future<void> addCharacter(Character character) async {
    _characters.insert(0, character);
    notifyListeners();
    await _persistCharacters();
  }

  /// Adds several characters at once (bulk import), newest first, persisting
  /// once.
  Future<void> addCharacters(List<Character> characters) async {
    if (characters.isEmpty) return;
    _characters.insertAll(0, characters);
    notifyListeners();
    await _persistCharacters();
  }

  /// Replaces the stored character sharing [character]'s id, or adds it when
  /// there is no match yet.
  Future<void> saveCharacter(Character character) async {
    character.updatedAt = DateTime.now();
    final index = _characters.indexWhere((c) => c.id == character.id);
    if (index == -1) {
      _characters.insert(0, character);
    } else {
      _characters[index] = character;
    }
    notifyListeners();
    await _persistCharacters();
  }

  Future<void> deleteCharacter(String id) async {
    _characters.removeWhere((c) => c.id == id);
    notifyListeners();
    await _persistCharacters();
  }

  /// Flips a character's starred flag — the pin-to-top action.
  Future<void> toggleCharacterStar(String id) async {
    final character = characterById(id);
    if (character == null) return;
    character.starred = !character.starred;
    character.updatedAt = DateTime.now();
    notifyListeners();
    await _persistCharacters();
  }

  /// Copies a character under a new id and "(copy)" name — the duplicate action.
  Future<Character> duplicateCharacter(Character character) async {
    final copy = character.copyWith(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: '${character.displayName} (copy)',
    );
    await addCharacter(copy);
    return copy;
  }

  /// Opens a fresh thread bound to [character]: titles it after the character,
  /// stores the composed persona as the thread's (invisible) system prompt, and
  /// seeds the resolved greeting as the opening assistant turn when there is one.
  /// Returns the new conversation's id so the caller can navigate to it.
  String startChatWithCharacter(Character character) {
    final conversation = Conversation.empty()
      ..title = character.displayName
      ..characterId = character.id
      ..characterName = character.displayName
      ..systemPrompt = character.composedSystemPrompt();
    final greeting = character.resolvedGreeting();
    if (greeting.isNotEmpty) {
      conversation.messages.add(ChatMessage(role: 'assistant', content: greeting));
    }
    _conversations.insert(0, conversation);
    _activeId = conversation.id;
    notifyListeners();
    _storage
      ..saveActiveId(conversation.id)
      ..saveConversations(_conversations);
    return conversation.id;
  }

  /// Opens a fresh thread, reusing an existing empty one so repeated taps do
  /// not pile up blank entries.
  void newConversation() {
    final existing =
        _conversations.where((c) => c.isEmpty).cast<Conversation?>().firstWhere(
              (c) => true,
              orElse: () => null,
            );
    final target = existing ?? Conversation.empty();
    if (existing == null) _conversations.insert(0, target);
    _activeId = target.id;
    notifyListeners();
    _storage.saveActiveId(target.id);
  }

  void selectConversation(String id) {
    _activeId = id;
    notifyListeners();
    _storage.saveActiveId(id);
  }

  /// Renames a thread and persists it — the "edit chat" action.
  Future<void> renameConversation(String id, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    for (final conversation in _conversations) {
      if (conversation.id == id) {
        conversation.title = trimmed;
        conversation.updatedAt = DateTime.now();
        break;
      }
    }
    notifyListeners();
    await _storage.saveConversations(_conversations);
  }

  /// Empties the active thread but keeps it around — the "restart chat"
  /// action. Any in-flight reply is aborted first.
  Future<void> restartConversation() async {
    if (_streaming) stop();
    final conversation = active;
    conversation.messages.clear();
    // A character thread keeps its identity and re-seeds the greeting; a plain
    // thread resets to an untitled one.
    if (conversation.hasCharacter) {
      final character = characterById(conversation.characterId);
      if (character != null) {
        final greeting = character.resolvedGreeting();
        if (greeting.isNotEmpty) {
          conversation.messages
              .add(ChatMessage(role: 'assistant', content: greeting));
        }
      }
    } else {
      conversation.title = 'New chat';
    }
    conversation.updatedAt = DateTime.now();
    notifyListeners();
    await _storage.saveConversations(_conversations);
  }

  Future<void> deleteConversation(String id) async {
    if (id == active.id && _streaming) stop();
    _conversations.removeWhere((c) => c.id == id);
    if (_activeId == id) _activeId = null;
    notifyListeners();
    await _storage.saveConversations(_conversations);
  }

  /// Sends [text] and streams the reply into a placeholder turn.
  Future<void> send(String text) async {
    final prompt = text.trim();
    if (prompt.isEmpty || _streaming) return;
    final provider = activeProvider;
    if (provider == null) return;

    final conversation = active;
    if (conversation.isEmpty) conversation.retitleFrom(prompt);
    conversation.messages.add(ChatMessage(role: 'user', content: prompt));
    // A character thread runs under its composed persona, sent as a leading
    // system turn. Failure notices are display-only, so they never go back.
    final history = <ChatMessage>[
      if (conversation.systemPrompt.trim().isNotEmpty)
        ChatMessage(role: 'system', content: conversation.systemPrompt.trim()),
      ...conversation.messages.where((m) => !m.error),
    ];
    conversation.messages.add(ChatMessage(role: 'assistant', content: ''));
    conversation.updatedAt = DateTime.now();
    _moveToTop(conversation);
    _streaming = true;
    _stopRequested = false;
    notifyListeners();

    final reply = StringBuffer();
    try {
      final deltas =
          _client.streamChat(provider: provider, history: history);
      await for (final delta in deltas) {
        reply.write(delta);
        _replaceLast(conversation, content: reply.toString());
        notifyListeners();
      }
      if (reply.isEmpty) {
        _replaceLast(
          conversation,
          content: 'The model returned an empty response.',
          error: true,
        );
      }
    } on ChatApiException catch (e) {
      if (_stopRequested) {
        _finishStopped(conversation, reply.toString());
      } else {
        _replaceLast(conversation, content: e.message, error: true);
      }
    } finally {
      _streaming = false;
      _stopRequested = false;
      conversation.updatedAt = DateTime.now();
      notifyListeners();
      await _storage.saveConversations(_conversations);
    }
  }

  /// Aborts streaming and keeps whatever text already arrived.
  void stop() {
    if (!_streaming) return;
    _stopRequested = true;
    _client.cancel();
  }

  /// Lists models for [provider], or the active provider when omitted.
  Future<List<String>> fetchModels([Provider? provider]) {
    final target = provider ?? activeProvider;
    if (target == null) {
      throw ChatApiException('Add a provider first.');
    }
    return _client.listModels(target);
  }

  void _replaceLast(
    Conversation conversation, {
    required String content,
    bool error = false,
  }) {
    if (conversation.messages.isEmpty) return;
    final last = conversation.messages.last;
    conversation.messages[conversation.messages.length - 1] =
        last.copyWith(content: content, error: error);
  }

  /// A stop with no text yet leaves nothing worth keeping.
  void _finishStopped(Conversation conversation, String partial) {
    if (partial.trim().isEmpty) {
      if (conversation.messages.isNotEmpty) conversation.messages.removeLast();
      return;
    }
    _replaceLast(conversation, content: partial);
  }

  void _moveToTop(Conversation conversation) {
    _conversations.remove(conversation);
    _conversations.insert(0, conversation);
  }

  @override
  void dispose() {
    _client.cancel();
    super.dispose();
  }
}
