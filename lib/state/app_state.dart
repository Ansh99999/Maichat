import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../app_info.dart';
import '../models/appearance.dart';
import '../models/character.dart';
import '../models/chat_interface.dart';
import '../models/conversation.dart';
import '../models/discover.dart';
import '../models/lorebook.dart';
import '../models/message.dart';
import '../models/preset.dart';
import '../models/prompt_block.dart';
import '../models/provider.dart';
import '../services/chat_client.dart';
import '../services/avatar_store.dart';
import '../services/macro_context.dart';
import '../services/macro_engine.dart';
import '../services/model_context.dart';
import '../services/prompt_builder.dart';
import '../services/reasoning.dart';
import '../services/storage.dart';
import '../services/tokenizer.dart';
import '../services/update_service.dart';
import '../services/world_info.dart';

/// Single source of truth for providers, threads and the in-flight reply.
class AppState extends ChangeNotifier {
  AppState({
    Storage? storage,
    ChatClient? client,
    UpdateService? updateService,
    AvatarStore? avatars,
    this.loadTimeout = const Duration(seconds: 30),
  })  : _storage = storage ?? Storage(),
        _client = client ?? ChatClient(),
        _updateService = updateService ?? UpdateService() {
    _avatars = avatars;
  }

  final Storage _storage;
  final ChatClient _client;
  final UpdateService _updateService;

  /// How long the startup read is given before the app opens anyway. Generous
  /// enough for a big store on a slow phone, short enough that the app is never
  /// simply stuck.
  final Duration loadTimeout;

  /// Where character pictures are kept. Resolved in `main()` before the first
  /// frame and handed in, so nothing here has to wait on a platform channel;
  /// null when the platform would not say where to put them, in which case
  /// pictures stay where an older build left them.
  AvatarStore? _avatars;

  final List<Conversation> _conversations = <Conversation>[];
  final List<Provider> _providers = <Provider>[];
  final List<Character> _characters = <Character>[];
  final List<Lorebook> _lorebooks = <Lorebook>[];
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

  /// Decides which lorebook entries each request carries. Shares the app's
  /// tokenizer so the lore budget is measured the same way the prompt budget is.
  late final WorldInfoScanner _world = WorldInfoScanner(tokens: _tokenizer);
  String? _activeProviderId;
  Appearance _appearance = const Appearance();
  ChatInterface _chatInterface = const ChatInterface();
  String? _activeId;
  bool _ready = false;
  bool _streaming = false;
  bool _stopRequested = false;
  UpdateInfo? _availableUpdate;

  /// What went wrong while reading stored data, or null when startup was clean.
  String? _loadError;

  /// Set when startup could not read the store. Writing is then refused, so a
  /// half-loaded (or empty) session can never overwrite data that is still on
  /// disk — see [_writable].
  bool _loadFailed = false;

  List<Conversation> get conversations => List.unmodifiable(_conversations);
  List<Provider> get providers => List.unmodifiable(_providers);
  List<Character> get characters => List.unmodifiable(_characters);
  List<Lorebook> get lorebooks => List.unmodifiable(_lorebooks);
  List<Preset> get presets => List.unmodifiable(_presets);
  Appearance get appearance => _appearance;
  ChatInterface get chatInterface => _chatInterface;
  bool get ready => _ready;
  bool get streaming => _streaming;

  /// A human-readable reason the stored data could not be read, or null.
  /// Non-null means the session is read-only until [retryLoad] succeeds.
  String? get loadError => _loadError;

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

  /// Reads everything the app needs to open.
  ///
  /// Startup must always finish. Whatever happens down in the storage layer —
  /// a corrupt entry, a platform channel that fails, a store so large that
  /// reading it runs out of memory — the app still opens and says what went
  /// wrong, because the alternative (what shipped before) was an
  /// indistinguishable spinner forever: [ready] never became true and there was
  /// no way back in. When the load does fail, [_loadFailed] makes the session
  /// read-only so the half-empty state cannot overwrite what is still on disk.
  Future<void> init() async {
    try {
      await _load().timeout(loadTimeout);
    } on TimeoutException {
      _fail('Reading saved data took too long and was given up on.');
    } catch (error) {
      _fail('Saved data could not be read: $error');
    } finally {
      _ready = true;
      notifyListeners();
      // Best-effort, non-blocking: surfaces an update affordance if one exists.
      unawaited(checkForUpdates());
    }
  }

  /// Reads each store in turn. Anything that throws in here aborts the whole
  /// read — [init] catches it and the session goes read-only.
  Future<void> _load() async {
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
    _lorebooks
      ..clear()
      ..addAll(await _storage.loadLorebooks());
    await _loadPresets();
    _globalVars
      ..clear()
      ..addAll(await _storage.loadGlobalVars());
    _modelCache
      ..clear()
      ..addAll(await _storage.loadModelCache());
    _tokenizerConfig = await _storage.loadTokenizerConfig();
    _discoverPrefs = await _storage.loadDiscoverPrefs();
    final stored = await _storage.loadConversations()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _conversations
      ..clear()
      ..addAll(stored);
    _activeId = await _storage.loadActiveId();
    await _adoptStoredAvatars();
  }

  /// Moves any picture still living as base64 in the preferences store into the
  /// pictures directory, once, on the first launch that has this code. A store
  /// written by an older build carries its avatars inline; leaving them there is
  /// what made the store slow to read, slow to write and — past Android's
  /// preference-parser limits — unreadable.
  ///
  /// Deliberately best-effort: if it cannot be done the app carries on with the
  /// pictures where they are.
  Future<void> _adoptStoredAvatars() async {
    final store = _avatars;
    if (store == null) return;
    try {
      var moved = 0;
      for (final character in _characters) {
        final ref = await store.adopt(character.avatar);
        if (ref != character.avatar) {
          character.avatar = ref;
          moved++;
        }
      }
      if (moved > 0) {
        debugPrint('MaiChat: moved $moved character picture(s) out of the '
            'preferences store and into files');
        await _persistCharacters();
      }
      await _sweepAvatars();
    } catch (error) {
      debugPrint('MaiChat: could not move pictures into files ($error)');
    }
  }

  void _fail(String message) {
    _loadError = message;
    _loadFailed = true;
    debugPrint('MaiChat: $message');
  }

  /// Whether persisting is allowed. False after a failed load, so a session
  /// that came up without the user's data never writes over it.
  bool get _writable => !_loadFailed;

  /// Tries the failed load again, from the UI's "Retry" action.
  Future<void> retryLoad() async {
    if (!_loadFailed) return;
    _loadError = null;
    _loadFailed = false;
    _ready = false;
    notifyListeners();
    await init();
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

  Future<void> _persistProviders() async {
    if (!_writable) return;
    await _storage.saveProviders(ProviderState(_providers, _activeProviderId));
  }

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
    if (!_writable) return;
    await _storage.saveAppearance(next);
  }

  Future<void> updateChatInterface(ChatInterface next) async {
    if (next == _chatInterface) return;
    _chatInterface = next;
    notifyListeners();
    if (!_writable) return;
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

  Future<void> _persistPresets() async {
    if (!_writable) return;
    await _storage.savePresets(PresetState(_presets, _defaultPresetId));
  }

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
    await _saveConversations();
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
    await _saveConversations();
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
    await _saveConversations();
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
    await _saveConversations();
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
    await _saveConversations();
  }

  // --- Characters ----------------------------------------------------------

  Future<void> _persistCharacters() async {
    if (!_writable) return;
    await _storage.saveCharacters(_characters);
  }

  /// The whole conversation list, rewritten. Everything that changes a thread
  /// funnels through here (and the siblings below) so the read-only guard after
  /// a failed load is impossible to bypass.
  Future<void> _saveConversations() async {
    if (!_writable) return;
    await _storage.saveConversations(_conversations);
  }

  Future<void> _saveActiveId(String id) async {
    if (!_writable) return;
    await _storage.saveActiveId(id);
  }


  Character? characterById(String? id) {
    if (id == null) return null;
    for (final c in _characters) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Adds [character] to the top of the roster.
  Future<void> addCharacter(Character character) async {
    await _storeAvatar(character);
    _characters.insert(0, character);
    notifyListeners();
    await _persistCharacters();
  }

  /// Adds several characters at once (bulk import), newest first, persisting
  /// once.
  Future<void> addCharacters(List<Character> characters) async {
    if (characters.isEmpty) return;
    for (final character in characters) {
      await _storeAvatar(character);
    }
    _characters.insertAll(0, characters);
    notifyListeners();
    await _persistCharacters();
  }

  /// Replaces the stored character sharing [character]'s id, or adds it when
  /// there is no match yet.
  Future<void> saveCharacter(Character character) async {
    character.updatedAt = DateTime.now();
    await _storeAvatar(character);
    final index = _characters.indexWhere((c) => c.id == character.id);
    if (index == -1) {
      _characters.insert(0, character);
    } else {
      _characters[index] = character;
    }
    notifyListeners();
    await _persistCharacters();
  }

  /// Moves the picture a character arrived with out of the preferences store and
  /// into a file. Every avatar reaches storage through here — a picked photo, an
  /// imported card, a CharX asset — so nothing puts an image back in the store.
  /// No size limit: the file can be as large as the picture is.
  Future<void> _storeAvatar(Character character) async {
    final store = _avatars;
    if (store == null) return; // No directory: keep the old base64 behaviour.
    final stored = await store.adopt(character.avatar);
    if (stored != character.avatar) character.avatar = stored;
  }

  Future<void> deleteCharacter(String id) async {
    _characters.removeWhere((c) => c.id == id);
    notifyListeners();
    await _persistCharacters();
    await _sweepAvatars();
  }

  /// Deletes picture files no character refers to any more.
  Future<void> _sweepAvatars() async {
    final store = _avatars;
    if (store == null || !_writable) return;
    await store.sweep([
      ..._characters.map((c) => c.avatar),
      ..._lorebooks.map((b) => b.thumbnail),
    ]);
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

  // --- Lorebooks -----------------------------------------------------------

  Future<void> _persistLorebooks() async {
    if (!_writable) return;
    await _storage.saveLorebooks(_lorebooks);
  }

  Lorebook? lorebookById(String? id) {
    if (id == null) return null;
    for (final b in _lorebooks) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// The books switched on for [conversation], in the order they were added.
  /// Ids that no longer resolve are skipped rather than reported: a book the
  /// user deleted should not break sending a message. A repeated id is counted
  /// once, so a stored list written by hand cannot inject the same lore twice.
  List<Lorebook> lorebooksFor(Conversation? conversation) {
    if (conversation == null) return const <Lorebook>[];
    final out = <Lorebook>[];
    final seen = <String>{};
    for (final id in conversation.lorebookIds) {
      if (!seen.add(id)) continue;
      final book = lorebookById(id);
      if (book != null) out.add(book);
    }
    return out;
  }

  /// Moves a book's picture out of the preferences store and into a file, the
  /// same way character avatars are handled — the store is read whole at every
  /// launch, so an inline picture is felt on every start.
  Future<void> _storeThumbnail(Lorebook book) async {
    final store = _avatars;
    if (store == null) return;
    final stored = await store.adopt(book.thumbnail);
    if (stored != book.thumbnail) book.thumbnail = stored;
  }

  Future<void> addLorebook(Lorebook book) async {
    await _storeThumbnail(book);
    _lorebooks.insert(0, book);
    notifyListeners();
    await _persistLorebooks();
  }

  /// Adds several books at once (an import), newest first, persisting once.
  Future<void> addLorebooks(List<Lorebook> books) async {
    if (books.isEmpty) return;
    for (final book in books) {
      await _storeThumbnail(book);
    }
    _lorebooks.insertAll(0, books);
    notifyListeners();
    await _persistLorebooks();
  }

  /// Replaces the stored book sharing [book]'s id, or adds it when new.
  Future<void> saveLorebook(Lorebook book) async {
    book.updatedAt = DateTime.now();
    await _storeThumbnail(book);
    final index = _lorebooks.indexWhere((b) => b.id == book.id);
    if (index == -1) {
      _lorebooks.insert(0, book);
    } else {
      _lorebooks[index] = book;
    }
    notifyListeners();
    await _persistLorebooks();
  }

  /// Deletes a book and switches it off in every chat that was using it, so no
  /// thread is left pointing at something that is gone.
  Future<void> deleteLorebook(String id) async {
    _lorebooks.removeWhere((b) => b.id == id);
    var touched = false;
    for (final conversation in _conversations) {
      if (conversation.lorebookIds.remove(id)) touched = true;
    }
    notifyListeners();
    await _persistLorebooks();
    if (touched) await _saveConversations();
    await _sweepAvatars();
  }

  Future<void> toggleLorebookStar(String id) async {
    final book = lorebookById(id);
    if (book == null) return;
    book.starred = !book.starred;
    book.updatedAt = DateTime.now();
    notifyListeners();
    await _persistLorebooks();
  }

  Future<Lorebook> duplicateLorebook(Lorebook book) async {
    final copy = book.copyWith(name: '${book.displayName} (copy)');
    final fresh = Lorebook.fromJson({
      ...copy.toJson(),
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
    });
    await addLorebook(fresh);
    return fresh;
  }

  /// Switches [bookId] on for a chat, or off again if it was already on.
  Future<void> toggleConversationLorebook(
      String conversationId, String bookId) async {
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    if (!conversation.lorebookIds.remove(bookId)) {
      conversation.lorebookIds.add(bookId);
    }
    notifyListeners();
    await _saveConversations();
  }

  /// Replaces the whole set of books a chat runs with.
  Future<void> setConversationLorebooks(
      String conversationId, List<String> bookIds) async {
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    conversation.lorebookIds
      ..clear()
      ..addAll(bookIds);
    notifyListeners();
    await _saveConversations();
  }


  /// Every greeting [character] offers, in card order: the main one first, then
  /// its alternates, blanks dropped. Seeded as the swipes of the opening turn so
  /// a card's alternate greetings are finally reachable — flip through them with
  /// the message's ‹ › control instead of only ever seeing `first_mes`.
  ///
  /// Greetings are kept with {{char}}/{{user}} intact so they track the current
  /// identity (e.g. after the user starts impersonating) — resolution happens at
  /// prompt-build and display time, not once at write time.
  static List<MessageVariant> _greetingSwipes(Character character) => <String>[
        character.firstMes.trim(),
        ...character.alternateGreetings.map((g) => g.trim()),
      ]
          .where((g) => g.isNotEmpty)
          .map((g) => MessageVariant(content: g))
          .toList();

  /// Opens a fresh thread bound to [character]: titles it after the character,
  /// stores the composed persona as the thread's (invisible) system prompt, and
  /// seeds its greetings as the opening assistant turn when there are any.
  /// Returns the new conversation's id so the caller can navigate to it.
  String startChatWithCharacter(Character character) {
    final conversation = Conversation.empty()
      ..title = character.displayName
      ..characterId = character.id
      ..characterName = character.displayName
      ..systemPrompt = character.composedSystemPrompt();
    final greetings = _greetingSwipes(character);
    if (greetings.isNotEmpty) {
      conversation.messages
          .add(ChatMessage(role: 'assistant', swipes: greetings));
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
    _saveActiveId(target.id);
  }

  void selectConversation(String id) {
    _activeId = id;
    notifyListeners();
    _saveActiveId(id);
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
    await _saveConversations();
  }

  /// Empties the active thread but keeps it around — the "restart chat"
  /// action. Any in-flight reply is aborted first.
  Future<void> restartConversation() async {
    if (_streaming) stop();
    final conversation = active;
    conversation.messages.clear();
    // A character thread keeps its identity and re-seeds the greetings; a plain
    // thread resets to an untitled one.
    if (conversation.hasCharacter) {
      final character = characterById(conversation.characterId);
      if (character != null) {
        final greetings = _greetingSwipes(character);
        if (greetings.isNotEmpty) {
          conversation.messages
              .add(ChatMessage(role: 'assistant', swipes: greetings));
        }
      }
    } else {
      conversation.title = 'New chat';
    }
    conversation.updatedAt = DateTime.now();
    notifyListeners();
    await _saveConversations();
  }

  Future<void> deleteConversation(String id) async {
    if (id == active.id && _streaming) stop();
    _conversations.removeWhere((c) => c.id == id);
    if (_activeId == id) _activeId = null;
    notifyListeners();
    await _saveConversations();
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
  ///
  /// With [swipeInto] set, the reply is written as a new swipe on the existing
  /// assistant turn at that index rather than as a new turn — so a regeneration
  /// keeps the reply it replaced and the two can be flipped between. The prompt
  /// is then the history that came *before* that turn: a reply is never part of
  /// its own input.
  ///
  /// Two kinds of thinking are folded into the same place on the message: what
  /// the provider returns in its own field, and what the model writes inline
  /// between the preset's thinking tags. Either way the reply text stays clean
  /// and the thinking is timed, so the chat can show "Thought for X seconds".
  Future<void> _generate(Conversation conversation, {int? swipeInto}) async {
    final preset = presetFor(conversation);
    final base = _resolveProvider(preset);
    if (base == null) return;

    final assembled = _assemble(conversation, historyEnd: swipeInto);
    final history = assembled.messages;
    final params = assembled.params;
    final tags = ReasoningTags(
      start: preset?.thinkStartTag.trim() ?? '',
      end: preset?.thinkEndTag.trim() ?? '',
    );

    // The turn the reply streams into, and (for a regeneration) the swipe that
    // was live before it, so an aborted attempt can be rolled back cleanly.
    final int target;
    if (swipeInto == null) {
      conversation.messages.add(ChatMessage(role: 'assistant', content: ''));
      target = conversation.messages.length - 1;
    } else {
      target = swipeInto;
      conversation.messages[target] = conversation.messages[target]
          .addSwipe(const MessageVariant(content: ''));
    }
    conversation.updatedAt = DateTime.now();
    _moveToTop(conversation);
    _streaming = true;
    _stopRequested = false;
    notifyListeners();

    // Everything the model sent as message text, tags included; the split into
    // answer and thinking is re-derived from it after every delta.
    final raw = StringBuffer();
    // Thinking the provider handed over separately.
    final thoughts = StringBuffer();
    final clock = Stopwatch()..start();
    int? thinkingMs;
    var answer = '';
    var thinking = '';

    // Narrow the key pool to the one this request should use.
    final provider = _applyKey(base);
    try {
      final deltas =
          _client.streamChat(provider: provider, history: history, params: params);
      await for (final delta in deltas) {
        if (delta.reasoning.isNotEmpty) thoughts.write(delta.reasoning);
        if (delta.text.isNotEmpty) raw.write(delta.text);
        final split = splitReasoning(raw.toString(), tags);
        answer = split.text;
        thinking = _joinThinking(thoughts.toString(), split.reasoning);
        // Thinking is over the moment the answer starts — or, for tagged
        // thinking, when the closing tag lands.
        if (thinkingMs == null &&
            thinking.trim().isNotEmpty &&
            !split.open &&
            answer.trim().isNotEmpty) {
          thinkingMs = clock.elapsedMilliseconds;
        }
        _replaceAt(conversation, target,
            content: answer, reasoning: thinking, thinkingMs: thinkingMs);
        notifyListeners();
      }
      // A block the model never closed, or a reply that was thinking and nothing
      // else, still gets a duration once the stream ends.
      if (thinkingMs == null && thinking.trim().isNotEmpty) {
        thinkingMs = clock.elapsedMilliseconds;
      }
      if (answer.trim().isEmpty) {
        _replaceAt(
          conversation,
          target,
          content: thinking.trim().isEmpty
              ? 'The model returned an empty response.'
              // Almost always a thinking budget that left no room for the reply.
              : 'The model finished thinking but returned no answer.',
          reasoning: thinking,
          thinkingMs: thinkingMs,
          error: true,
        );
      } else {
        _replaceAt(conversation, target,
            content: answer, reasoning: thinking, thinkingMs: thinkingMs);
      }
    } on ChatApiException catch (e) {
      if (_stopRequested) {
        _finishStopped(conversation, target, answer,
            reasoning: thinking, thinkingMs: thinkingMs);
      } else {
        // A failed request rotates an error-based pool to the next key.
        _advanceKeyOnError(base);
        _replaceAt(conversation, target,
            content: e.message, reasoning: '', error: true);
      }
    } finally {
      _streaming = false;
      _stopRequested = false;
      conversation.updatedAt = DateTime.now();
      notifyListeners();
      await _saveConversations();
      // Deliberately *not* saving the macro scopes here. The engine never
      // touches MacroVariables (grep macro_engine.dart), so this was a second
      // full rewrite of the entire preferences store after every single reply —
      // on Android each write rewrites the whole file, avatars included.
    }
  }

  /// Joins provider-returned thinking with thinking parsed out of the reply
  /// text. A model normally produces one or the other, but a gateway that
  /// forwards both should not lose half of it.
  static String _joinThinking(String native, String inline) {
    final parts = [native.trim(), inline.trim()]..removeWhere((p) => p.isEmpty);
    return parts.join('\n\n');
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
    await _saveConversations();
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
    await _saveConversations();
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
      lorebookIds: List<String>.from(source.lorebookIds),
    );
    _conversations.insert(0, fork);
    _activeId = fork.id;
    notifyListeners();
    await _saveActiveId(fork.id);
    await _saveConversations();
    return fork.id;
  }

  /// Regenerates the assistant turn at [index]: keeps the existing reply as a
  /// swipe, drops the turns that followed it (they answered the old reply), and
  /// streams a fresh alternative from the history before it — the "retry"
  /// action. Both replies stay on the turn, so the ‹ › control can flip between
  /// them. A no-op for a user turn, an unknown thread, or while streaming.
  Future<void> regenerateMessage(String conversationId, int index) async {
    if (_streaming) return;
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    if (index < 0 || index >= conversation.messages.length) return;
    if (conversation.messages[index].isUser) return;
    conversation.messages.removeRange(index + 1, conversation.messages.length);
    await _generate(conversation, swipeInto: index);
  }

  /// Selects the swipe at [swipeIndex] on the message at [index] — the ‹ 1/2 ›
  /// control under a turn that has alternatives. The selected variant is what
  /// the chat shows and what later requests send; the others are kept.
  Future<void> setSwipe(
      String conversationId, int index, int swipeIndex) async {
    if (_streaming) return;
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    if (index < 0 || index >= conversation.messages.length) return;
    final message = conversation.messages[index];
    if (swipeIndex < 0 ||
        swipeIndex >= message.swipeCount ||
        swipeIndex == message.swipeIndex) {
      return;
    }
    conversation.messages[index] = message.withSwipe(swipeIndex);
    conversation.updatedAt = DateTime.now();
    notifyListeners();
    await _saveConversations();
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
    if (!_writable) return;
    await _storage.saveTokenizerConfig(next);
  }

  // --- Discover ------------------------------------------------------------

  DiscoverPrefs _discoverPrefs = const DiscoverPrefs();

  /// Which catalogue Discover was left on, plus its adult-content and ordering
  /// choices. The feed itself is never stored — it is a live view of a remote
  /// site.
  DiscoverPrefs get discoverPrefs => _discoverPrefs;

  Future<void> updateDiscoverPrefs(DiscoverPrefs next) async {
    if (next == _discoverPrefs) return;
    _discoverPrefs = next;
    notifyListeners();
    if (!_writable) return;
    await _storage.saveDiscoverPrefs(next);
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
    final maxContext = _effectiveMaxContext(preset, model);

    // Which lorebook entries this turn should carry. Scanned here so the
    // inspectors and the real send go through exactly the same code and see the
    // same history. One caveat worth knowing: an entry carrying a probability is
    // rolled per scan, so re-opening "View prompt" can show a different draw
    // than the request that was actually sent.
    final lore = _world.scan(
      books: lorebooksFor(conversation),
      history: priorTurns,
      charName: character?.displayName ?? conversation.characterName ?? '',
      userName: userName,
    );

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
        maxContext: maxContext,
        userName: userName,
        persona: persona,
        variables: MacroVariables(
          local: conversation.variables,
          global: _globalVars,
        ),
        input: input,
        lore: lore,
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
      // Same again for lore: a preset that carries neither world-info marker
      // would otherwise activate entries and then throw them away. Only the two
      // definition-anchored slots can be rescued this way — depth-injected lore
      // needs the builder, which already handled it.
      if (!_presetEmitsWorldInfo(preset)) {
        addPrefix(
          'World info',
          [lore.before, lore.after].where((s) => s.isNotEmpty).join('\n'),
        );
      }
      if (!_presetEmitsExamples(preset)) {
        addPrefix(
          'World info',
          [lore.exampleTop, lore.exampleBottom]
              .where((s) => s.isNotEmpty)
              .join('\n'),
        );
      }
      messages = <ChatMessage>[...prefix, ...built.messages];
      sections.addAll(built.sections);
      params = _paramsFor(preset);
    } else {
      // No preset: the original flat behaviour — stored persona then history,
      // plus the impersonated user persona (when set).
      addPrefix('Character (stored)', conversation.systemPrompt);
      if (persona.isNotEmpty) addPrefix('User persona', persona);
      // With no preset there are no slots to place lore in, so everything that
      // activated is prefixed as one block. Depth-injected entries lose their
      // depth here — there is nowhere to inject them — but their text still
      // reaches the model rather than being scanned for and then discarded.
      addPrefix(
        'World info',
        [
          lore.before,
          lore.exampleTop,
          lore.exampleBottom,
          lore.after,
          ...lore.injections.map((i) => i.text),
        ].where((s) => s.isNotEmpty).join('\n'),
      );
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

  /// Whether [preset] has an enabled world-info marker to put activated lore in.
  /// When it has not, [_assemble] prefixes the lore itself rather than letting a
  /// scan that found something end up sending nothing.
  bool _presetEmitsWorldInfo(Preset preset) {
    const worldMarkers = <String>{
      PromptId.worldInfoBefore,
      PromptId.worldInfoAfter,
    };
    for (final entry in preset.promptOrder) {
      if (entry.enabled && worldMarkers.contains(entry.identifier)) {
        final block = preset.blockById(entry.identifier);
        if (block != null && block.marker) return true;
      }
    }
    return false;
  }

  /// Whether [preset] has an enabled example-dialogue marker. Lore positioned
  /// around the examples travels with that marker, so without it the same
  /// rescue is needed.
  bool _presetEmitsExamples(Preset preset) {
    for (final entry in preset.promptOrder) {
      if (entry.enabled && entry.identifier == PromptId.dialogueExamples) {
        final block = preset.blockById(entry.identifier);
        if (block != null && block.marker) return true;
      }
    }
    return false;
  }

  /// The context window a turn is budgeted against.
  ///
  /// Normally the preset's own number. With "Use model max context if known" on,
  /// the selected model's published window wins whenever it is one the app
  /// recognises — so a preset downloaded with a GPT-3.5-era 4095 in it stops
  /// throttling a 200k model. An unrecognised model keeps the preset's value
  /// rather than guessing at one.
  int _effectiveMaxContext(Preset? preset, String model) {
    final fallback = preset?.maxContext ?? Preset.defaultMaxContext;
    if (preset == null || !preset.useMaxContext) return fallback;
    return knownMaxContext(model) ?? fallback;
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
        stream: p.stream,
        thinking: p.thinking,
        thinkingBudget: p.thinkingBudget,
        reasoningEffort: p.reasoningEffort,
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
    if (_writable) await _storage.saveModelCache(_modelCache);
    return models;
  }

  /// Writes streamed output into the live swipe of the turn at [index] — the one
  /// place a reply lands, whether it is a fresh turn or a regenerated swipe.
  void _replaceAt(
    Conversation conversation,
    int index, {
    required String content,
    bool error = false,
    String? reasoning,
    int? thinkingMs,
  }) {
    if (index < 0 || index >= conversation.messages.length) return;
    conversation.messages[index] = conversation.messages[index].copyWith(
      content: content,
      error: error,
      reasoning: reasoning,
      thinkingMs: thinkingMs,
    );
  }

  /// A stop with no text yet leaves nothing worth keeping — unless the model had
  /// already produced some thinking, which is worth showing on its own. An
  /// abandoned regeneration drops its empty swipe and hands the turn back to the
  /// reply that was live before it; an abandoned fresh turn goes away entirely.
  void _finishStopped(
    Conversation conversation,
    int index,
    String partial, {
    String reasoning = '',
    int? thinkingMs,
  }) {
    if (index < 0 || index >= conversation.messages.length) return;
    if (partial.trim().isEmpty && reasoning.trim().isEmpty) {
      final message = conversation.messages[index];
      if (message.hasSwipes) {
        conversation.messages[index] = message.removeSwipe(message.swipeIndex);
      } else {
        conversation.messages.removeAt(index);
      }
      return;
    }
    _replaceAt(conversation, index,
        content: partial, reasoning: reasoning, thinkingMs: thinkingMs);
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
