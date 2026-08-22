import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../app_info.dart';
import '../models/appearance.dart';
import '../models/character.dart';
import '../models/chat_interface.dart';
import '../models/conversation.dart';
import '../models/discover.dart';
import '../models/floating_image.dart';
import '../models/gallery_image.dart';
import '../models/lorebook.dart';
import '../models/message.dart';
import '../models/preset.dart';
import '../models/prompt_block.dart';
import '../models/provider.dart';
import '../models/summary.dart';
import '../services/chat_client.dart';
import '../services/avatar_store.dart';
import '../services/gallery_group.dart';
import '../services/jank_logger.dart';
import '../services/macro_context.dart';
import '../services/macro_engine.dart';
import '../services/model_context.dart';
import '../services/prompt_builder.dart';
import '../services/reasoning.dart';
import '../services/storage.dart';
import '../services/storage_report.dart';
import '../services/summarizer.dart';
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
  final List<GalleryImage> _gallery = <GalleryImage>[];
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

  /// Generates chat summaries in the background, off the chat's streaming path.
  final Summarizer _summarizer = Summarizer();

  /// Chat ids whose summary is being (re)generated right now — guards against
  /// firing a second run for the same chat while one is in flight.
  final Set<String> _summarizing = <String>{};

  /// A pending in-app notice from a completed summary, and a monotonically
  /// increasing sequence so a listener can show it exactly once.
  String? _summaryNotice;
  int _summaryNoticeSeq = 0;

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
  List<GalleryImage> get gallery => List.unmodifiable(_gallery);
  List<Preset> get presets => List.unmodifiable(_presets);
  Appearance get appearance => _appearance;
  ChatInterface get chatInterface => _chatInterface;
  bool get ready => _ready;
  bool get streaming => _streaming;

  /// Whether Flutter's performance overlay is shown over the whole app — a
  /// diagnostic the user can flip from Appearance settings. Two stacked graphs:
  /// the top is the UI (build/layout/paint) thread, the bottom is the raster
  /// (GPU compositing) thread; a bar crossing the green line is a dropped frame.
  /// Deliberately not persisted — it is a "show me what's slow right now" switch,
  /// not a preference.
  bool _perfOverlay = false;
  bool get perfOverlay => _perfOverlay;
  void togglePerfOverlay() {
    _perfOverlay = !_perfOverlay;
    notifyListeners();
  }

  /// **Temporary.** Records janky frames + a breadcrumb trail to a downloadable
  /// log, so a real device can say whether a stutter is UI-thread (build) or GPU
  /// (raster) and what was running — see [JankLogger]. Not persisted.
  bool get jankLogging => JankLogger.instance.isOn;
  Future<void> toggleJankLogging() async {
    if (JankLogger.instance.isOn) {
      await JankLogger.instance.stop();
    } else {
      await JankLogger.instance.start();
    }
    notifyListeners();
  }

  /// Whether a float's position is persisted on a debounce (the real-app
  /// behaviour — see [settleFloatingImage]) or written straight away. Tests turn
  /// it off so a manipulation leaves no pending timer to trip the test binding.
  bool debounceFloatSaves = true;

  /// Writes any debounced float position straight away — for a test, or for the
  /// app being backgrounded before the timer fires.
  Future<void> flushPendingSaves() async {
    if (_floatPersist?.isActive ?? false) {
      _floatPersist!.cancel();
      _floatPersist = null;
      if (_writable) await _storage.saveConversations(_conversations);
    }
  }

  /// Debounces persisting a float's new position/size — see [settleFloatingImage].
  Timer? _floatPersist;

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
    _gallery
      ..clear()
      ..addAll(await _storage.loadGallery());
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

  /// The thread with [id], or null when there is none. Public so a screen can
  /// hold an id rather than a [Conversation] object and always read the live one.
  Conversation? conversationById(String id) => _conversationById(id);

  /// The character the user is impersonating in [conversation], or null when
  /// they are speaking as themselves.
  Character? impersonationFor(Conversation conversation) =>
      characterFor(conversation, conversation.impersonateId);

  // --- Per-chat settings ---------------------------------------------------

  /// The chat-style settings that apply to [conversation]: its own copy when it
  /// has one, otherwise the app-wide settings.
  ChatInterface interfaceFor(Conversation? conversation) =>
      conversation?.interfaceOverride ?? _chatInterface;

  /// Whether [conversation] is styled by its own copy rather than the app-wide
  /// settings.
  bool hasInterfaceOverride(Conversation conversation) =>
      conversation.interfaceOverride != null;

  /// The character [id] resolves to *inside* [conversation]: the chat's own
  /// definition when one is stored and overriding is on, otherwise the roster's.
  ///
  /// Everything that reads a character for a thread — the prompt, the bubbles,
  /// the inspectors — goes through here, so an override is impossible to apply
  /// in one place and forget in another.
  Character? characterFor(Conversation? conversation, String? id) {
    if (id == null) return null;
    if (conversation != null && conversation.overrideDefinitions) {
      final override = conversation.characterOverrides[id];
      if (override != null) return override;
    }
    return characterById(id);
  }

  /// Applies [change] to the thread with [conversationId] and persists.
  Future<void> _editConversation(
    String conversationId,
    void Function(Conversation) change,
  ) async {
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    change(conversation);
    conversation.updatedAt = DateTime.now();
    notifyListeners();
    await _saveConversations();
  }

  /// Sets (or clears, with a null [image]) the picture drawn behind this thread.
  /// [image] is a `local:` reference into the pictures directory or an http(s)
  /// URL; [opacity] fades it so text stays readable.
  Future<void> setChatBackground(
    String conversationId,
    String? image, {
    double? opacity,
  }) async {
    await _editConversation(conversationId, (c) {
      final trimmed = image?.trim();
      c.backgroundImage =
          (trimmed == null || trimmed.isEmpty) ? null : trimmed;
      if (opacity != null) c.backgroundOpacity = opacity.clamp(0, 1).toDouble();
    });
    // A background that is no longer referenced is a file nobody will ever look
    // at again.
    await _sweepAvatars();
  }

  /// Writes [bytes] into the pictures directory and returns the `local:`
  /// reference to persist, or null when there is nowhere to write it.
  ///
  /// Kept separate from [setChatBackground] because a picture is chosen while a
  /// screen is still editing a draft: the file is written straight away, the
  /// reference is held by the caller, and a file the caller never commits is
  /// collected by the next sweep.
  Future<String?> storePicture(Uint8List bytes) async {
    final store = _avatars;
    if (store == null || bytes.isEmpty) return null;
    try {
      return await store.write(bytes);
    } catch (error) {
      debugPrint('MaiChat: could not store a picture ($error)');
      return null;
    }
  }

  /// Gives this thread its own copy of the chat-style settings.
  Future<void> saveChatInterfaceOverride(
    String conversationId,
    ChatInterface ui,
  ) =>
      _editConversation(conversationId, (c) {
        c.interfaceOverride = ChatInterface.fromJson(ui.toJson());
      });

  /// Drops a thread's own chat-style copy so it follows the app-wide settings
  /// again — the counterpart of [saveChatInterfaceOverride], for the same reason
  /// [clearChatPresetOverride] exists.
  Future<void> clearChatInterfaceOverride(String conversationId) =>
      _editConversation(conversationId, (c) => c.interfaceOverride = null);

  /// Turns per-chat character definitions on or off for this thread. The stored
  /// overrides are kept either way, so switching back on restores them.
  Future<void> setOverrideDefinitions(
    String conversationId,
    bool enabled,
  ) =>
      _editConversation(
          conversationId, (c) => c.overrideDefinitions = enabled);

  /// Stores [character] as this thread's own definition of it, leaving the
  /// roster untouched. Switches overriding on, since an override nobody honours
  /// is indistinguishable from a lost edit.
  Future<void> saveChatCharacterOverride(
    String conversationId,
    Character character,
  ) async {
    await _editConversation(conversationId, (c) {
      c.characterOverrides[character.id] = character.clone();
      c.overrideDefinitions = true;
    });
    await _storeOverrideAvatar(conversationId, character.id);
  }

  /// Drops one per-chat definition, so the thread sees the roster's card again.
  Future<void> clearChatCharacterOverride(
    String conversationId,
    String characterId,
  ) async {
    await _editConversation(
        conversationId, (c) => c.characterOverrides.remove(characterId));
    await _sweepAvatars();
  }

  /// Moves a per-chat override's picture into the pictures directory, the same
  /// way [_storeAvatar] does for the roster — an override can carry a freshly
  /// picked photo, and base64 in the preferences store is what [AvatarStore]
  /// exists to prevent.
  Future<void> _storeOverrideAvatar(
      String conversationId, String characterId) async {
    final store = _avatars;
    if (store == null) return;
    final conversation = _conversationById(conversationId);
    final override = conversation?.characterOverrides[characterId];
    if (override == null) return;
    final stored = await store.adopt(override.avatar);
    if (stored == override.avatar) return;
    override.avatar = stored;
    await _saveConversations();
  }

  /// Links [character] to an existing thread that had none — the "+" in the
  /// chat's Characters involved list. Seeds the stored persona snapshot so the
  /// definition survives the character later being deleted, and drops in the
  /// greeting when the thread is still empty.
  Future<void> attachCharacter(
    String conversationId,
    Character character,
  ) async {
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    conversation.characterId = character.id;
    conversation.characterName = character.displayName;
    conversation.systemPrompt =
        _mergedPrompt(character, conversation.systemPrompt);
    if (conversation.messages.isEmpty) {
      final swipes = _greetingSwipes(character);
      if (swipes.isNotEmpty) {
        conversation.messages.add(
          ChatMessage(role: 'assistant', swipes: swipes),
        );
      }
    }
    if (conversation.title.trim().isEmpty ||
        conversation.title == 'New chat') {
      conversation.title = character.displayName;
    }
    conversation.updatedAt = DateTime.now();
    notifyListeners();
    await _saveConversations();
  }

  /// Unlinks the thread's character (or its impersonated identity, when
  /// [impersonation] is set) — "Remove" in the Characters involved list. The
  /// messages stay; only the definition behind them goes.
  Future<void> detachCharacter(
    String conversationId, {
    bool impersonation = false,
  }) async {
    await _editConversation(conversationId, (c) {
      if (impersonation) {
        c.impersonateId = null;
        c.impersonateName = null;
      } else {
        final removed = c.characterId;
        c.characterId = null;
        c.characterName = null;
        if (removed != null) c.characterOverrides.remove(removed);
      }
    });
    await _sweepAvatars();
  }

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

  // --- Group chat ----------------------------------------------------------

  /// Whether the group-chat feature is switched on app-wide. Read from the
  /// global interface so a per-chat style copy can't silently disable it.
  bool get groupChatsEnabled => _chatInterface.groupChatsEnabled;

  /// The AI characters taking part in [conversation], in speaking order,
  /// resolved against the roster (and per-chat overrides). Characters that no
  /// longer resolve are dropped, so a deleted member never crashes a send.
  List<Character> participantsOf(Conversation conversation) => [
        for (final id in conversation.memberIds)
          if (characterFor(conversation, id) != null)
            characterFor(conversation, id)!,
      ];

  /// Adds [character] to [conversationId] as a group member. The first add to a
  /// one-to-one thread seeds the roster with the existing character first, so
  /// the original speaker keeps its place; the thread becomes a group once a
  /// second member is present. Idempotent — re-adding a member is a no-op.
  Future<void> addParticipant(
    String conversationId,
    Character character,
  ) async {
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    final members = conversation.participantIds.isNotEmpty
        ? conversation.participantIds.toList()
        : (conversation.characterId == null
            ? <String>[]
            : <String>[conversation.characterId!]);
    if (members.contains(character.id)) return;
    members.add(character.id);
    conversation.participantIds
      ..clear()
      ..addAll(members);
    // Keep the primary pointer valid: an empty thread's first member becomes the
    // bound character (and names the thread), matching a one-to-one start.
    conversation.characterId ??= members.first;
    conversation.characterName ??= character.displayName;
    if (conversation.messages.isEmpty &&
        (conversation.title.trim().isEmpty ||
            conversation.title == 'New chat')) {
      conversation.title = character.displayName;
    }
    conversation.updatedAt = DateTime.now();
    notifyListeners();
    await _saveConversations();
  }

  /// Removes a member from a group chat. Dropping back to a single member turns
  /// the thread one-to-one again (the lone survivor becomes the bound
  /// character); the transcript and each turn's speaker tag are left untouched.
  Future<void> removeParticipant(
    String conversationId,
    String characterId,
  ) async {
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    final members = conversation.participantIds.toList()..remove(characterId);
    if (members.length <= 1) {
      // No longer a group: collapse to the plain one-to-one shape.
      conversation.participantIds.clear();
      final sole = members.isNotEmpty
          ? members.first
          : (conversation.characterId == characterId
              ? null
              : conversation.characterId);
      conversation.characterId = sole;
      conversation.characterName =
          characterFor(conversation, sole)?.displayName;
      // Auto-reply is a group-only notion; there is no roster to choose from now.
      conversation.groupResponder = null;
    } else {
      conversation.participantIds
        ..clear()
        ..addAll(members);
      if (conversation.characterId == characterId) {
        conversation.characterId = members.first;
        conversation.characterName =
            characterFor(conversation, members.first)?.displayName;
      }
      // The chosen auto-responder just left; drop back to manual rather than
      // silently answering as someone else.
      if (conversation.groupResponder == characterId) {
        conversation.groupResponder = null;
      }
    }
    conversation.updatedAt = DateTime.now();
    notifyListeners();
    await _saveConversations();
    await _sweepAvatars();
  }

  /// The character whose turn it is to reply next in [conversation] — round
  /// robin over the participant order, picking the member after whoever spoke
  /// last. Falls back to the first member when no member has spoken yet, and to
  /// the single character in a one-to-one thread. Null when nothing resolves.
  Character? nextSpeaker(Conversation conversation) {
    final members = participantsOf(conversation);
    if (members.isEmpty) return null;
    if (members.length == 1) return members.first;
    // The most recent assistant turn attributed to a current member sets the
    // anchor; the reply goes to the next member in order.
    for (final message in conversation.messages.reversed) {
      if (message.role != 'assistant' || message.speakerId == null) continue;
      final at = members.indexWhere((c) => c.id == message.speakerId);
      if (at >= 0) return members[(at + 1) % members.length];
    }
    return members.first;
  }

  /// Makes a specific member of the active group chat reply now — the group
  /// bar's "tap a chip to let them speak" action. No user turn is added; the
  /// character responds to the conversation as it stands.
  Future<void> speakAs(String characterId) async {
    if (_streaming) return;
    final conversation = active;
    final character = characterFor(conversation, characterId);
    if (character == null) return;
    await _generate(conversation, responder: character);
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
    // Their photos are kept, just detached: a picture the user took the trouble
    // to import and tag is worth more than the card it happened to be filed
    // under, and it still shows in the whole-app gallery. (Agnai deletes them
    // with the character; this deliberately does not.)
    var detached = false;
    for (final image in _gallery) {
      if (image.characterId == id) {
        image.characterId = null;
        image.updatedAt = DateTime.now();
        detached = true;
      }
    }
    // The per-chat avatar choices for a character nobody can reach are dead
    // weight, and holding them would keep their picture files alive for ever.
    var touchedChats = false;
    for (final conversation in _conversations) {
      if (conversation.avatarOverrides.remove(id) != null) touchedChats = true;
    }
    notifyListeners();
    await _persistCharacters();
    if (detached) await _persistGallery();
    if (touchedChats) await _saveConversations();
    await _sweepAvatars();
  }

  /// Deletes picture files nothing refers to any more. The keep-list has to name
  /// every place a picture can be referenced from — a chat's background, a
  /// per-chat character override, a gallery entry, a character's extra avatars and
  /// a per-chat avatar choice all live outside the roster's `avatar` field, and a
  /// sweep that forgot one would delete a picture still on screen.
  Future<void> _sweepAvatars() async {
    final store = _avatars;
    if (store == null || !_writable) return;
    await store.sweep([
      ..._characters.map((c) => c.avatar),
      ..._characters.expand((c) => c.avatars),
      ..._lorebooks.map((b) => b.thumbnail),
      ..._gallery.map((g) => g.image),
      for (final c in _conversations) ...[
        c.backgroundImage ?? '',
        ...c.characterOverrides.values.map((o) => o.avatar),
        ...c.characterOverrides.values.expand((o) => o.avatars),
        ...c.avatarOverrides.values,
        // A float can carry a picture the gallery never held (an avatar off an
        // imported card), and it is on screen right now.
        ...c.floatingImages.map((f) => f.imageRef),
      ],
    ]);
  }

  /// Where picture files live, once resolved — used by the Storage screen to
  /// list and size them. Null when the platform never told us where to put them.
  Directory? get imageDirectory => _avatars?.directory ?? avatarDirectory;

  /// Every picture file on disk with its size and mtime, largest first — the
  /// raw material behind the Storage screen's Images category and its grid.
  Future<List<ImageFileStat>> imageFiles() async {
    final dir = imageDirectory;
    if (dir == null || !dir.existsSync()) return const [];
    final files = <ImageFileStat>[];
    try {
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final stat = entity.statSync();
        files.add((
          name: entity.uri.pathSegments.last,
          bytes: stat.size,
          modified: stat.modified,
        ));
      }
    } catch (error) {
      debugPrint('MaiChat: could not list picture files ($error)');
    }
    files.sort((a, b) => b.bytes.compareTo(a.bytes));
    return files;
  }

  /// The whole storage picture behind Settings ▸ Storage: prefs blobs bucketed
  /// by category plus the picture files on disk (the bulk, invisible to prefs).
  Future<StorageReport> storageReport() async {
    final prefsUsage = await _storage.usage();
    final images = await imageFiles();
    return StorageReport.build(
      prefsUsage: prefsUsage,
      imageFiles: images,
      itemCounts: {
        StorageCategory.chats: _conversations.length,
        StorageCategory.characters: _characters.length,
        StorageCategory.lorebooks: _lorebooks.length,
        StorageCategory.presets: _presets.length,
        StorageCategory.gallery: _gallery.length,
      },
    );
  }

  /// Deletes the named picture files. This is the escape hatch for a store that
  /// has grown out of proportion, so it deletes the *file* directly and does not
  /// chase down references — a chat background or avatar pointing at a deleted
  /// file simply falls back to nothing, which is exactly what the on-screen
  /// caution ("May affect your chat history") warns about. A referenced file is
  /// never removed by the periodic sweep, so this is the only way to reclaim one.
  Future<void> deleteImageFiles(Iterable<String> names) async {
    final dir = imageDirectory;
    if (dir == null || !_writable) return;
    var removed = false;
    for (final name in names) {
      // Never let a name climb out of the pictures directory.
      if (name.isEmpty || name.contains('/') || name.contains('\\')) continue;
      final file = File('${dir.path}/$name');
      try {
        if (file.existsSync()) {
          file.deleteSync();
          removed = true;
        }
      } catch (error) {
        debugPrint('MaiChat: could not delete a picture file ($error)');
      }
    }
    if (removed) notifyListeners();
  }

  /// Drops the rebuild-from-scratch caches (model lists, Discover state). Safe:
  /// nothing the user authored is lost.
  Future<void> clearCaches() async {
    if (!_writable) return;
    _modelCache.clear();
    await _storage.clearCache();
    notifyListeners();
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

  /// The lorebook [id] resolves to *inside* [conversation]: the chat's own
  /// override copy when one is stored, otherwise the global library book. The
  /// single resolution point (mirrors [characterFor]) so a per-chat override is
  /// impossible to apply in one place and forget in another.
  Lorebook? lorebookFor(Conversation? conversation, String id) {
    if (conversation != null) {
      final override = conversation.lorebookOverrides[id];
      if (override != null) return override;
    }
    return lorebookById(id);
  }

  /// Whether [conversation] carries a per-chat override copy of book [id].
  bool hasLorebookOverride(Conversation conversation, String id) =>
      conversation.lorebookOverrides.containsKey(id);

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
      final book = lorebookFor(conversation, id);
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
      if (conversation.lorebookOverrides.remove(id) != null) touched = true;
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

  /// Saves [book] as a per-chat override for [conversationId] — the "save for
  /// this chat only" path from the lorebook editor opened inside a chat. The
  /// global library book is untouched; other chats keep seeing the shared copy.
  /// The chat is switched on for the book if it was not already.
  Future<void> saveChatLorebookOverride(
      String conversationId, Lorebook book) async {
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    book.updatedAt = DateTime.now();
    await _storeThumbnail(book);
    conversation.lorebookOverrides[book.id] = book;
    if (!conversation.lorebookIds.contains(book.id)) {
      conversation.lorebookIds.add(book.id);
    }
    conversation.updatedAt = DateTime.now();
    notifyListeners();
    await _saveConversations();
  }

  /// Drops [conversationId]'s override copy of book [id], so it falls back to the
  /// shared library version again.
  Future<void> clearChatLorebookOverride(
      String conversationId, String id) async {
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    if (conversation.lorebookOverrides.remove(id) != null) {
      conversation.updatedAt = DateTime.now();
      notifyListeners();
      await _saveConversations();
    }
  }

  // --- Summary -------------------------------------------------------------

  /// A pending in-app notice from the last completed summary (null once shown),
  /// with a sequence number so a listener can react to it exactly once.
  String? get summaryNotice => _summaryNotice;
  int get summaryNoticeSeq => _summaryNoticeSeq;
  void consumeSummaryNotice() => _summaryNotice = null;

  /// Whether [conversation] has a summary run in flight.
  bool isSummarizing(Conversation conversation) =>
      _summarizing.contains(conversation.id);

  /// Turns the summary feature on/off for a chat, creating the config on first
  /// enable. Does not itself summarise — that happens on the next send (or via
  /// [summarizeNow]).
  Future<void> setSummaryEnabled(String conversationId, bool enabled) async {
    final c = _conversationById(conversationId);
    if (c == null) return;
    final cfg = c.summary ?? ChatSummary();
    cfg.enabled = enabled;
    if (cfg.title.trim().isEmpty) cfg.title = c.title;
    c.summary = cfg;
    c.updatedAt = DateTime.now();
    notifyListeners();
    await _saveConversations();
  }

  /// Replaces a chat's whole [ChatSummary] (config edits, manual segment edits,
  /// or an imported summary).
  Future<void> setSummary(String conversationId, ChatSummary summary) async {
    final c = _conversationById(conversationId);
    if (c == null) return;
    c.summary = summary;
    c.updatedAt = DateTime.now();
    notifyListeners();
    await _saveConversations();
  }

  /// Called after every reply: summarises when the interval has elapsed. Fire and
  /// forget — it runs in the background and saves itself.
  Future<void> maybeSummarize(Conversation conversation) async {
    final cfg = conversation.summary;
    if (cfg == null || !cfg.enabled || cfg.interval <= 0) return;
    if (_summarizing.contains(conversation.id)) return;
    if (conversation.messages.length - cfg.lastSummarizedIndex < cfg.interval) {
      return;
    }
    await _runSummary(conversation, cfg, force: false);
  }

  /// Summarises the messages since the last run right now, even if the interval
  /// has not elapsed (the "Summarise now" button).
  Future<void> summarizeNow(String conversationId) async {
    final c = _conversationById(conversationId);
    final cfg = c?.summary;
    if (c == null || cfg == null) return;
    await _runSummary(c, cfg, force: true);
  }

  /// Wipes the summary and rebuilds it from the start (the "Re-summarise" button).
  Future<void> resummarize(String conversationId) async {
    final c = _conversationById(conversationId);
    final cfg = c?.summary;
    if (c == null || cfg == null) return;
    cfg.segments.clear();
    cfg.lastSummarizedIndex = 0;
    await _runSummary(c, cfg, force: true);
  }

  /// Removes a chat's summary entirely (the full-screen "delete" action).
  Future<void> deleteSummary(String conversationId) async {
    final c = _conversationById(conversationId);
    if (c == null || c.summary == null) return;
    c.summary = null;
    c.updatedAt = DateTime.now();
    notifyListeners();
    await _saveConversations();
  }

  /// Every chat that currently has a summary, newest-updated first — the source
  /// for the Library's global "Summary" section.
  List<Conversation> get conversationsWithSummary => [
        for (final c in _conversations)
          if (c.summary != null) c,
      ];

  // --- Gallery -------------------------------------------------------------

  Future<void> _persistGallery() async {
    if (!_writable) return;
    await _storage.saveGallery(_gallery);
  }

  GalleryImage? galleryImageById(String? id) {
    if (id == null) return null;
    for (final image in _gallery) {
      if (image.id == id) return image;
    }
    return null;
  }

  /// The pictures filed under [characterId], newest first. A null [characterId]
  /// asks for the unattached ones, not for everything — [gallery] is everything.
  List<GalleryImage> galleryFor(String? characterId) => sortImages(
        _gallery.where((image) => image.characterId == characterId).toList(),
        GallerySort.newest,
      );

  /// Every tag across the whole gallery, sorted — what the tag-filter sheet
  /// lists.
  List<String> get galleryTags {
    final tags = <String>{};
    for (final image in _gallery) {
      tags.addAll(image.tags);
    }
    return tags.toList()..sort();
  }

  /// How many pictures [characterId] has, for the "N photos" line on a row.
  int galleryCountFor(String? characterId) =>
      _gallery.where((image) => image.characterId == characterId).length;

  /// Files each of [pictures] into the gallery, returning what was added.
  ///
  /// The bytes go through [storePicture], so a photo becomes a file in the
  /// pictures directory and only its reference is stored — the same path every
  /// other picture in the app takes. Several pictures added at once share [tags]
  /// and, when there is more than one, are numbered from [title].
  Future<List<GalleryImage>> addGalleryImages(
    List<Uint8List> pictures, {
    String? characterId,
    String title = '',
    List<String> tags = const <String>[],
  }) async {
    if (pictures.isEmpty) return const <GalleryImage>[];
    final added = <GalleryImage>[];
    final base = title.trim();
    for (var i = 0; i < pictures.length; i++) {
      final ref = await storePicture(pictures[i]);
      if (ref == null) continue; // Nowhere to write it; skip rather than lie.
      added.add(GalleryImage.create(
        image: ref,
        title: base.isEmpty
            ? ''
            : pictures.length == 1
                ? base
                : '$base ${i + 1}',
        tags: List<String>.from(tags),
        characterId: characterId,
      ));
    }
    if (added.isEmpty) return added;
    _gallery.insertAll(0, added);
    notifyListeners();
    await _persistGallery();
    return added;
  }

  /// Replaces the stored record sharing [image]'s id (title, tags, owner, star).
  Future<void> saveGalleryImage(GalleryImage image) async {
    final index = _gallery.indexWhere((i) => i.id == image.id);
    image.updatedAt = DateTime.now();
    if (index == -1) {
      _gallery.insert(0, image);
    } else {
      _gallery[index] = image;
    }
    notifyListeners();
    await _persistGallery();
  }

  Future<void> toggleGalleryStar(String id) async {
    final image = galleryImageById(id);
    if (image == null) return;
    image.starred = !image.starred;
    image.updatedAt = DateTime.now();
    notifyListeners();
    await _persistGallery();
  }

  /// Files a picture under [characterId] (or detaches it with null).
  Future<void> assignGalleryImage(String id, String? characterId) async {
    final image = galleryImageById(id);
    if (image == null || image.characterId == characterId) return;
    image.characterId = characterId;
    image.updatedAt = DateTime.now();
    notifyListeners();
    await _persistGallery();
  }

  /// Notes that a picture was opened, which is what the "Last viewed" ordering
  /// sorts on. Deliberately does not touch [GalleryImage.updatedAt] — looking at
  /// something is not editing it.
  Future<void> touchGalleryImage(String id) async {
    final image = galleryImageById(id);
    if (image == null) return;
    image.lastViewed = DateTime.now();
    // No notifyListeners: nothing visible changes, and rebuilding the grid the
    // instant a picture opens would be work for nothing. The new order is picked
    // up the next time the list is built.
    await _persistGallery();
  }

  /// Deletes a picture and unpicks every reference to it.
  ///
  /// A gallery picture can be worn as a character's avatar, sit in a character's
  /// pool, or be a chat's own choice for that character — deleting the record
  /// without clearing those would leave avatars pointing at a file the next sweep
  /// removes, i.e. characters whose picture silently becomes a monogram later.
  /// So the cascade is part of the delete, as it is in Agnai's `deleteGalleryImage`.
  Future<void> deleteGalleryImages(Iterable<String> ids) async {
    final wanted = ids.toSet();
    if (wanted.isEmpty) return;
    final refs = <String>{};
    for (final id in wanted) {
      final image = galleryImageById(id);
      if (image != null) refs.add(image.image);
    }
    _gallery.removeWhere((image) => wanted.contains(image.id));

    var touchedCharacters = false;
    for (final character in _characters) {
      if (_dropAvatarRefs(character, refs)) touchedCharacters = true;
    }

    var touchedChats = false;
    for (final conversation in _conversations) {
      // A chat's own choice for a character falls back to the card's avatar.
      conversation.avatarOverrides.removeWhere((_, ref) {
        final gone = refs.contains(ref);
        if (gone) touchedChats = true;
        return gone;
      });
      // Per-chat character definitions carry their own copy of the pool.
      for (final override in conversation.characterOverrides.values) {
        if (_dropAvatarRefs(override, refs)) touchedChats = true;
      }
      // A float showing a deleted picture has nothing left to draw.
      final before = conversation.floatingImages.length;
      conversation.floatingImages.removeWhere(
        (f) => wanted.contains(f.imageId) || refs.contains(f.imageRef),
      );
      if (conversation.floatingImages.length != before) touchedChats = true;
    }

    notifyListeners();
    await _persistGallery();
    if (touchedCharacters) await _persistCharacters();
    if (touchedChats) await _saveConversations();
    await _sweepAvatars();
  }

  Future<void> deleteGalleryImage(String id) =>
      deleteGalleryImages(<String>[id]);

  /// Takes [refs] out of [character]'s pool, and off its face when it was wearing
  /// one: the next pooled picture takes over, or it goes back to a monogram.
  /// Returns whether anything changed.
  bool _dropAvatarRefs(Character character, Set<String> refs) {
    var changed = false;
    if (character.avatars.any(refs.contains)) {
      character.avatars.removeWhere(refs.contains);
      changed = true;
    }
    if (refs.contains(character.avatar) && character.avatar.isNotEmpty) {
      character.avatar =
          character.avatars.isEmpty ? '' : character.avatars.removeAt(0);
      changed = true;
    }
    if (changed) character.updatedAt = DateTime.now();
    return changed;
  }

  // --- Avatars from the gallery --------------------------------------------

  /// Every picture [character] can wear, in order: the one it is wearing first,
  /// then its pool, de-duplicated.
  ///
  /// This is the single definition of "a character's avatars" — the swipe viewer,
  /// the "set as avatar" toggle and the delete cascade all read it, so the pool
  /// cannot mean one thing in one place and something else in another. Mirrors
  /// Agnai's `getCharacterAvatars`.
  List<String> avatarPoolFor(Character character) =>
      _pool([character.avatar, ...character.avatars]);

  /// Every picture [characterId] can wear **inside [conversation]**.
  ///
  /// Not simply [avatarPoolFor] of the resolved card: a thread with per-chat
  /// character definitions holds a *frozen copy* of the card, so a picture added
  /// to the roster afterwards was invisible in that chat — the avatar viewer
  /// opened on one picture with nothing to swipe, which is precisely the "multiple
  /// avatars don't work" report. A per-chat override is about a character's text,
  /// never about which pictures exist, so both pools are unioned here and the
  /// chat's own choice leads.
  List<String> avatarPoolIn(Conversation? conversation, String characterId) {
    final roster = characterById(characterId);
    final override = conversation?.overrideDefinitions == true
        ? conversation?.characterOverrides[characterId]
        : null;
    return _pool([
      if (conversation != null) conversation.avatarOverrides[characterId] ?? '',
      if (override != null) ...[override.avatar, ...override.avatars],
      if (roster != null) ...[roster.avatar, ...roster.avatars],
    ]);
  }

  /// Trims, drops empties and de-duplicates, keeping the first spelling.
  List<String> _pool(Iterable<String> refs) {
    final out = <String>[];
    for (final ref in refs) {
      final trimmed = ref.trim();
      if (trimmed.isEmpty || out.contains(trimmed)) continue;
      out.add(trimmed);
    }
    return out;
  }

  /// Which picture [character] wears inside [conversation]: the chat's own choice
  /// when it has one, otherwise the card's.
  ///
  /// The counterpart of [interfaceFor] and [characterFor] — read a chat avatar
  /// through here and nowhere else, so a per-chat choice cannot be honoured by the
  /// bubbles and forgotten by everything else.
  String avatarRefFor(Conversation? conversation, Character character) {
    final override = conversation?.avatarOverrides[character.id];
    if (override != null && override.trim().isNotEmpty) return override.trim();
    return character.avatar;
  }

  /// Whether [ref] is already one of [character]'s avatars.
  bool isAvatarOf(Character character, String ref) =>
      avatarPoolFor(character).contains(ref.trim());

  /// Adds [ref] to [character]'s pool — the "set as avatar" action. A character
  /// with no picture yet wears it straight away, so the action visibly does
  /// something the first time it is used.
  Future<void> addAvatarToPool(String characterId, String ref) async {
    final character = characterById(characterId);
    final trimmed = ref.trim();
    if (character == null || trimmed.isEmpty) return;
    if (isAvatarOf(character, trimmed)) return;
    if (character.avatar.trim().isEmpty) {
      character.avatar = trimmed;
    } else {
      character.avatars.add(trimmed);
    }
    character.updatedAt = DateTime.now();
    notifyListeners();
    await _persistCharacters();
  }

  /// Takes [ref] back out of [character]'s pool.
  Future<void> removeAvatarFromPool(String characterId, String ref) async {
    final character = characterById(characterId);
    if (character == null) return;
    if (!_dropAvatarRefs(character, <String>{ref.trim()})) return;
    notifyListeners();
    await _persistCharacters();
  }

  /// Makes [ref] the picture [character] wears everywhere ("set as default").
  /// The one it was wearing stays in the pool, so this is a reorder rather than a
  /// replacement — nothing is lost by trying a different face.
  Future<void> setDefaultAvatar(String characterId, String ref) async {
    final character = characterById(characterId);
    final trimmed = ref.trim();
    if (character == null || trimmed.isEmpty) return;
    if (character.avatar == trimmed) return;
    final previous = character.avatar.trim();
    character.avatars.remove(trimmed);
    if (previous.isNotEmpty && !character.avatars.contains(previous)) {
      character.avatars.insert(0, previous);
    }
    character.avatar = trimmed;
    character.updatedAt = DateTime.now();
    notifyListeners();
    await _persistCharacters();
  }

  /// Makes [ref] the picture [characterId] wears **in this chat only**, or clears
  /// the choice when [ref] is null so the card's own picture shows again.
  Future<void> setChatAvatar(
    String conversationId,
    String characterId,
    String? ref,
  ) async {
    await _editConversation(conversationId, (c) {
      final trimmed = ref?.trim() ?? '';
      if (trimmed.isEmpty) {
        c.avatarOverrides.remove(characterId);
      } else {
        c.avatarOverrides[characterId] = trimmed;
      }
    });
    await _sweepAvatars();
  }

  // --- Floating pictures ---------------------------------------------------

  /// Pins a gallery picture over a chat. Floating the same picture twice just
  /// raises the one already there rather than stacking a duplicate on top of it.
  Future<void> floatImage(String conversationId, String imageId) async {
    final image = galleryImageById(imageId);
    if (image == null) return;
    await _addFloat(conversationId, FloatingImage(imageId: imageId));
    await touchGalleryImage(imageId);
  }

  /// Pins a picture that is not a gallery record — an avatar that arrived on an
  /// imported card, say. Floating is about looking at a picture, so anything the
  /// app can draw can float; a gallery entry is not a prerequisite.
  ///
  /// When [ref] *is* a gallery picture this defers to [floatImage], so the float
  /// stays tied to the record and follows its edits and deletion.
  Future<void> floatPictureRef(String conversationId, String ref) async {
    final trimmed = ref.trim();
    if (trimmed.isEmpty) return;
    final known = _gallery.where((i) => i.image == trimmed).firstOrNull;
    if (known != null) {
      await floatImage(conversationId, known.id);
      return;
    }
    await _addFloat(conversationId, FloatingImage(imageRef: trimmed));
  }

  /// Mutates a chat's floating pictures and notifies listeners — but never
  /// saves. Floats are in-memory only (see [Conversation.toJson]); persisting
  /// them was the whole-store re-save behind the "placing it" hitch, and they
  /// deliberately vanish when the app is fully closed.
  void _mutateFloats(String conversationId, void Function(Conversation) change) {
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    change(conversation);
    notifyListeners();
  }

  /// Adds [float] to a chat, or raises the matching one when it is already there.
  Future<void> _addFloat(String conversationId, FloatingImage float) async =>
      _mutateFloats(conversationId, (c) {
        final existing =
            c.floatingImages.indexWhere((f) => f.key == float.key);
        if (existing != -1) {
          c.floatingImages.add(c.floatingImages.removeAt(existing));
          return;
        }
        // Each new float is offset a little from the last so a run of them fans
        // out instead of hiding one another exactly. These are centre positions.
        final step = c.floatingImages.length % 4;
        float
          ..x = FloatingImage.clampFraction(0.2 + step * 0.05)
          ..y = FloatingImage.clampFraction(0.24 + step * 0.06);
        c.floatingImages.add(float);
      });

  /// Takes [float] back off the chat.
  Future<void> unfloatImage(String conversationId, FloatingImage float) async =>
      _mutateFloats(conversationId,
          (c) => c.floatingImages.removeWhere((f) => f.key == float.key));

  Future<void> clearFloatingImages(String conversationId) async =>
      _mutateFloats(conversationId, (c) => c.floatingImages.clear());

  /// Commits where a float ended up, and optionally brings it to the front.
  ///
  /// Called when a gesture *finishes* — never while one runs. Updates the
  /// in-memory geometry only: floats are not persisted (see
  /// [Conversation.toJson]), so there is nothing to save. Deliberately does
  /// **not** notifyListeners — the floating layer already tracks the live
  /// geometry and is showing the settled position, and a notify here would
  /// rebuild the whole chat for a picture that just moved.
  Future<void> settleFloatingImage(
    String conversationId,
    FloatingImage float, {
    double? x,
    double? y,
    double? width,
    double? rotation,
    bool raise = false,
  }) async {
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    final index =
        conversation.floatingImages.indexWhere((f) => f.key == float.key);
    if (index == -1) return;
    final stored = conversation.floatingImages[index];
    if (x != null) stored.x = FloatingImage.clampFraction(x);
    if (y != null) stored.y = FloatingImage.clampFraction(y);
    if (width != null) {
      stored.width = width
          .clamp(kFloatingImageMinWidth, kFloatingImageMaxWidth)
          .toDouble();
    }
    if (rotation != null) {
      stored.rotation = FloatingImage.normaliseRotation(rotation);
    }
    // The list's order *is* z-order, so the last one is on top.
    if (raise && index != conversation.floatingImages.length - 1) {
      conversation.floatingImages.add(conversation.floatingImages.removeAt(index));
    }
  }

  /// The floats of [conversation] paired with the picture each one draws, in
  /// z-order. A float whose gallery record has gone is skipped rather than drawn
  /// as a blank frame.
  List<FloatedPicture> floatingImagesFor(Conversation? conversation) {
    if (conversation == null) return const <FloatedPicture>[];
    final out = <FloatedPicture>[];
    for (final float in conversation.floatingImages) {
      if (float.imageId.isNotEmpty) {
        final image = galleryImageById(float.imageId);
        if (image == null) continue;
        out.add(FloatedPicture(
          float: float,
          ref: image.image,
          title: image.displayTitle,
        ));
      } else if (float.imageRef.isNotEmpty) {
        out.add(FloatedPicture(float: float, ref: float.imageRef, title: ''));
      }
    }
    return out;
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
      final character = characterFor(conversation, conversation.characterId);
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

  /// Files imported threads at the top of the list, newest first, persisting
  /// once.
  ///
  /// When [bind] is given, every imported thread is attached to that character —
  /// which is what makes an imported chat continuable, since the persona a reply
  /// needs lives on the character and not in the file. Any system prompt the file
  /// carried (Agnai's scenario, a log's leading system turn) is kept underneath
  /// the persona rather than thrown away.
  Future<void> importConversations(
    List<Conversation> imported, {
    Character? bind,
  }) async {
    if (imported.isEmpty) return;
    final taken = _conversations.map((c) => c.id).toSet();
    final fresh = <Conversation>[];
    for (final conversation in imported) {
      final target = taken.contains(conversation.id)
          ? _renumber(conversation)
          : conversation;
      taken.add(target.id);
      if (bind != null) {
        target
          ..characterId = bind.id
          ..characterName = bind.displayName
          ..systemPrompt = _mergedPrompt(bind, target.systemPrompt);
      }
      fresh.add(target);
    }
    _conversations.insertAll(0, fresh);
    notifyListeners();
    await _saveConversations();
  }

  /// The character's composed persona, with anything the imported file already
  /// carried appended so neither is lost.
  String _mergedPrompt(Character character, String existing) {
    final persona = character.composedSystemPrompt();
    final extra = existing.trim();
    if (extra.isEmpty) return persona;
    if (persona.trim().isEmpty) return extra;
    return '$persona\n\n$extra';
  }

  /// A copy under an unused id, for the rare case where an imported thread
  /// claims an id the list already holds.
  Conversation _renumber(Conversation source) => source.copyAs(
        id: '${DateTime.now().microsecondsSinceEpoch}-${_conversations.length}',
      );

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
    // In a group chat the user's turn is tagged with whoever they are speaking
    // as, so the transcript and the wire can label it (mirrors how each member's
    // replies carry their speaker).
    final speaking = conversation.isGroup ? impersonationFor(conversation) : null;
    conversation.messages.add(ChatMessage(
      role: 'user',
      content: prompt,
      speakerId: speaking?.id,
      speakerName: speaking?.displayName,
    ));

    // In a group chat nobody replies automatically: the user's turn just lands
    // and they tap a chip to pick who speaks. The exception is a chosen
    // auto-responder — a specific member, or a random one each turn — set from
    // the participant bar's options menu.
    if (conversation.isGroup) {
      final responder = groupAutoResponder(conversation);
      if (responder == null) {
        conversation.updatedAt = DateTime.now();
        _moveToTop(conversation);
        notifyListeners();
        await _saveConversations();
        return;
      }
      await _generate(conversation, responder: responder);
      return;
    }

    await _generate(conversation);
  }

  /// The member who should reply to a plain [send] in a group [conversation],
  /// honouring [Conversation.groupResponder]: null when nobody is set (manual —
  /// the user taps a chip), a random member when set to [kGroupResponderRandom],
  /// or the named member. Returns null (nobody) when the named member no longer
  /// resolves. Not used outside a group.
  Character? groupAutoResponder(Conversation conversation) {
    final mode = conversation.groupResponder;
    if (mode == null) return null;
    final members = participantsOf(conversation);
    if (members.isEmpty) return null;
    if (mode == kGroupResponderRandom) {
      return members[_random.nextInt(members.length)];
    }
    for (final member in members) {
      if (member.id == mode) return member;
    }
    return null;
  }

  /// Sets who auto-replies in [conversationId]'s group chat, toggling off when
  /// [value] is already the current choice — so tapping the selected entry in
  /// the options menu returns the thread to manual (nobody). [value] is a
  /// member's [Character.id], [kGroupResponderRandom], or null to clear.
  Future<void> toggleGroupResponder(
      String conversationId, String? value) async {
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    conversation.groupResponder =
        conversation.groupResponder == value ? null : value;
    notifyListeners();
    await _saveConversations();
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
  Future<void> _generate(Conversation conversation,
      {int? swipeInto, Character? responder}) async {
    final preset = presetFor(conversation);
    final base = _resolveProvider(preset);
    if (base == null) return;

    // In a group chat every reply is spoken by one member. When the caller did
    // not name one (a plain send), round-robin picks who is up next.
    final speaker = conversation.isGroup
        ? (responder ?? nextSpeaker(conversation))
        : responder;

    final assembled = _assemble(conversation, historyEnd: swipeInto, responder: speaker);
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
      conversation.messages.add(ChatMessage(
        role: 'assistant',
        content: '',
        speakerId: conversation.isGroup ? speaker?.id : null,
        speakerName: conversation.isGroup ? speaker?.displayName : null,
      ));
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
    JankLogger.instance.activity('streaming');
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
      JankLogger.instance.activity('idle');
      conversation.updatedAt = DateTime.now();
      notifyListeners();
      await _saveConversations();
      // Deliberately *not* saving the macro scopes here. The engine never
      // touches MacroVariables (grep macro_engine.dart), so this was a second
      // full rewrite of the entire preferences store after every single reply —
      // on Android each write rewrites the whole file, avatars included.
    }
    // Kick off a background summary if this chat is due one. Fire-and-forget so
    // the send completes immediately; it runs off the streaming path, saves and
    // notifies itself.
    unawaited(maybeSummarize(conversation));
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
    final fork = source.copyAs(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: '${source.title} (fork)',
      messages: copied,
      updatedAt: DateTime.now(),
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
    // A group turn is re-spoken by the same member, so the swipe keeps the same
    // voice and the round-robin anchor is unchanged.
    final responder = conversation.isGroup
        ? characterFor(conversation, conversation.messages[index].speakerId)
        : null;
    await _generate(conversation, swipeInto: index, responder: responder);
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
  /// The message ranges still to summarise given the method, interval and how far
  /// the chat was last summarised. Rolling yields a single `[0, count)` range;
  /// incremental yields one range per full interval window since the last run.
  /// When [force] (manual "summarise now") a trailing partial window is included.
  List<(int, int)> _pendingRanges(ChatSummary cfg, int count,
      {required bool force}) {
    if (cfg.interval <= 0 || count <= 0) return const <(int, int)>[];
    if (cfg.method == SummaryMethod.rolling) {
      if (!force && count - cfg.lastSummarizedIndex < cfg.interval) {
        return const <(int, int)>[];
      }
      return <(int, int)>[(0, count)];
    }
    final out = <(int, int)>[];
    var s = cfg.lastSummarizedIndex.clamp(0, count);
    while (count - s >= cfg.interval) {
      out.add((s, s + cfg.interval));
      s += cfg.interval;
    }
    if (force && s < count) out.add((s, count));
    return out;
  }

  /// A plain-text transcript of messages `[start, end)` for the summarizer.
  String _summaryTranscript(Conversation c, int start, int end) {
    final userName = impersonationFor(c)?.displayName ?? 'User';
    final charName = characterFor(c, c.characterId)?.displayName ??
        c.characterName ??
        'Character';
    final msgs = c.messages;
    final lo = start.clamp(0, msgs.length);
    final hi = end.clamp(0, msgs.length);
    final buf = StringBuffer();
    for (var i = lo; i < hi; i++) {
      final m = msgs[i];
      if (m.error || m.content.trim().isEmpty) continue;
      final name = m.speakerName ?? (m.isUser ? userName : charName);
      buf.writeln('$name: ${m.content.trim()}');
      buf.writeln();
    }
    return buf.toString().trim();
  }

  /// The provider+model+key a chat's summary should use: its own override, else
  /// the chat's current provider ("same as current").
  Provider? _summaryProvider(ChatSummary cfg, Conversation c) {
    Provider? base;
    if (cfg.providerId != null) {
      for (final p in _providers) {
        if (p.id == cfg.providerId) {
          base = p;
          break;
        }
      }
    }
    base ??= _resolveProvider(presetFor(c));
    if (base == null) return null;
    final model = cfg.model?.trim() ?? '';
    final resolved = model.isNotEmpty ? base.copyWith(model: model) : base;
    return _applyKey(resolved);
  }

  Future<void> _runSummary(Conversation c, ChatSummary cfg,
      {required bool force}) async {
    if (_summarizing.contains(c.id)) return;
    final provider = _summaryProvider(cfg, c);
    if (provider == null) return;
    final count = c.messages.length;
    final ranges = _pendingRanges(cfg, count, force: force);
    if (ranges.isEmpty) return;

    final requests = <SummaryRequest>[];
    for (final r in ranges) {
      final transcript = _summaryTranscript(c, r.$1, r.$2);
      if (transcript.isEmpty) continue;
      requests.add(SummaryRequest(
          startIndex: r.$1, endIndex: r.$2, transcript: transcript));
    }
    if (requests.isEmpty) return;

    _summarizing.add(c.id);
    notifyListeners();
    try {
      final budget = cfg.budget ?? presetFor(c)?.summaryBudget ?? 512;
      final results = await _summarizer.run(
        provider: provider,
        systemPrompt: cfg.effectivePrompt,
        maxTokens: budget,
        requests: requests,
      );
      final ok = results.where((r) => r.ok).toList()
        ..sort((a, b) => a.startIndex.compareTo(b.startIndex));
      if (ok.isEmpty) {
        if (cfg.notify) _raiseSummaryNotice('Summary failed — check the provider');
        return;
      }
      final stamp = DateTime.now().microsecondsSinceEpoch;
      if (cfg.method == SummaryMethod.rolling) {
        final content = ok.map((r) => r.text).join('\n\n');
        cfg.segments
          ..clear()
          ..add(SummarySegment(
            id: '$stamp',
            title: 'Summary through message ${ok.last.endIndex}',
            content: content,
            startIndex: 0,
            endIndex: ok.last.endIndex,
            tokens: estimateTokens(content),
          ));
      } else {
        for (var i = 0; i < ok.length; i++) {
          final r = ok[i];
          cfg.segments.add(SummarySegment(
            id: '$stamp-$i',
            title: 'Messages ${r.startIndex + 1}–${r.endIndex}',
            content: r.text,
            startIndex: r.startIndex,
            endIndex: r.endIndex,
            tokens: estimateTokens(r.text),
          ));
        }
      }
      cfg.lastSummarizedIndex = ok.last.endIndex;
      if (cfg.title.trim().isEmpty) cfg.title = c.title;
      c.updatedAt = DateTime.now();
      if (cfg.notify) {
        _raiseSummaryNotice('Memory updated · ${cfg.totalTokens} tokens');
      }
    } finally {
      _summarizing.remove(c.id);
      notifyListeners();
      await _saveConversations();
    }
  }

  void _raiseSummaryNotice(String message) {
    _summaryNotice = message;
    _summaryNoticeSeq++;
  }

  Provider? _resolveProvider(Preset? preset) {    Provider? base = activeProvider;
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
  AssembledPrompt _assemble(Conversation conversation,
      {int? historyEnd, Character? responder}) {
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
    // Whose card fills the definition markers. In a one-to-one thread that is the
    // bound character; in a group it is the member who is about to speak — the
    // "whoever is invoked, their definition is sent" policy (matching Agnai, and
    // SillyTavern's default SWAP mode). Everyone else is summarised in a compact
    // roster block below, so the responder knows who is in the room without
    // paying for every card on every turn.
    final character = conversation.isGroup
        ? (responder ?? nextSpeaker(conversation))
        : characterFor(conversation, conversation.characterId);
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

    // Group chats speak in one thread of many voices, so every turn is labelled
    // with its speaker ("Name: …") — the shape SillyTavern uses for groups — and
    // the responder is told who else is present and asked to reply only as
    // itself. A one-to-one thread is untouched (no labels, no roster).
    final history = conversation.isGroup
        ? [
            for (final m in priorTurns)
              m.copyWith(
                content: _groupTurnLabel(m, userName).isEmpty
                    ? m.content
                    : '${_groupTurnLabel(m, userName)}: ${m.content}',
              ),
          ]
        : priorTurns;
    if (conversation.isGroup && character != null) {
      addPrefix(
        'Group',
        _groupBriefing(
          responder: character,
          others: participantsOf(conversation)
              .where((c) => c.id != character.id)
              .toList(),
          userName: userName,
        ),
      );
    }

    List<ChatMessage> messages;
    var params = const GenParams();

    // The running summary, when enabled, feeds both the {{summary}} macro and the
    // auto-injection fallback (used when the preset places no {{summary}}).
    final chatSummary = conversation.summary;
    final summaryText = (chatSummary != null && chatSummary.enabled)
        ? chatSummary.combinedText
        : '';

    if (preset != null) {
      final built = _prompts.build(
        preset: preset,
        character: character,
        history: history,
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
        dynamicMacros: {'summary': () => summaryText},
        summaryText: summaryText,
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
      // plus the impersonated user persona (when set). In a group the stored
      // prompt belongs to the primary character, so the responder's own composed
      // persona is used instead — otherwise a non-primary speaker would be sent
      // the wrong definition.
      addPrefix(
        'Character (stored)',
        conversation.isGroup && character != null
            ? character.composedSystemPrompt(userName: userName)
            : conversation.systemPrompt,
      );
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
      messages = <ChatMessage>[...prefix, ...history];
      if (history.isNotEmpty) {
        sections.add(PromptSection(
          label: 'Chat history',
          role: 'mixed',
          tokens: history.fold<int>(0, (s, m) => s + _cost(m)),
          messageCount: history.length,
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
    // For a group, an assistant turn was produced by a specific member, so its
    // prompt is rebuilt from that member's seat rather than the round-robin
    // guess; a user turn shows what the next speaker would receive.
    final responder = conversation.isGroup && !isUser && safe < conversation.messages.length
        ? characterFor(conversation, conversation.messages[safe].speakerId)
        : null;
    return _assemble(conversation, historyEnd: end, responder: responder);
  }

  /// The speaker label a group turn is prefixed with on the wire ("Name: …").
  /// A user turn is labelled with whoever they are speaking as (the impersonated
  /// identity, or the plain user name); an assistant turn with its stored
  /// speaker. Empty means "leave this turn unlabelled" (a pre-group turn).
  static String _groupTurnLabel(ChatMessage m, String userName) {
    if (m.isUser) return (m.speakerName ?? userName).trim();
    return (m.speakerName ?? '').trim();
  }

  /// A compact system briefing for a group reply: who is speaking, who else is
  /// present (one line each), and the instruction to answer only as the
  /// responder. This is the "others summarised" half of the group prompt policy
  /// — the responder's full card is emitted by the preset markers as usual.
  static String _groupBriefing({
    required Character responder,
    required List<Character> others,
    required String userName,
  }) {
    final buffer = StringBuffer()
      ..writeln('This is a group roleplay with several characters. '
          'Write the next reply as ${responder.displayName} only.');
    if (others.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('# Other characters present');
      for (final c in others) {
        final brief = c.blurb;
        final line = brief.isEmpty
            ? c.displayName
            : '${c.displayName}: ${brief.length > 240 ? '${brief.substring(0, 240)}…' : brief}';
        buffer.writeln('- $line');
      }
    }
    buffer
      ..writeln()
      ..writeln('$userName is the user. Stay in character as '
          '${responder.displayName}; do not speak, act, or narrate for the '
          'other characters or for $userName.');
    return Character.resolveMacros(
      buffer.toString().trim(),
      charName: responder.displayName,
      userName: userName,
    );
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
