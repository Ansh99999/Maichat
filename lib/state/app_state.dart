import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../app_info.dart';
import '../models/appearance.dart';
import '../models/character.dart';
import '../models/chat_interface.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../models/preset.dart';
import '../models/prompt_block.dart';
import '../models/provider.dart';
import '../services/chat_client.dart';
import '../services/macro_context.dart';
import '../services/macro_engine.dart';
import '../services/prompt_builder.dart';
import '../services/storage.dart';
import '../services/tokenizer.dart';
import '../services/update_service.dart';

/// Single source of truth for providers, threads and the in-flight reply.
class AppState extends ChangeNotifier {
  AppState({Storage? storage, ChatClient? client, UpdateService? updateService})
      : _storage = storage ?? Storage(),
        _client = client ?? ChatClient(),
        _updateService = updateService ?? UpdateService();

  final Storage _storage;
  final ChatClient _client;
  final UpdateService _updateService;

  final List<Conversation> _conversations = <Conversation>[];
  final List<Provider> _providers = <Provider>[];
  final List<Character> _characters = <Character>[];
  final List<Preset> _presets = <Preset>[];
  final Map<String, String> _globalVars = <String, String>{};
  final Map<String, List<String>> _modelCache = <String, List<String>>{};
  // Per-provider cursor into its key pool, used by round-robin (advances every
  // request) and error-based (advances only when a request fails).
  final Map<String, int> _keyCursor = <String, int>{};
  final Random _random = Random();
  String? _defaultPresetId;
  TokenizerConfig _tokenizerConfig = const TokenizerConfig();
  // The app-wide tokenizer, reading config + active model live so a settings
  // change takes effect without rebuilding the prompt builder.
  late final AppTokenizer _tokenizer = AppTokenizer(
    config: () => _tokenizerConfig,
    model: () => activeProvider?.model ?? '',
  );
  late final PromptBuilder _prompts =
      PromptBuilder(macros: DefaultMacroEngine(), tokens: _tokenizer);
  String? _activeProviderId;
  Appearance _appearance = const Appearance();
  ChatInterface _chatInterface = const ChatInterface();
  String? _activeId;
  bool _ready = false;
  bool _streaming = false;
  bool _stopRequested = false;
  UpdateInfo? _availableUpdate;

  List<Conversation> get conversations => List.unmodifiable(_conversations);
  List<Provider> get providers => List.unmodifiable(_providers);
  List<Character> get characters => List.unmodifiable(_characters);
  List<Preset> get presets => List.unmodifiable(_presets);
  Appearance get appearance => _appearance;
  ChatInterface get chatInterface => _chatInterface;
  bool get ready => _ready;
  bool get streaming => _streaming;

  /// A newer release found on GitHub, or null when up to date / not yet checked.
  UpdateInfo? get availableUpdate => _availableUpdate;

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

  /// The visible thread without creating one — for read-only peeks (e.g. before
  /// committing to a send).
  Conversation? _activeOrNull() {
    final id = _activeId;
    if (id != null) {
      for (final conversation in _conversations) {
        if (conversation.id == id) return conversation;
      }
    }
    return _conversations.isEmpty ? null : _conversations.first;
  }

  Future<void> init() async {
    final providerState = await _storage.loadProviders();
    _providers
      ..clear()
      ..addAll(providerState.providers);
    _activeProviderId = providerState.activeId;
    _appearance = await _storage.loadAppearance();
    _chatInterface = await _storage.loadChatInterface();
    _characters
      ..clear()
      ..addAll(await _storage.loadCharacters());
    await _loadPresets();
    _globalVars
      ..clear()
      ..addAll(await _storage.loadGlobalVars());
    _modelCache
      ..clear()
      ..addAll(await _storage.loadModelCache());
    _tokenizerConfig = await _storage.loadTokenizerConfig();
    final stored = await _storage.loadConversations()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _conversations
      ..clear()
      ..addAll(stored);
    _activeId = await _storage.loadActiveId();
    _ready = true;
    notifyListeners();
    // Best-effort, non-blocking: surfaces an update affordance if one exists.
    unawaited(checkForUpdates());
  }

  /// Asks GitHub whether a newer release exists and, if so, exposes it via
  /// [availableUpdate]. Silent on any failure.
  Future<void> checkForUpdates() async {
    final info = await _updateService.checkLatest(kAppVersion);
    if (info != null) {
      _availableUpdate = info;
      notifyListeners();
    }
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

  Future<void> updateChatInterface(ChatInterface next) async {
    if (next == _chatInterface) return;
    _chatInterface = next;
    notifyListeners();
    await _storage.saveChatInterface(next);
  }

  // --- Presets -------------------------------------------------------------

  /// Loads presets, seeding a built-in default (SillyTavern's default blocks) on
  /// first run so a fresh install always has something to chat with.
  Future<void> _loadPresets() async {
    final state = await _storage.loadPresets();
    _presets
      ..clear()
      ..addAll(state.presets);
    _defaultPresetId = state.defaultId;
    if (_presets.isEmpty) {
      final seed = Preset.create(name: 'Default');
      _presets.add(seed);
      _defaultPresetId = seed.id;
      await _persistPresets();
    } else if (presetById(_defaultPresetId) == null) {
      _defaultPresetId = _presets.first.id;
    }
  }

  Future<void> _persistPresets() =>
      _storage.savePresets(PresetState(_presets, _defaultPresetId));

  Preset? presetById(String? id) {
    if (id == null) return null;
    for (final p in _presets) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// The preset a conversation runs under: its own chat-specific override, then
  /// its referenced preset, then the app default.
  Preset? presetFor(Conversation conversation) =>
      conversation.presetOverride ??
      presetById(conversation.presetId) ??
      presetById(_defaultPresetId);

  Preset? get defaultPreset => presetById(_defaultPresetId);
  String? get defaultPresetId => _defaultPresetId;

  Future<void> addPreset(Preset preset) async {
    _presets.add(preset);
    _defaultPresetId ??= preset.id;
    notifyListeners();
    await _persistPresets();
  }

  Future<void> savePreset(Preset preset) async {
    final index = _presets.indexWhere((p) => p.id == preset.id);
    if (index == -1) {
      _presets.add(preset);
    } else {
      _presets[index] = preset;
    }
    notifyListeners();
    await _persistPresets();
  }

  Future<Preset> duplicatePreset(Preset preset) async {
    final copy = preset.duplicate();
    _presets.add(copy);
    notifyListeners();
    await _persistPresets();
    return copy;
  }

  Future<void> deletePreset(String id) async {
    _presets.removeWhere((p) => p.id == id);
    if (_defaultPresetId == id) {
      _defaultPresetId = _presets.isEmpty ? null : _presets.first.id;
    }
    notifyListeners();
    await _persistPresets();
  }

  Future<void> setDefaultPreset(String id) async {
    if (_defaultPresetId == id) return;
    _defaultPresetId = id;
    notifyListeners();
    await _persistPresets();
  }

  /// Binds [conversation] to a preset (or clears it) — the per-chat selection.
  /// Choosing a preset drops any chat-specific override so the chat cleanly
  /// follows the chosen one.
  Future<void> setConversationPreset(String conversationId, String? presetId) async {
    for (final c in _conversations) {
      if (c.id == conversationId) {
        c.presetId = presetId;
        c.presetOverride = null;
        c.updatedAt = DateTime.now();
        break;
      }
    }
    notifyListeners();
    await _storage.saveConversations(_conversations);
  }

  /// Stores an edited preset as a chat-specific override (the "save for this
  /// chat only" path); does not touch the shared library.
  Future<void> saveChatPresetOverride(String conversationId, Preset preset) async {
    for (final c in _conversations) {
      if (c.id == conversationId) {
        c.presetOverride = Preset.fromJson(preset.toJson());
        c.updatedAt = DateTime.now();
        break;
      }
    }
    notifyListeners();
    await _storage.saveConversations(_conversations);
  }

  /// Drops a chat's preset override so it follows the shared library preset
  /// again. Without this, a single "this chat only" save pins the chat to a
  /// frozen copy forever: later edits to the library preset (raising the context
  /// size, say) apply everywhere *except* that chat, with nothing on screen to
  /// explain why.
  Future<void> clearChatPresetOverride(String conversationId) async {
    var changed = false;
    for (final c in _conversations) {
      if (c.id == conversationId && c.presetOverride != null) {
        c.presetOverride = null;
        c.updatedAt = DateTime.now();
        changed = true;
        break;
      }
    }
    if (!changed) return;
    notifyListeners();
    await _storage.saveConversations(_conversations);
  }

  /// Whether [conversation] runs on a chat-specific copy rather than the shared
  /// library preset.
  bool hasPresetOverride(Conversation conversation) =>
      conversation.presetOverride != null;

  /// Saves an edited preset back to the shared library (the "save for the whole
  /// preset" path) and binds the chat to it, clearing any override.
  Future<void> savePresetToLibrary(String conversationId, Preset preset) async {
    await savePreset(preset);
    for (final c in _conversations) {
      if (c.id == conversationId) {
        c.presetId = preset.id;
        c.presetOverride = null;
        c.updatedAt = DateTime.now();
        break;
      }
    }
    notifyListeners();
    await _storage.saveConversations(_conversations);
  }

  /// The character the user is impersonating in [conversation], or null when
  /// they are speaking as themselves.
  Character? impersonationFor(Conversation conversation) =>
      characterById(conversation.impersonateId);

  /// Sets (or clears, when [character] is null) the impersonated identity on the
  /// active thread — the send-bar "impersonate" action. The chosen persona is
  /// injected into every subsequent request (see [_generate]).
  Future<void> setImpersonation(Character? character) async {
    final conversation = active;
    if (conversation.impersonateId == character?.id) return;
    conversation.impersonateId = character?.id;
    conversation.impersonateName = character?.displayName;
    conversation.updatedAt = DateTime.now();
    notifyListeners();
    await _storage.saveConversations(_conversations);
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
    // The greeting is stored with {{char}}/{{user}} intact so it tracks the
    // current identity (e.g. after the user starts impersonating) — resolution
    // happens at prompt-build and display time, not once at write time.
    final greeting = character.firstMes.trim();
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
        final greeting = character.firstMes.trim();
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

    // Resolve the provider before materializing a thread, so a misconfigured
    // app never spawns an empty conversation just to bail out.
    final current = _activeOrNull();
    final preset = current == null
        ? presetById(_defaultPresetId)
        : presetFor(current);
    if (_resolveProvider(preset) == null) return;

    final conversation = active;

    if (conversation.isEmpty) conversation.retitleFrom(prompt);
    conversation.messages.add(ChatMessage(role: 'user', content: prompt));

    await _generate(conversation);
  }

  /// Streams an assistant reply into [conversation], whose messages already end
  /// with the user's latest turn (this does NOT append the user message). Shared
  /// by [send] and [regenerateMessage].
  Future<void> _generate(Conversation conversation) async {
    final preset = presetFor(conversation);
    final base = _resolveProvider(preset);
    if (base == null) return;

    final assembled = _assemble(conversation);
    final history = assembled.messages;
    final params = assembled.params;

    conversation.messages.add(ChatMessage(role: 'assistant', content: ''));
    conversation.updatedAt = DateTime.now();
    _moveToTop(conversation);
    _streaming = true;
    _stopRequested = false;
    notifyListeners();

    final reply = StringBuffer();
    // Narrow the key pool to the one this request should use.
    final provider = _applyKey(base);
    try {
      final deltas =
          _client.streamChat(provider: provider, history: history, params: params);
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
        // A failed request rotates an error-based pool to the next key.
        _advanceKeyOnError(base);
        _replaceLast(conversation, content: e.message, error: true);
      }
    } finally {
      _streaming = false;
      _stopRequested = false;
      conversation.updatedAt = DateTime.now();
      notifyListeners();
      await _storage.saveConversations(_conversations);
      // Macros may have mutated variables; persist both scopes.
      await _storage.saveGlobalVars(_globalVars);
    }
  }

  /// Finds a thread by [id] without materializing one — for the message-level
  /// actions below, which must be no-ops on an unknown id.
  Conversation? _conversationById(String id) {
    for (final c in _conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Replaces the content of the message at [index] — the "edit turn" action.
  /// An empty (trimmed) edit is ignored.
  Future<void> editMessage(
      String conversationId, int index, String content) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    if (index < 0 || index >= conversation.messages.length) return;
    conversation.messages[index] =
        conversation.messages[index].copyWith(content: trimmed);
    conversation.updatedAt = DateTime.now();
    notifyListeners();
    await _storage.saveConversations(_conversations);
  }

  /// Removes the message at [index] — the "delete turn" action. Ignored while
  /// the active conversation is streaming, to avoid racing the in-flight reply.
  Future<void> deleteMessage(String conversationId, int index) async {
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    if (_streaming && _activeOrNull()?.id == conversation.id) return;
    if (index < 0 || index >= conversation.messages.length) return;
    conversation.messages.removeAt(index);
    conversation.updatedAt = DateTime.now();
    notifyListeners();
    await _storage.saveConversations(_conversations);
  }

  /// Copies messages [0..index] (inclusive) into a NEW thread, makes it active,
  /// and returns its id — the "fork from here" action. Messages are deep-copied
  /// so the fork and its source diverge independently.
  Future<String> forkConversation(String conversationId, int index) async {
    final source = _conversationById(conversationId);
    if (source == null) return '';
    final end =
        source.messages.isEmpty ? -1 : index.clamp(0, source.messages.length - 1);
    final copied = <ChatMessage>[
      for (var i = 0; i <= end; i++)
        ChatMessage.fromJson(source.messages[i].toJson()),
    ];
    final fork = Conversation(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: '${source.title} (fork)',
      messages: copied,
      updatedAt: DateTime.now(),
      characterId: source.characterId,
      characterName: source.characterName,
      systemPrompt: source.systemPrompt,
      impersonateId: source.impersonateId,
      impersonateName: source.impersonateName,
      presetId: source.presetId,
      presetOverride: source.presetOverride == null
          ? null
          : Preset.fromJson(source.presetOverride!.toJson()),
      variables: Map<String, String>.from(source.variables),
    );
    _conversations.insert(0, fork);
    _activeId = fork.id;
    notifyListeners();
    await _storage.saveActiveId(fork.id);
    await _storage.saveConversations(_conversations);
    return fork.id;
  }

  /// Regenerates the assistant turn at [index]: drops it and everything after,
  /// then streams a fresh reply from the remaining history — the "retry" action.
  /// A no-op for a user turn, an unknown thread, or while streaming.
  Future<void> regenerateMessage(String conversationId, int index) async {
    if (_streaming) return;
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    if (index < 0 || index >= conversation.messages.length) return;
    if (conversation.messages[index].isUser) return;
    conversation.messages.removeRange(index, conversation.messages.length);
    await _generate(conversation);
  }

  /// The provider a request runs on. The user's active provider selection is
  /// authoritative — a preset's bound provider/model is only a fallback for when
  /// nothing is actively selected (or the provider names no model). Previously
  /// a preset's binding silently overrode the picker, so switching provider or
  /// model "did nothing" and the old one lived on.
  Provider? _resolveProvider(Preset? preset) {
    Provider? base = activeProvider;
    // Fall back to the preset's bound provider only when there is no active one.
    if (base == null && preset?.providerId != null) {
      for (final p in _providers) {
        if (p.id == preset!.providerId) {
          base = p;
          break;
        }
      }
    }
    if (base == null) return null;
    // The active provider's own model wins; the preset's model is used only when
    // that provider has none set.
    final model = base.model.trim().isNotEmpty
        ? base.model
        : (preset?.model.trim() ?? '');
    return model == base.model ? base : base.copyWith(model: model);
  }

  /// Narrows [base]'s key pool to the single key this request should use, per
  /// its [KeyRotationStrategy]. A single-key (or keyless) provider is returned
  /// unchanged. Round-robin advances the cursor here; error-based holds until a
  /// failure moves it (see [_advanceKeyOnError]); random is stateless.
  Provider _applyKey(Provider base) {
    final keys = base.usableKeys;
    if (keys.length <= 1) return base;
    switch (base.keyStrategy) {
      case KeyRotationStrategy.random:
        return base.withActiveKey(keys[_random.nextInt(keys.length)]);
      case KeyRotationStrategy.roundRobin:
        final i = (_keyCursor[base.id] ?? 0) % keys.length;
        _keyCursor[base.id] = (i + 1) % keys.length;
        return base.withActiveKey(keys[i]);
      case KeyRotationStrategy.errorBased:
        final i = (_keyCursor[base.id] ?? 0) % keys.length;
        return base.withActiveKey(keys[i]);
    }
  }

  /// Moves an error-based pool onto its next key so the following request tries
  /// a different credential. No-op for other strategies or a single key.
  void _advanceKeyOnError(Provider base) {
    if (base.keyStrategy != KeyRotationStrategy.errorBased) return;
    final count = base.usableKeys.length;
    if (count <= 1) return;
    _keyCursor[base.id] = ((_keyCursor[base.id] ?? 0) + 1) % count;
  }

  static const int _perMessageOverhead = 4; // mirrors PromptBuilder
  int _cost(ChatMessage m) => _tokenizer.estimate(m.content) + _perMessageOverhead;

  /// The app-wide tokenizer choice (OpenAI / Anthropic / Custom).
  TokenizerConfig get tokenizerConfig => _tokenizerConfig;

  /// Whether the current tokenizer yields approximate counts (Anthropic).
  bool get tokenizerIsApproximate => _tokenizer.isApproximate;

  /// The BPE encoding the tokenizer is currently resolving to (for the settings
  /// readout).
  BpeEncoding get activeTokenizerEncoding => _tokenizer.activeEncoding();

  Future<void> updateTokenizerConfig(TokenizerConfig next) async {
    if (next == _tokenizerConfig) return;
    _tokenizerConfig = next;
    notifyListeners();
    await _storage.saveTokenizerConfig(next);
  }

  /// A synchronous token estimate for [text] under the active tokenizer — used
  /// by the message Info view and anywhere a one-off count is needed.
  int estimateTokens(String text) => _tokenizer.estimate(text);

  /// An exact input-token count for [assembled] from the provider's count API
  /// (Anthropic only), or null when unavailable. Display-only, best-effort.
  Future<int?> exactTokenCount(AssembledPrompt assembled) {
    final provider = activeProvider;
    if (provider == null) return Future<int?>.value(null);
    return _client.countTokens(provider, assembled.messages);
  }

  /// The literal HTTP request a send would make for [assembled] — endpoint,
  /// headers (credentials redacted) and the JSON body — built by the same code
  /// that performs the send. For the inspector's "copy raw request", so a report
  /// about what the app transmits can be checked against the actual bytes
  /// instead of an approximation. Null when no provider is configured.
  String? requestPreview(AssembledPrompt assembled) {
    final preset = presetFor(_activeOrNull() ?? active);
    final provider = _resolveProvider(preset);
    if (provider == null) return null;
    return _client.requestPreview(
      _applyKey(provider),
      assembled.messages,
      params: assembled.params,
    );
  }

  /// Assembles the exact request for [conversation] — the single code path used
  /// by real sends ([_generate]) *and* the "View prompt" / "Info" inspectors, so
  /// what the user inspects is what the model receives. [historyEnd], when set,
  /// caps the messages considered (exclusive), letting a caller rebuild the
  /// prompt as it stood at an earlier turn.
  AssembledPrompt _assemble(Conversation conversation, {int? historyEnd}) {
    final preset = presetFor(conversation);
    final model = _resolveProvider(preset)?.model ?? '';

    final considered = historyEnd == null
        ? conversation.messages
        : conversation.messages.take(historyEnd.clamp(0, conversation.messages.length)).toList();
    // Failure notices are display-only, so they never go back to the model.
    final priorTurns =
        considered.where((m) => !m.error).toList(growable: false);

    // A preset's {{input}} is the latest user turn in the considered window.
    var input = '';
    for (final m in priorTurns.reversed) {
      if (m.isUser) {
        input = m.content;
        break;
      }
    }

    // When the user impersonates a character, their identity is injected so the
    // model treats their turns as that persona (mirrors Agnai's user-persona).
    final impersonation = impersonationFor(conversation);
    final character = characterById(conversation.characterId);
    final userName = impersonation?.displayName ?? 'User';
    final persona = impersonation == null
        ? ''
        : impersonation.userPersona(charName: character?.displayName ?? 'the character');
    final maxContext = preset?.maxContext ?? Preset.defaultMaxContext;

    // Leading system turns injected by AppState (ahead of the built prompt),
    // each surfaced as its own breakdown section.
    final prefix = <ChatMessage>[];
    final sections = <PromptSection>[];
    void addPrefix(String label, String content) {
      final trimmed = content.trim();
      if (trimmed.isEmpty) return;
      final m = ChatMessage(role: 'system', content: trimmed);
      prefix.add(m);
      sections.add(PromptSection(
        label: label, role: 'system', tokens: _cost(m), messageCount: 1));
    }

    List<ChatMessage> messages;
    var params = const GenParams();

    if (preset != null) {
      final built = _prompts.build(
        preset: preset,
        character: character,
        history: priorTurns,
        model: model,
        userName: userName,
        persona: persona,
        variables: MacroVariables(
          local: conversation.variables,
          global: _globalVars,
        ),
        input: input,
      );
      // Robustness: the preset fills the character definition from the *live*
      // character via its marker blocks. Two ways that definition can silently
      // vanish — leaving the model with "only the instructions and the last
      // message" — and a fallback for each:
      //  1. The linked character is gone (deleted, or an older thread that
      //     never linked one): fall back to the persona snapshot stored on the
      //     thread at creation.
      //  2. The character is present but the active preset carries none of the
      //     definition markers (a trimmed or imported preset, markers removed/
      //     disabled): inject the live character's definition directly.
      if (character == null) {
        addPrefix('Character (stored)', conversation.systemPrompt);
      } else if (!_presetEmitsDefinition(preset)) {
        addPrefix('Character definition', character.definition(userName: userName));
      }
      // The persona reaches the payload through the preset's personaDescription
      // block when it has one; otherwise inject it as a leading system turn so
      // impersonation always takes effect regardless of preset shape.
      if (persona.isNotEmpty && !_presetEmitsPersona(preset)) {
        addPrefix('User persona', persona);
      }
      messages = <ChatMessage>[...prefix, ...built.messages];
      sections.addAll(built.sections);
      params = _paramsFor(preset);
    } else {
      // No preset: the original flat behaviour — stored persona then history,
      // plus the impersonated user persona (when set).
      addPrefix('Character (stored)', conversation.systemPrompt);
      if (persona.isNotEmpty) addPrefix('User persona', persona);
      messages = <ChatMessage>[...prefix, ...priorTurns];
      if (priorTurns.isNotEmpty) {
        sections.add(PromptSection(
          label: 'Chat history',
          role: 'mixed',
          tokens: priorTurns.fold<int>(0, (s, m) => s + _cost(m)),
          messageCount: priorTurns.length,
        ));
      }
    }

    final total = sections.fold<int>(0, (s, x) => s + x.tokens);
    return AssembledPrompt(
      // Merge again after the prefix is prepended, so an injected leading system
      // turn cannot re-fragment the payload. This is the exact list handed to
      // the wire layer, and the same list "View prompt" renders — the inspector
      // shows what is actually sent, not a pre-merge idealisation.
      messages: mergeSameRole(messages),
      params: params,
      sections: sections,
      totalTokens: total,
      maxContext: maxContext,
    );
  }

  /// The exact prompt behind the message at [index] — for "View prompt"/"Info".
  /// An assistant turn shows the prompt that *produced* it (history before it);
  /// a user turn shows what *would* be sent next (history through it).
  AssembledPrompt assemblePromptForMessage(Conversation conversation, int index) {
    final safe = index.clamp(0, conversation.messages.length);
    final isUser = safe < conversation.messages.length &&
        conversation.messages[safe].isUser;
    final end = isUser ? safe + 1 : safe;
    return _assemble(conversation, historyEnd: end);
  }

  /// Whether [preset] already surfaces the user persona through an enabled
  /// personaDescription marker block, so the impersonation persona is not
  /// injected twice.
  bool _presetEmitsPersona(Preset preset) {
    for (final entry in preset.promptOrder) {
      if (entry.identifier == PromptId.personaDescription && entry.enabled) {
        final block = preset.blockById(entry.identifier);
        if (block != null && block.marker) return true;
      }
    }
    return false;
  }

  /// Whether [preset] will actually emit the character's definition — i.e. it
  /// has at least one enabled definition marker (description / personality /
  /// scenario / example dialogue) whose block still exists and is a marker.
  ///
  /// A preset that carries none of these (a trimmed or imported preset, or one
  /// whose markers were removed/disabled) would send only its instruction text
  /// and the chat, silently dropping the whole character definition. When this
  /// returns false, [_assemble] injects the definition as a fallback so it
  /// always reaches the model.
  bool _presetEmitsDefinition(Preset preset) {
    const definitionMarkers = <String>{
      PromptId.charDescription,
      PromptId.charPersonality,
      PromptId.scenario,
      PromptId.dialogueExamples,
    };
    for (final entry in preset.promptOrder) {
      if (entry.enabled && definitionMarkers.contains(entry.identifier)) {
        final block = preset.blockById(entry.identifier);
        if (block != null && block.marker) return true;
      }
    }
    return false;
  }

  GenParams _paramsFor(Preset p) => GenParams(
        temperature: p.temperature,
        maxTokens: p.maxResponseTokens,
        topP: p.topP,
        topK: p.topK,
        frequencyPenalty: p.frequencyPenalty,
        presencePenalty: p.presencePenalty,
        seed: p.seed,
        n: p.n,
        stop: p.stopSequences,
      );

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

  /// The last model list fetched for [providerId], or empty if none cached.
  List<String> cachedModels(String? providerId) =>
      providerId == null ? const [] : (_modelCache[providerId] ?? const []);

  /// Fetches [provider]'s model list, caches it (persisted) for later opens,
  /// and returns it. Used by the model picker's refresh.
  Future<List<String>> refreshModels(Provider provider) async {
    final models = await _client.listModels(provider);
    _modelCache[provider.id] = models;
    notifyListeners();
    await _storage.saveModelCache(_modelCache);
    return models;
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

/// The fully assembled request for a turn: the role-tagged [messages] the model
/// receives, the [params] applied, the per-section token [sections] breakdown,
/// the [totalTokens] estimate, and the preset's [maxContext] budget. Produced by
/// [AppState._assemble]; consumed by real sends and the View-prompt/Info views.
class AssembledPrompt {
  const AssembledPrompt({
    required this.messages,
    required this.params,
    required this.sections,
    required this.totalTokens,
    required this.maxContext,
  });

  final List<ChatMessage> messages;
  final GenParams params;
  final List<PromptSection> sections;
  final int totalTokens;
  final int maxContext;
}
