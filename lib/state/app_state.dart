import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../app_info.dart';
import '../models/appearance.dart';
import '../models/budget.dart';
import '../models/character.dart';
import '../models/chat_interface.dart';
import '../models/conversation.dart';
import '../models/discover.dart';
import '../models/embedding.dart';
import '../models/floating_image.dart';
import '../models/gallery_image.dart';
import '../models/image_gen.dart';
import '../models/lorebook.dart';
import '../models/message.dart';
import '../models/message_image.dart';
import '../models/preset.dart';
import '../models/prompt_block.dart';
import '../models/provider.dart';
import '../models/scenario.dart';
import '../models/summary.dart';
import '../models/usage.dart';
import '../models/view_prefs.dart';
import '../services/chat_client.dart';
import '../services/chat_graph.dart';
import '../services/avatar_store.dart';
import '../services/document_sources.dart';
import '../services/embedding_index.dart';
import '../services/embedding_store.dart';
import '../services/gallery_group.dart';
import '../services/image_client.dart';
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
import '../services/usage_ledger.dart';
import '../services/world_info.dart';

/// Single source of truth for providers, threads and the in-flight reply.
class AppState extends ChangeNotifier {
  AppState({
    Storage? storage,
    ChatClient? client,
    ImageClient? imageClient,
    UpdateService? updateService,
    AvatarStore? avatars,
    EmbeddingStore? embeddings,
    this.loadTimeout = const Duration(seconds: 30),
  })  : _storage = storage ?? Storage(),
        _client = client ?? ChatClient(),
        _imageClient = imageClient ?? ImageClient(),
        _updateService = updateService ?? UpdateService() {
    _avatars = avatars;
    _vectors = embeddings;
  }

  final Storage _storage;
  final ChatClient _client;
  final ImageClient _imageClient;
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
  final List<Scenario> _scenarios = <Scenario>[];
  final List<GalleryImage> _gallery = <GalleryImage>[];
  final List<Preset> _presets = <Preset>[];
  final Map<String, String> _globalVars = <String, String>{};
  final Map<String, List<String>> _modelCache = <String, List<String>>{};

  /// What has been spent, by provider and model. Replaced wholesale on load.
  UsageLedger _usage = UsageLedger();
  // Per-provider cursor into its key pool, used by round-robin (advances every
  // request) and error-based (advances only when a request fails).
  final Map<String, int> _keyCursor = <String, int>{};
  final Random _random = Random();
  String? _defaultPresetId;
  String? _defaultPersonaId;
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

  /// Where embedding vectors are kept (files, like [AvatarStore]); null when the
  /// platform would not name a directory, in which case embeddings stay off.
  EmbeddingStore? _vectors;

  /// App-wide embedding settings and the Data Bank documents.
  EmbeddingConfig _embeddingConfig = const EmbeddingConfig();
  final List<EmbeddingDocument> _documents = <EmbeddingDocument>[];

  /// The semantic-memory engine, built once the vector store is known. Null when
  /// there is no store (feature unavailable).
  EmbeddingIndex? _index;

  /// Per-conversation retrieval results, refreshed just before each send and
  /// read synchronously by [_assemble]: the recalled chat text, the recalled
  /// document text, and the lorebook entry keys the semantic pass activated.
  final Map<String, String> _memoryInjection = <String, String>{};
  final Map<String, String> _docInjection = <String, String>{};
  final Map<String, Set<String>> _forcedLore = <String, Set<String>>{};

  /// Collection ids currently being indexed, so a second background pass for the
  /// same collection is not started while one is in flight.
  final Set<String> _indexing = <String>{};

  /// A pending in-app notice from embedding work (an indexing/retrieval error),
  /// and a sequence so a listener shows it once. Mirrors the summary notice.
  String? _embeddingNotice;
  int _embeddingNoticeSeq = 0;

  /// Chat ids whose summary is being (re)generated right now — guards against
  /// firing a second run for the same chat while one is in flight.
  final Set<String> _summarizing = <String>{};

  /// A pending in-app notice from a completed summary, and a monotonically
  /// increasing sequence so a listener can show it exactly once.
  String? _summaryNotice;
  int _summaryNoticeSeq = 0;

  /// The error from the most recent summary run, or null on success — read by the
  /// summary editor right after it triggers a run (the transient notice can be
  /// consumed by the chat screen first).
  String? _lastSummaryError;

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
  List<Scenario> get scenarios => List.unmodifiable(_scenarios);
  List<GalleryImage> get gallery => List.unmodifiable(_gallery);
  List<Preset> get presets => List.unmodifiable(_presets);
  Appearance get appearance => _appearance;
  ChatInterface get chatInterface => _chatInterface;
  bool get ready => _ready;
  bool get streaming => _streaming;

  /// Whether the request in flight is writing the *user's* next line rather than
  /// a reply — [writeForUser]. The composer shows its own progress for it, and
  /// the chat does not: nothing is being added to the transcript.
  bool _writingForUser = false;
  bool get writingForUser => _writingForUser;

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
      // Building a BPE vocabulary is ~100k entries of work and the encoder cache
      // is static, so the first caller pays for the whole process. Left on the
      // build path it landed on whichever screen happened to ask first, as a
      // visible hitch. Pay it here instead, in a microtask — off init's await
      // chain, and no timer for a widget test to trip over.
      scheduleMicrotask(() {
        try {
          _tokenizer.estimate('warm');
        } catch (_) {
          // The tokenizer already falls back to a heuristic on its own; a failed
          // warm-up must not take the launch with it.
        }
      });
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
    _scenarios
      ..clear()
      ..addAll(await _storage.loadScenarios());
    _viewPrefs = await _storage.loadViewPrefs();
    _imageGen = await _storage.loadImageGen();
    _summaryFolds
      ..clear()
      ..addAll(await _storage.loadSummaryFolds());
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
    _usage = UsageLedger.decode(await _storage.loadUsage());
    // Folding stale hours down is cheap and only worth persisting when it
    // actually changed something.
    if (_usage.prune()) await _persistUsage();
    _discoverPrefs = await _storage.loadDiscoverPrefs();
    _embeddingConfig = await _storage.loadEmbeddingConfig();
    _documents
      ..clear()
      ..addAll(await _storage.loadDocuments());
    // The semantic-memory engine, once the vector store is known. Embedding
    // requests use a fresh client each time (see [_embed]).
    final vectors = _vectors;
    if (vectors != null) {
      _index = EmbeddingIndex(store: vectors, embed: _embed);
    }
    final stored = await _storage.loadConversations()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _conversations
      ..clear()
      ..addAll(stored);
    // Folds are a view preference held apart from the conversations blob, so
    // they are laid back over the summaries once those are in memory.
    _applySummaryFolds();
    _activeId = await _storage.loadActiveId();
    // The persona new chats default to. A card the user deleted between runs
    // leaves a dangling id, which would resolve to nobody — drop it so the
    // profile shows "just me" rather than a ghost.
    _defaultPersonaId = await _storage.loadDefaultPersonaId();
    if (characterById(_defaultPersonaId) == null) _defaultPersonaId = null;
    await _adoptStoredAvatars();
    // Clear vector files for anything that no longer exists (best-effort).
    unawaited(_sweepVectors());
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

  /// The stored provider with [id], or null. The provider editor reads through
  /// this rather than holding the object it was opened with, so its Costs tab
  /// sees saved state instead of the draft being typed.
  Provider? providerById(String? id) {
    if (id == null) return null;
    for (final provider in _providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  /// Tries one credential against [provider]'s host. Goes through the client so
  /// tests use the same headers, URL handling and error wording a real request
  /// would — a test that passes where a send fails is worse than no test.
  Future<KeyTestResult> testProviderKey(Provider provider, String key) =>
      _client.testKey(provider, key);

  // --- Providers: pricing, usage, budgets ---
  //
  // Kept in one block so this feature's footprint in a 3700-line file is
  // reviewable, and so a merge lands here rather than scattered.

  /// Read-only view of the ledger, for the Costs tab.
  UsageLedger get usage => _usage;

  Future<void> _persistUsage() async {
    if (!_writable) return;
    await _storage.saveUsage(_usage.encode());
  }

  /// Records what one reply cost, pricing it against the provider's own table.
  ///
  /// Does not persist: the caller writes once, alongside the conversation save it
  /// is already doing, so a reply costs one extra `setString` rather than a
  /// debounce timer that could lose the last few seconds of spend on a crash.
  void recordUsage(Provider provider, String model, TokenUsage tokens) {
    if (tokens.isEmpty) return;
    _usage.record(
      providerId: provider.id,
      model: model,
      usage: tokens,
      price: provider.priceOf(model),
    );
  }

  /// What [budget] has been used up so far, in whatever unit it counts.
  double budgetSpend(Provider provider, Budget budget) {
    final bucket = _usage.totals(
      provider.id,
      model: budget.isProviderWide ? null : budget.model,
      since: _periodStart(budget.period),
    );
    return switch (budget.metric) {
      BudgetMetric.cost => bucket.totalCost,
      BudgetMetric.tokens => bucket.totalTokens.toDouble(),
      BudgetMetric.requests => bucket.requests.toDouble(),
    };
  }

  /// When the current window began, or null for an all-time budget.
  static DateTime? _periodStart(BudgetPeriod period) {
    final now = DateTime.now();
    return switch (period) {
      BudgetPeriod.daily => DateTime(now.year, now.month, now.day),
      BudgetPeriod.weekly => DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: now.weekday - 1)),
      BudgetPeriod.monthly => DateTime(now.year, now.month),
      BudgetPeriod.total => null,
    };
  }

  /// The blocking budget that stands in the way of sending to [model] on
  /// [provider], or null when nothing does.
  ///
  /// Only budgets with [Budget.block] set can refuse a send; the rest are
  /// warnings the Costs tab colours. A budget with no limit is ignored, since a
  /// limit of nothing would block everything.
  Budget? blockingBudget(Provider provider, String model) {
    for (final budget in provider.budgets) {
      if (!budget.block || !budget.isSet) continue;
      if (!budget.isProviderWide && budget.model.trim() != model.trim()) {
        continue;
      }
      if (budget.isExceededBy(budgetSpend(provider, budget))) return budget;
    }
    return null;
  }

  /// Forgets a provider's recorded usage, and persists straight away rather than
  /// on the coalescing timer — a deletion the user asked for should not be
  /// waiting in a buffer.
  Future<void> forgetProviderUsage(String providerId) async {
    if (!_usage.forget(providerId)) return;
    notifyListeners();
    await _persistUsage();
  }

  /// Adds or replaces a budget on [provider].
  Future<void> saveBudget(Provider provider, Budget budget) async {
    final budgets = List<Budget>.of(provider.budgets);
    final index = budgets.indexWhere((b) => b.id == budget.id);
    if (index == -1) {
      budgets.add(budget);
    } else {
      budgets[index] = budget;
    }
    await updateProvider(provider.copyWith(budgets: budgets));
  }

  Future<void> deleteBudget(Provider provider, String budgetId) async {
    final budgets =
        provider.budgets.where((b) => b.id != budgetId).toList(growable: false);
    if (budgets.length == provider.budgets.length) return;
    await updateProvider(provider.copyWith(budgets: budgets));
  }

  /// How a refused send is explained. Written as a sentence because it lands in
  /// the chat as an error turn, where a user is owed a reason and a way out.
  static String describeBudgetBlock(Budget budget) {
    final scope = budget.isProviderWide ? 'this provider' : budget.model;
    final limit = switch (budget.metric) {
      BudgetMetric.cost => '\$${budget.limit.toStringAsFixed(2)}',
      BudgetMetric.tokens => '${budget.limit.toStringAsFixed(0)} tokens',
      BudgetMetric.requests => '${budget.limit.toStringAsFixed(0)} requests',
    };
    return 'Budget reached: $scope has hit its '
        '${budget.period.label.toLowerCase()} limit of $limit. '
        'Raise or remove the budget in the provider’s Costs tab to continue.';
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

  /// The persona (a roster [Character]) new chats adopt as the user's identity,
  /// or null when the user speaks as themselves by default. Mirrors the
  /// default-preset mechanism: stored as one scalar id, resolved lazily so a
  /// deleted card simply reads as "just me".
  Character? get defaultPersona => characterById(_defaultPersonaId);
  String? get defaultPersonaId => _defaultPersonaId;

  /// Sets (or clears, with a null [id]) the persona new chats start with. Applied
  /// in [newConversation] and [startChatWithCharacter]; existing threads keep
  /// whatever persona they already have.
  Future<void> setDefaultPersona(String? id) async {
    if (_defaultPersonaId == id) return;
    _defaultPersonaId = id;
    notifyListeners();
    if (!_writable) return;
    await _storage.saveDefaultPersonaId(id);
  }

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

  Timer? _convSaveTimer;

  /// Persists conversations shortly after the current interaction instead of
  /// on this frame. Used by animation-sensitive toggles (e.g. enabling summary)
  /// so the whole-store rewrite never competes with the toggle's animation.
  void _saveConversationsSoon() {
    _convSaveTimer?.cancel();
    _convSaveTimer = Timer(const Duration(milliseconds: 400), () {
      _convSaveTimer = null;
      _saveConversations();
    });
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
    // A deleted card can no longer be the default persona; drop the pointer so
    // new chats fall back to "just me" instead of resolving to nobody.
    var personaCleared = false;
    if (_defaultPersonaId == id) {
      _defaultPersonaId = null;
      personaCleared = true;
    }
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
    if (personaCleared) await _storage.saveDefaultPersonaId(null);
    if (detached) await _persistGallery();
    if (touchedChats) await _saveConversations();
    await _sweepAvatars();
  }

  /// Deletes picture files nothing refers to any more. The keep-list has to name
  /// every place a picture can be referenced from — a chat's background, a
  /// per-chat character override, a gallery entry, a character's extra avatars, a
  /// per-chat avatar choice and a picture attached to a message all live outside
  /// the roster's `avatar` field, and a sweep that forgot one would delete a
  /// picture still on screen.
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
        // A picture sent in a message is part of the transcript: it has to
        // outlive the gallery record it may have been picked from.
        ...c.messages.expand((m) => m.images.map((i) => i.ref)),
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
    final vectorBytes = await _vectors?.sizeBytes() ?? 0;
    return StorageReport.build(
      prefsUsage: prefsUsage,
      imageFiles: images,
      vectorBytes: vectorBytes,
      itemCounts: {
        StorageCategory.chats: _conversations.length,
        StorageCategory.characters: _characters.length,
        StorageCategory.lorebooks: _lorebooks.length,
        StorageCategory.presets: _presets.length,
        StorageCategory.gallery: _gallery.length,
        StorageCategory.embeddings: _documents.length,
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

  /// Replaces (or with an empty [scenario], clears) a character's **custom
  /// scenario** — the "write your own" half of the character sheet's scenario
  /// row. The card's own scenario is left untouched underneath, so clearing this
  /// restores it; [Character.activeScenario] is the single place that decides
  /// which of the two is in force.
  Future<void> setCustomScenario(String id, String scenario) async {
    final character = characterById(id);
    if (character == null) return;
    final next = scenario.trim();
    if (character.customScenario == next) return;
    character.customScenario = next;
    character.updatedAt = DateTime.now();
    notifyListeners();
    await _persistCharacters();
  }

  /// The freshest thread with [characterId] that actually holds messages, or null
  /// when the character has never been chatted with.
  ///
  /// Threads are held newest-first, so this is the first match — but the list is
  /// scanned rather than indexed, because an empty "New chat" can sit at the top
  /// and opening that instead of the real conversation is exactly the surprise
  /// the character sheet's "recent chat" bubble must not spring.
  Conversation? mostRecentChatWith(String characterId) {
    Conversation? best;
    for (final c in _conversations) {
      if (c.isEmpty) continue;
      if (!c.memberIds.contains(characterId)) continue;
      if (best == null || c.updatedAt.isAfter(best.updatedAt)) best = c;
    }
    return best;
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
    unawaited(_indexLoreBook(book));
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
    await _vectors?.delete(EmbeddingIndex.loreCollection(id));
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

  // --- Scenarios -----------------------------------------------------------
  //
  // A scenario reaches a request by one of three routes, and they are ranked in
  // exactly one place ([scenarioFor]): the character's own card, a library
  // scenario plugged into the chat, or one written for that chat alone.

  Future<void> _persistScenarios() async {
    if (!_writable) return;
    await _storage.saveScenarios(_scenarios);
  }

  Scenario? scenarioById(String? id) {
    if (id == null) return null;
    for (final s in _scenarios) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// The library scenario plugged into [conversation], or null when none is (or
  /// when the one it named has since been deleted).
  Scenario? scenarioOf(Conversation? conversation) =>
      scenarioById(conversation?.scenarioId);

  /// The scenario text in force for [conversation] with [character] answering.
  ///
  /// **The** resolution point, in ranked order: a scenario written for this chat
  /// wins, then the library scenario plugged into it (applied over the card's, so
  /// an "add to it" scenario keeps both), then the character's own. Everything
  /// that needs to know — the request, the inspectors, the chat settings screen —
  /// reads it through here, so a chosen scenario cannot be honoured in one place
  /// and forgotten in another.
  String scenarioFor(Conversation? conversation, Character? character) {
    final card = character?.activeScenario.trim() ?? '';
    final own = conversation?.scenarioOverride.trim() ?? '';
    if (own.isNotEmpty) return own;
    final plugged = scenarioOf(conversation);
    if (plugged != null && plugged.isUsable) return plugged.appliedOver(card);
    return card;
  }

  /// Where [conversation]'s scenario comes from, phrased for a settings row.
  String scenarioSourceFor(Conversation? conversation) {
    if (conversation == null) return "The character's own";
    if (conversation.scenarioOverride.trim().isNotEmpty) {
      return 'Written for this chat';
    }
    final plugged = scenarioOf(conversation);
    if (plugged != null) return plugged.displayName;
    return "The character's own";
  }

  Future<void> addScenario(Scenario scenario) async {
    _scenarios.insert(0, scenario);
    notifyListeners();
    await _persistScenarios();
  }

  /// Adds several at once (an import), newest first, persisting once.
  Future<void> addScenarios(List<Scenario> scenarios) async {
    if (scenarios.isEmpty) return;
    _scenarios.insertAll(0, scenarios.reversed);
    notifyListeners();
    await _persistScenarios();
  }

  /// Replaces the stored scenario sharing [scenario]'s id, or adds it when new.
  Future<void> saveScenario(Scenario scenario) async {
    scenario.updatedAt = DateTime.now();
    final index = _scenarios.indexWhere((s) => s.id == scenario.id);
    if (index == -1) {
      _scenarios.insert(0, scenario);
    } else {
      _scenarios[index] = scenario;
    }
    notifyListeners();
    await _persistScenarios();
  }

  /// Deletes a scenario and unplugs it from every chat that was running it, so no
  /// thread is left pointing at something that is gone. A chat that had *edited*
  /// the scenario keeps its own copy — that text is the user's, not the library's.
  Future<void> deleteScenario(String id) async {
    _scenarios.removeWhere((s) => s.id == id);
    for (final conversation in _conversations) {
      if (conversation.scenarioId == id) conversation.scenarioId = null;
    }
    notifyListeners();
    await _persistScenarios();
    await _saveConversations();
  }

  Future<void> toggleScenarioStar(String id) async {
    final index = _scenarios.indexWhere((s) => s.id == id);
    if (index == -1) return;
    final scenario = _scenarios[index];
    scenario.starred = !scenario.starred;
    notifyListeners();
    await _persistScenarios();
  }

  Future<Scenario> duplicateScenario(Scenario scenario) async {
    final copy = scenario.copyWith(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: '${scenario.displayName} (copy)',
      updatedAt: DateTime.now(),
    );
    await addScenario(copy);
    return copy;
  }

  /// Applies a scenario to one chat. [scenarioId] names the library scenario it
  /// came from (null for one written on the spot); [text] is a wording for this
  /// chat alone, which wins over the library copy. Passing neither clears the
  /// chat back to the character's own scenario.
  Future<void> setChatScenario(
    String conversationId, {
    String? scenarioId,
    String text = '',
  }) async {
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    conversation.scenarioId = scenarioId;
    conversation.scenarioOverride = text.trim();
    conversation.updatedAt = DateTime.now();
    notifyListeners();
    await _saveConversations();
  }

  /// Puts a chat back on the character's own scenario.
  Future<void> clearChatScenario(String conversationId) =>
      setChatScenario(conversationId);

  // --- Browse layout -------------------------------------------------------

  ViewPrefs _viewPrefs = const ViewPrefs();

  /// Which shape each browsable section (characters, lorebooks, scenarios) was
  /// last left in. Persisted, because it is a preference about how the user likes
  /// to read their own library and not a per-visit gesture.
  ViewPrefs get viewPrefs => _viewPrefs;

  BrowseLayout browseLayout(String section,
          {BrowseLayout fallback = BrowseLayout.grid}) =>
      _viewPrefs.layoutFor(section, fallback: fallback);

  Future<void> setBrowseLayout(String section, BrowseLayout layout) async {
    // Nothing observable changes when the section already reads this way — and
    // writing the default out explicitly would rewrite the store for a tap that
    // did nothing.
    if (browseLayout(section) == layout) return;
    final next = _viewPrefs.withLayout(section, layout);
    if (next == _viewPrefs) return;
    _viewPrefs = next;
    notifyListeners();
    if (!_writable) return;
    await _storage.saveViewPrefs(_viewPrefs);
  }

  // --- Embeddings (semantic memory + Data Bank) ----------------------------

  EmbeddingConfig get embeddingConfig => _embeddingConfig;
  List<EmbeddingDocument> get documents => List.unmodifiable(_documents);

  /// Whether embeddings can actually run: enabled, a provider chosen, and a
  /// vector store available on this platform.
  bool get embeddingReady => _embeddingConfig.isReady && _index != null;

  EmbeddingDocument? documentById(String? id) {
    if (id == null) return null;
    for (final d in _documents) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// A pending in-app notice from embedding work, shown once by a listener.
  String? get embeddingNotice => _embeddingNotice;
  int get embeddingNoticeSeq => _embeddingNoticeSeq;
  void consumeEmbeddingNotice() => _embeddingNotice = null;

  void _noteEmbedding(String message) {
    _embeddingNotice = message;
    _embeddingNoticeSeq++;
    notifyListeners();
  }

  Future<void> updateEmbeddingConfig(EmbeddingConfig config) async {
    final was = _embeddingConfig;
    _embeddingConfig = config;
    notifyListeners();
    if (_writable) await _storage.saveEmbeddingConfig(config);
    // A model change makes every stored vector stale; the collections re-embed
    // lazily the next time each is indexed (they key on the stored model).
    // When the feature has just become usable, index the vectorized books now
    // so lore recall works without waiting for each to be re-saved.
    if (config.isReady && (!was.isReady || was.model != config.model)) {
      unawaited(_indexVectorizedLore());
    }
  }

  /// The provider serving `/embeddings`, or null when none is chosen/valid.
  Provider? _embeddingProvider() {
    final id = _embeddingConfig.providerId;
    if (id == null) return null;
    for (final p in _providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// The [Embedder] handed to [EmbeddingIndex]: a fresh client per call, its key
  /// narrowed by the same rotation the chat send uses.
  Future<List<Float32List>> _embed(List<String> texts, String model) {
    final base = _embeddingProvider();
    if (base == null) {
      throw ChatApiException('Choose an embedding provider in settings.');
    }
    return ChatClient().embed(_applyKey(base), texts, model: model);
  }

  /// The retrieval query: the most recent user/assistant turns, newest first,
  /// joined — mirrors SillyTavern's `getQueryText`.
  String _queryText(Conversation conversation) {
    final parts = <String>[];
    for (final m in conversation.messages.reversed) {
      if (m.error || (m.role != 'user' && m.role != 'assistant')) continue;
      final text = m.content.trim();
      if (text.isEmpty) continue;
      parts.add(text);
      if (parts.length >= _embeddingConfig.queryMessages) break;
    }
    return parts.join('\n');
  }

  /// Refreshes [conversation]'s retrieval caches so the synchronous [_assemble]
  /// can read them. Best-effort: any failure leaves the caches empty (no recall)
  /// and never blocks the send. Awaited before each generation.
  Future<void> _refreshMemory(Conversation conversation) async {
    _memoryInjection.remove(conversation.id);
    _docInjection.remove(conversation.id);
    _forcedLore.remove(conversation.id);

    final index = _index;
    final cfg = _embeddingConfig;
    if (index == null || !cfg.isReady) return;

    final wantChat = conversation.embedRecall;
    final books = lorebooksFor(conversation).where((b) => b.vectorized).toList();
    final wantLore = cfg.loreActivation && books.isNotEmpty;
    final docs = conversation.documentIds
        .map(documentById)
        .whereType<EmbeddingDocument>()
        .where((d) => d.isIndexed)
        .toList();
    if (!wantChat && !wantLore && docs.isEmpty) return;

    try {
      final query = _queryText(conversation);
      final qv = await index
          .embedQuery(query, model: cfg.model)
          .timeout(const Duration(seconds: 30));
      if (qv == null) return;

      if (wantChat) {
        // The last `protect` messages are already in context, so their chunks
        // are excluded from what gets recalled.
        final tail = conversation.messages.length > cfg.protect
            ? conversation.messages.sublist(
                conversation.messages.length - cfg.protect)
            : conversation.messages;
        final exclude = EmbeddingIndex.chatChunks(tail, cfg.messageChunkSize)
            .map(EmbeddingIndex.hashText)
            .toSet();
        final hits = await index.retrieve(
          EmbeddingIndex.chatCollection(conversation.id),
          qv,
          topK: cfg.insert,
          threshold: cfg.threshold,
          model: cfg.model,
          excludeKeys: exclude,
        );
        if (hits.isNotEmpty) {
          _memoryInjection[conversation.id] = cfg.template.replaceAll(
              '{{text}}', hits.map((h) => h.text).join('\n\n'));
        }
      }

      if (docs.isNotEmpty) {
        final all = <ScoredChunk>[];
        for (final d in docs) {
          all.addAll(await index.retrieve(
            EmbeddingIndex.docCollection(d.id),
            qv,
            topK: cfg.insert,
            threshold: cfg.threshold,
            model: cfg.model,
          ));
        }
        all.sort((a, b) => b.score.compareTo(a.score));
        final top = all.length > cfg.insert ? all.sublist(0, cfg.insert) : all;
        if (top.isNotEmpty) {
          _docInjection[conversation.id] = cfg.docTemplate.replaceAll(
              '{{text}}', top.map((h) => h.text).join('\n\n'));
        }
      }

      if (wantLore) {
        final forced = <String>{};
        for (final book in books) {
          final hits = await index.retrieve(
            EmbeddingIndex.loreCollection(book.id),
            qv,
            topK: cfg.insert,
            threshold: cfg.threshold,
            model: cfg.model,
          );
          for (final h in hits) {
            // Keys are `<uid>:<hash>`; recover the uid to force-activate it.
            final uid = h.key.split(':').first;
            forced.add('${book.id}#$uid');
          }
        }
        if (forced.isNotEmpty) _forcedLore[conversation.id] = forced;
      }
    } on ChatApiException catch (e) {
      _noteEmbedding('Semantic recall unavailable: ${e.message}');
    } catch (_) {
      // Any other failure just means no recall this turn.
    }
  }

  /// Re-embeds a chat's messages in the background (only when recall is on and
  /// the feature is ready). Guarded so one pass runs per collection at a time.
  Future<void> _indexChat(Conversation conversation) async {
    final index = _index;
    if (index == null ||
        !_embeddingConfig.isReady ||
        !conversation.embedRecall) {
      return;
    }
    final id = EmbeddingIndex.chatCollection(conversation.id);
    if (!_indexing.add(id)) return;
    try {
      await index.indexChat(
        conversation.id,
        List<ChatMessage>.of(conversation.messages),
        model: _embeddingConfig.model,
        chunkSize: _embeddingConfig.messageChunkSize,
      );
    } on ChatApiException catch (e) {
      _noteEmbedding('Could not index this chat: ${e.message}');
    } catch (_) {
      // Leave it for the next send.
    } finally {
      _indexing.remove(id);
    }
  }

  /// Re-embeds a vectorized lorebook's entries in the background.
  Future<void> _indexLoreBook(Lorebook book) async {
    final index = _index;
    if (index == null || !_embeddingConfig.isReady) return;
    final id = EmbeddingIndex.loreCollection(book.id);
    if (!book.vectorized) {
      await _vectors?.delete(id);
      return;
    }
    if (!_indexing.add(id)) return;
    try {
      await index.indexLore(book.id, book.entries,
          model: _embeddingConfig.model);
    } on ChatApiException catch (e) {
      _noteEmbedding('Could not index "${book.displayName}": ${e.message}');
    } catch (_) {
      // Retried next time the book is saved.
    } finally {
      _indexing.remove(id);
    }
  }

  /// Indexes every vectorized book — fired after a lorebook is saved.
  Future<void> _indexVectorizedLore() async {
    if (!_embeddingConfig.isReady) return;
    for (final book in _lorebooks) {
      if (book.vectorized) await _indexLoreBook(book);
    }
  }

  /// Turns [conversation]'s semantic recall on or off, indexing immediately when
  /// switched on so recall works from the next turn.
  Future<void> setEmbedRecall(String conversationId, bool on) async {
    final conversation = _conversationById(conversationId);
    if (conversation == null || conversation.embedRecall == on) return;
    conversation.embedRecall = on;
    notifyListeners();
    await _saveConversations();
    if (on) unawaited(_indexChat(conversation));
  }

  /// Attaches/detaches a document to a chat (toggles).
  Future<void> toggleConversationDocument(
      String conversationId, String docId) async {
    final conversation = _conversationById(conversationId);
    if (conversation == null) return;
    if (!conversation.documentIds.remove(docId)) {
      conversation.documentIds.add(docId);
    }
    notifyListeners();
    await _saveConversations();
  }

  Future<void> _persistDocuments() async {
    if (!_writable) return;
    await _storage.saveDocuments(_documents);
  }

  /// Ingests a [DocumentText] (already extracted from a file/URL/paste): records
  /// it, chunks and embeds it into its own collection, and persists. Returns the
  /// document, or null when embeddings are not ready. Throws on an embed failure.
  Future<EmbeddingDocument?> importDocument(
    DocumentText doc, {
    List<String> tags = const <String>[],
  }) async {
    final index = _index;
    if (index == null || !_embeddingConfig.isReady) {
      _noteEmbedding('Turn embeddings on and pick a provider first.');
      return null;
    }
    final record = EmbeddingDocument(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: doc.name,
      source: doc.source,
      origin: doc.origin,
      tags: tags,
      tokens: estimateTokens(doc.text),
      model: _embeddingConfig.model,
    );
    final count = await index.indexDocument(
      record.id,
      doc.text,
      model: _embeddingConfig.model,
      chunkSize: _embeddingConfig.docChunkSize,
      overlapPercent: _embeddingConfig.docOverlapPercent,
    );
    record.chunkCount = count;
    _documents.insert(0, record);
    notifyListeners();
    await _persistDocuments();
    return record;
  }

  /// The reconstructed source text of document [id] — its original text when it
  /// was stored (exact), falling back to its stored chunks joined back together.
  Future<String> documentText(String id) async {
    final store = _vectors;
    if (store == null) return '';
    final col = await store.read(EmbeddingIndex.docCollection(id));
    if (col.sourceText.isNotEmpty) return col.sourceText;
    // Older documents (or a rebuild) may have no stored source — join the chunks
    // in `docId#n` order as a best effort.
    final ordered = col.records.toList()
      ..sort((a, b) {
        int n(String k) => int.tryParse(k.split('#').last) ?? 0;
        return n(a.key).compareTo(n(b.key));
      });
    return ordered.map((r) => r.text).join('\n');
  }

  /// Updates a document's name and tags (no re-embedding).
  Future<void> updateDocumentMeta(String id,
      {String? name, List<String>? tags}) async {
    final i = _documents.indexWhere((d) => d.id == id);
    if (i == -1) return;
    _documents[i] = _documents[i].copyWith(name: name, tags: tags);
    notifyListeners();
    await _persistDocuments();
  }

  /// Replaces document [id]'s text (a text-document edit or a re-fetch),
  /// re-embedding it. Metadata is updated alongside. Throws on an embed failure.
  Future<void> reindexDocument(
    String id, {
    required String text,
    String? name,
    List<String>? tags,
  }) async {
    final index = _index;
    final i = _documents.indexWhere((d) => d.id == id);
    if (index == null || i == -1 || !_embeddingConfig.isReady) {
      _noteEmbedding('Turn embeddings on and pick a provider first.');
      return;
    }
    final count = await index.indexDocument(
      id,
      text,
      model: _embeddingConfig.model,
      chunkSize: _embeddingConfig.docChunkSize,
      overlapPercent: _embeddingConfig.docOverlapPercent,
    );
    _documents[i] = _documents[i].copyWith(
      name: name,
      tags: tags,
      chunkCount: count,
      tokens: estimateTokens(text),
      model: _embeddingConfig.model,
    );
    notifyListeners();
    await _persistDocuments();
  }

  Future<void> renameDocument(String id, String name) async {
    final index = _documents.indexWhere((d) => d.id == id);
    if (index == -1) return;
    _documents[index].name = name.trim();
    notifyListeners();
    await _persistDocuments();
  }

  /// Deletes a document, its vector file, and detaches it from every chat.
  Future<void> deleteDocument(String id) async {
    _documents.removeWhere((d) => d.id == id);
    await _vectors?.delete(EmbeddingIndex.docCollection(id));
    var touched = false;
    for (final c in _conversations) {
      if (c.documentIds.remove(id)) touched = true;
    }
    notifyListeners();
    await _persistDocuments();
    if (touched) await _saveConversations();
  }

  /// Removes vector collections for chats, books and documents that no longer
  /// exist — run once at startup to clear orphaned files.
  Future<void> _sweepVectors() async {
    final store = _vectors;
    if (store == null) return;
    final keep = <String>{
      for (final c in _conversations) EmbeddingIndex.chatCollection(c.id),
      for (final b in _lorebooks) EmbeddingIndex.loreCollection(b.id),
      for (final d in _documents) EmbeddingIndex.docCollection(d.id),
    };
    try {
      await store.sweep(keep);
    } catch (_) {
      // Best-effort cleanup.
    }
  }

  // --- Summary -------------------------------------------------------------

  /// A pending in-app notice from the last completed summary (null once shown),
  /// with a sequence number so a listener can react to it exactly once.
  String? get summaryNotice => _summaryNotice;
  int get summaryNoticeSeq => _summaryNoticeSeq;
  void consumeSummaryNotice() => _summaryNotice = null;

  /// The error from the last summary run (null on success). For the editor to
  /// report a failure it triggered directly.
  String? get lastSummaryError => _lastSummaryError;

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
    if (cfg.title.trim().isEmpty) cfg.title = '${c.title} summary';
    c.summary = cfg;
    c.updatedAt = DateTime.now();
    notifyListeners();
    // Defer the heavy whole-store write so the sidebar toggle animates smoothly.
    _saveConversationsSoon();
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
  /// The user's own hand-written blocks are kept.
  Future<void> resummarize(String conversationId) async {
    final c = _conversationById(conversationId);
    final cfg = c?.summary;
    if (c == null || cfg == null) return;
    cfg.segments.removeWhere((s) => !s.manual);
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

  /// The highest message index a chat's memory actually covers right now,
  /// recomputed from the segments that still exist (so a deleted block is no
  /// longer counted). The memory editor uses this to describe, and gate, a
  /// manual "Summarise now".
  int summaryCoverage(String conversationId) {
    final c = _conversationById(conversationId);
    final cfg = c?.summary;
    if (c == null || cfg == null) return 0;
    return cfg.coveredIndex(c.messages.length);
  }

  /// Persists the folded/unfolded state of a single memory block without going
  /// through the editor's save/dirty flow — collapse is a view preference, so it
  /// should stick even when the user leaves without saving content edits.
  ///
  /// The fold is written to its own small store entry and **not** into the
  /// conversation. Writing it into the conversation meant re-encoding every
  /// message of every chat to record one boolean, which on a real store is tens
  /// of milliseconds of JSON on the UI thread — the hitch felt when a memory
  /// block was opened. The stored segment's flag is still updated in memory, so
  /// a later Save carries it too and nothing else has to know where it came from.
  void setSummarySegmentCollapsed(
      String conversationId, String segmentId, bool collapsed) {
    final cfg = _conversationById(conversationId)?.summary;
    if (cfg == null) return;
    for (final s in cfg.segments) {
      if (s.id != segmentId) continue;
      s.collapsed = collapsed;
      final folded = _summaryFolds.putIfAbsent(conversationId, () => <String>{});
      if (collapsed ? !folded.add(segmentId) : !folded.remove(segmentId)) {
        return; // Already recorded that way; nothing to write.
      }
      if (folded.isEmpty) _summaryFolds.remove(conversationId);
      unawaited(_persistSummaryFolds());
      return;
    }
  }

  /// Which memory blocks are folded shut, by conversation id. A view preference,
  /// kept apart from the conversations blob — see [setSummarySegmentCollapsed].
  final Map<String, Set<String>> _summaryFolds = <String, Set<String>>{};

  Future<void> _persistSummaryFolds() async {
    if (!_writable) return;
    await _storage.saveSummaryFolds(_summaryFolds);
  }

  /// Applies the remembered folds to the summaries just read from the store, and
  /// forgets folds for chats and blocks that no longer exist.
  void _applySummaryFolds() {
    var stale = false;
    for (final id in _summaryFolds.keys.toList()) {
      final cfg = _conversationById(id)?.summary;
      if (cfg == null) {
        _summaryFolds.remove(id);
        stale = true;
        continue;
      }
      final folded = _summaryFolds[id]!;
      final known = <String>{};
      for (final segment in cfg.segments) {
        if (folded.contains(segment.id)) {
          segment.collapsed = true;
          known.add(segment.id);
        }
      }
      if (known.length != folded.length) {
        stale = true;
        if (known.isEmpty) {
          _summaryFolds.remove(id);
        } else {
          _summaryFolds[id] = known;
        }
      }
    }
    if (stale) unawaited(_persistSummaryFolds());
  }

  /// Every chat that currently has a summary, newest-updated first — the source
  /// for the Library's global "Summary" section.
  List<Conversation> get conversationsWithSummary => [
        for (final c in _conversations)
          if (c.summary != null) c,
      ];

  // --- Image generation -----------------------------------------------------
  //
  // The studio is deliberately independent of the chat provider list: every chat
  // and every model can generate a picture because generation goes to an endpoint
  // of its own, with its own key. Nothing here depends on which model the
  // conversation runs on.

  ImageGenConfig _imageGen = const ImageGenConfig();

  /// How the image studio talks to its endpoint.
  ImageGenConfig get imageGen => _imageGen;

  /// Whether the studio has enough to make a request.
  bool get imageGenReady => _imageGen.isReady;

  Future<void> updateImageGen(ImageGenConfig next) async {
    _imageGen = next;
    notifyListeners();
    if (!_writable) return;
    await _storage.saveImageGen(next);
  }

  /// Generates pictures for [prompt] and files every one of them in the gallery,
  /// belonging to the character whose chat asked for them — so a picture made in
  /// Aria's chat is in Aria's album afterwards without anyone having to save it.
  ///
  /// [references] are pictures already in the app (a gallery entry, an
  /// attachment) handed to the endpoint as a starting point; their bytes are read
  /// here so the studio only has to pass references around.
  ///
  /// Throws [ChatApiException] with the same wording a failed chat request uses.
  Future<List<GalleryImage>> generateImages({
    required String prompt,
    String? conversationId,
    List<MessageImage> references = const <MessageImage>[],
  }) async {
    final config = _imageGen;
    if (!config.isReady) {
      throw ChatApiException(
        'Set an image model and endpoint in the studio settings first.',
      );
    }
    final conversation =
        conversationId == null ? null : _conversationById(conversationId);
    final result = await _imageClient.generate(
      config: config,
      prompt: config.composePrompt(prompt),
      references: _referenceBytes(references),
    );
    if (result.images.isEmpty) {
      throw ChatApiException('The host returned no pictures.');
    }
    final title = _pictureTitle(prompt);
    return addGalleryImages(
      result.images,
      characterId: conversation?.characterId,
      title: title,
      tags: const <String>['generated'],
    );
  }

  /// A short, searchable name for a generated picture: the first few words of the
  /// prompt, which is what someone looking for it later would type.
  static String _pictureTitle(String prompt) {
    final flat = prompt.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return 'Generated picture';
    return flat.length <= 48 ? flat : '${flat.substring(0, 48)}…';
  }

  /// Reads the bytes behind each reference, skipping anything unreadable — a
  /// missing reference should cost the reference, not the whole generation.
  List<ImageReference> _referenceBytes(List<MessageImage> references) {
    final out = <ImageReference>[];
    for (final image in references) {
      final file = avatarRefFile(image.ref);
      if (file == null) continue;
      try {
        if (!file.existsSync()) continue;
        final bytes = file.readAsBytesSync();
        if (bytes.isEmpty) continue;
        out.add(ImageReference(bytes: bytes, mime: image.mime));
      } catch (error) {
        debugPrint('MaiChat: could not read a reference picture ($error)');
      }
    }
    return out;
  }

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
    // The user's default persona becomes this thread's identity — unless it *is*
    // the character being chatted with, since nobody impersonates their own
    // partner.
    final persona = defaultPersona;
    if (persona != null && persona.id != character.id) {
      conversation.impersonateId = persona.id;
      conversation.impersonateName = persona.displayName;
    }
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
    // Seed the default persona onto a genuinely fresh thread. A reused empty
    // thread that already carries a persona (the user set one by hand) keeps it.
    final persona = defaultPersona;
    if (persona != null && target.impersonateId == null) {
      target.impersonateId = persona.id;
      target.impersonateName = persona.displayName;
    }
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

  /// Pins or unpins a chat. Pinned chats sort to the top of the chat lists and
  /// appear in a separate group on the home screen.
  Future<void> togglePinned(String id) async {
    final conversation = _conversationById(id);
    if (conversation == null) return;
    conversation.pinned = !conversation.pinned;
    notifyListeners();
    await _saveConversations();
  }

  /// Pins or unpins a whole **fork tree**. A row in the chat lists stands for
  /// the family, so the pin has to move with all of it; any member pinned makes
  /// the tree read as pinned, so unpinning clears every member. Used by the
  /// lists; [togglePinned] still pins one chat on its own.
  Future<void> togglePinnedTree(String id) async {
    final rootId = rootIdOf(_conversations, id);
    final members = _conversations
        .where((c) => rootIdOf(_conversations, c.id) == rootId)
        .toList();
    if (members.isEmpty) return;
    final pinned = members.any((c) => c.pinned);
    for (final c in members) {
      c.pinned = !pinned;
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

  /// Sends [text] with any [images] attached, and streams the reply into a
  /// placeholder turn. A picture on its own (no text) is a perfectly good send.
  Future<void> send(String text, {List<MessageImage> images = const []}) async {
    final prompt = text.trim();
    if ((prompt.isEmpty && images.isEmpty) || _streaming) return;

    // Resolve the provider before materializing a thread, so a misconfigured
    // app never spawns an empty conversation just to bail out.
    final current = _activeOrNull();
    final preset = current == null
        ? presetById(_defaultPresetId)
        : presetFor(current);
    if (_resolveProvider(preset) == null) return;

    final conversation = active;

    if (conversation.isEmpty) {
      // A picture with nothing typed still deserves a name for the chat lists.
      conversation.retitleFrom(prompt.isEmpty ? 'Picture' : prompt);
    }
    // In a group chat the user's turn is tagged with whoever they are speaking
    // as, so the transcript and the wire can label it (mirrors how each member's
    // replies carry their speaker).
    final speaking = conversation.isGroup ? impersonationFor(conversation) : null;
    conversation.messages.add(ChatMessage(
      role: 'user',
      content: prompt,
      images: images,
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

  // --- asking for a turn without typing one --------------------------------
  //
  // Three things Agnai's input bar can do that MaiChat could not: extend the
  // last reply, ask for another reply with nothing typed, and have the model
  // write the user's own next line. All three run through the same [_generate]
  // as a plain send, so budgets, keys, thinking, usage, swipes, summaries and
  // the stop button behave identically.

  /// The index of the turn [conversation]'s "continue" would extend: its newest
  /// assistant turn, and only when there is text there to carry on from. Null
  /// when there is nothing to continue — an empty chat, a chat whose last turn
  /// is the user's, or a failure notice.
  int? continuableIndex(Conversation conversation) {
    final messages = conversation.messages;
    if (messages.isEmpty) return null;
    final last = messages.length - 1;
    final message = messages[last];
    if (message.isUser || message.error) return null;
    if (message.content.trim().isEmpty) return null;
    return last;
  }

  /// Whether a reply can be asked for right now with nothing typed — the chat
  /// has something in it and nothing is in flight.
  bool canRespondAgain(Conversation conversation) =>
      !_streaming && conversation.messages.isNotEmpty;

  /// Extends the newest reply: the model is handed what it has already written
  /// and whatever comes back is appended to that same turn. Nothing is replaced,
  /// so the reply survives a failed or empty continuation.
  Future<void> continueReply() async {
    if (_streaming) return;
    final conversation = active;
    final index = continuableIndex(conversation);
    if (index == null) return;
    final speaker = conversation.isGroup
        ? characterFor(conversation, conversation.messages[index].speakerId)
        : null;
    await _generate(conversation, continueAt: index, responder: speaker);
  }

  /// Asks for another reply with nothing typed — the character speaks again on
  /// its own. In a group the usual round-robin picks who is up next, exactly as
  /// a plain send would.
  Future<void> respondAgain() async {
    if (_streaming) return;
    final conversation = active;
    if (conversation.messages.isEmpty) return;
    await _generate(conversation, nudgeNewReply: true);
  }

  /// Writes the user's next line for them and returns it, **without** putting
  /// anything in the chat: it lands in the composer, where it can be read, edited
  /// or thrown away before it is ever sent. Agnai posts its self-generated
  /// message straight into the conversation; a line you have not seen yet is
  /// exactly the kind of thing worth looking at first, and an unwanted one then
  /// costs a keystroke instead of a delete.
  ///
  /// [onProgress] receives the text as it arrives, on the same cadence a reply
  /// paints at, so the composer can fill in as it is written. Returns null when
  /// nothing came back (a stop, or a model that said nothing); throws
  /// [ChatApiException] when the request itself failed, with the same wording a
  /// failed reply carries.
  Future<String?> writeForUser({void Function(String text)? onProgress}) async {
    if (_streaming) return null;
    final conversation = active;
    final preset = presetFor(conversation);
    final base = _resolveProvider(preset);
    if (base == null) return null;
    final blocked = blockingBudget(base, base.model);
    if (blocked != null) throw ChatApiException(describeBudgetBlock(blocked));

    _streaming = true;
    _writingForUser = true;
    _stopRequested = false;
    JankLogger.instance.activity('streaming');
    notifyListeners();
    await _letTheFrameLand();

    final provider = _applyKey(base);
    final buffer = StringBuffer();
    var inputTokens = 0;
    var text = '';
    try {
      await _refreshMemory(conversation);
      final assembled = _assemble(conversation);
      inputTokens = assembled.totalTokens;
      // The instruction has to be the last thing the model reads, whatever the
      // preset left at the end of the payload, so it goes on unconditionally
      // rather than through the "only after a reply" rule a nudge follows.
      final history = _wirePayload(
        assembled.messages,
        instruction: _impersonationInstruction(conversation),
      );
      final clock = Stopwatch()..start();
      var painted = -_streamPaintMs;
      await for (final delta in _client.streamChat(
        provider: provider,
        history: history,
        params: assembled.params,
      )) {
        if (delta.text.isEmpty) continue;
        buffer.write(delta.text);
        final now = clock.elapsedMilliseconds;
        if (now - painted < _streamPaintMs) continue;
        painted = now;
        onProgress?.call(buffer.toString().trimLeft());
      }
      text = buffer.toString().trim();
      onProgress?.call(text);
      return text.isEmpty ? null : text;
    } on ChatApiException catch (_) {
      if (_stopRequested) {
        text = buffer.toString().trim();
        onProgress?.call(text);
        return text.isEmpty ? null : text;
      }
      _advanceKeyOnError(base);
      rethrow;
    } finally {
      _streaming = false;
      _writingForUser = false;
      _stopRequested = false;
      JankLogger.instance.activity('idle');
      // Only when a request actually went out: a refusal before that spent
      // nothing, and a zero-token entry in the ledger would say otherwise.
      if (inputTokens > 0) {
        recordUsage(
          base,
          provider.model,
          TokenUsage(
            inputTokens: inputTokens,
            outputTokens: _tokenizer.estimate(text),
            estimated: true,
          ),
        );
        await _persistUsage();
      }
      notifyListeners();
    }
  }

  /// What the model is told when it is writing the user's line rather than the
  /// character's. Shaped after the impersonation prompt both SillyTavern and
  /// Agnai use: whose voice, taken from the conversation, and a clear fence
  /// against writing the other side of it.
  String _impersonationInstruction(Conversation conversation) {
    final persona = impersonationFor(conversation);
    final character = conversation.isGroup
        ? nextSpeaker(conversation)
        : characterFor(conversation, conversation.characterId);
    final me = persona?.displayName.trim();
    final them = (character?.displayName ?? conversation.characterName ?? '')
        .trim();
    final myName = (me == null || me.isEmpty) ? 'the user' : me;
    final theirName = them.isEmpty ? 'the character' : them;
    return '[Write $myName’s next message in this conversation, in their voice '
        'and in the same style and tense as the rest of it. Write only '
        '$myName’s message — nothing for $theirName, and no narration of what '
        '$theirName does or says.]';
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

  /// How often a streaming reply repaints the chat, in milliseconds.
  ///
  /// A repaint rebuilds every visible bubble and re-derives the thinking split
  /// over the whole reply so far, so doing it per delta costs more the longer the
  /// answer gets — and it competes with the reader's own scrolling for the UI
  /// thread, which is exactly when smoothness matters most. ~20 batches a second
  /// still reads as text being typed.
  static const int _streamPaintMs = 50;

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
  /// With [continueAt] set, the turn at that index is *extended*: its text stays
  /// where it is, the model is handed it as the start of its own answer, and
  /// whatever comes back is appended to it. Nothing is replaced, so a failed or
  /// empty continuation can never eat the reply it was extending.
  ///
  /// [nudgeNewReply] appends a one-line instruction when the payload would
  /// otherwise end on the character's own words — see [_newReplyNudge].
  ///
  /// Two kinds of thinking are folded into the same place on the message: what
  /// the provider returns in its own field, and what the model writes inline
  /// between the preset's thinking tags. Either way the reply text stays clean
  /// and the thinking is timed, so the chat can show "Thought for X seconds".
  Future<void> _generate(Conversation conversation,
      {int? swipeInto,
      int? continueAt,
      bool nudgeNewReply = false,
      Character? responder}) async {
    final preset = presetFor(conversation);
    final base = _resolveProvider(preset);
    if (base == null) return;

    // A blocking budget refuses the send before anything is spent. Reported as an
    // error turn in the chat rather than a silent no-op: a reply that never comes
    // with no explanation is the worst version of this feature.
    final blocked = blockingBudget(base, base.model);
    if (blocked != null) {
      _appendErrorTurn(conversation, describeBudgetBlock(blocked));
      return;
    }

    // In a group chat every reply is spoken by one member. When the caller did
    // not name one (a plain send), round-robin picks who is up next.
    final speaker = conversation.isGroup
        ? (responder ?? nextSpeaker(conversation))
        : responder;

    // The turn the reply streams into, and (for a regeneration) the swipe that
    // was live before it, so an aborted attempt can be rolled back cleanly.
    final int target;
    if (continueAt != null) {
      target = continueAt;
    } else if (swipeInto == null) {
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
    // What a continuation is extending: kept aside so every write below is
    // "everything that was already there, plus what has arrived since".
    final existing = continueAt == null ? null : conversation.messages[target];
    final prefix = existing?.content ?? '';
    final prefixReasoning = existing?.reasoning ?? '';
    conversation.updatedAt = DateTime.now();
    _moveToTop(conversation);
    _streaming = true;
    _stopRequested = false;
    JankLogger.instance.activity('streaming');
    notifyListeners();
    // Everything above is bookkeeping; everything below takes real time. Let the
    // frame that shows the waiting turn reach the screen first, so the tap has a
    // visible effect immediately instead of after the assembly — which is the
    // whole of the pause that used to sit between pressing send and seeing the
    // message.
    await _letTheFrameLand();

    // Refresh semantic-recall caches before assembling, so the synchronous
    // [_assemble] can inject what was retrieved. Best-effort and time-boxed.
    await _refreshMemory(conversation);

    // The placeholder turn added above is not part of its own prompt, so the
    // window always stops short of [target].
    final assembled = _assemble(conversation, historyEnd: target, responder: speaker);
    final history = _wirePayload(
      assembled.messages,
      continuation: continueAt == null ? null : prefix,
      nudge: nudgeNewReply
          ? _newReplyNudge(conversation, speaker: speaker)
          : null,
    );
    final params = assembled.params;
    final tags = ReasoningTags(
      start: preset?.thinkStartTag.trim() ?? '',
      end: preset?.thinkEndTag.trim() ?? '',
    );

    // Everything the model sent as message text, tags included; the split into
    // answer and thinking is re-derived from it after every delta.
    final raw = StringBuffer();
    // Thinking the provider handed over separately.
    final thoughts = StringBuffer();
    final clock = Stopwatch()..start();
    int? thinkingMs;
    var answer = '';
    var thinking = '';
    // The last usage the host reported. Every dialect sends it at most once per
    // reply, but Gemini re-sends a running total, so the newest wins.
    TokenUsage? reported;

    // Narrow the key pool to the one this request should use.
    final provider = _applyKey(base);

    // Re-derives the split, times the thinking, writes the turn and repaints.
    // Called on a cadence rather than per delta — see [_streamPaintMs].
    void paint() {
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
          content: prefix + answer,
          reasoning: _joinThinking(prefixReasoning, thinking),
          thinkingMs: thinkingMs);
      notifyListeners();
    }

    var painted = -_streamPaintMs; // so the first delta always shows at once
    try {
      final deltas =
          _client.streamChat(provider: provider, history: history, params: params);
      await for (final delta in deltas) {
        if (delta.usage != null) reported = delta.usage;
        if (delta.reasoning.isNotEmpty) thoughts.write(delta.reasoning);
        if (delta.text.isNotEmpty) raw.write(delta.text);
        // A host can send a token every few milliseconds, and each repaint
        // rebuilds every visible bubble and re-splits the whole reply so far —
        // work that grows with the length of the answer. Painting on a cadence
        // instead leaves the UI thread with frames to spare for the reader's own
        // scrolling, and text arriving in ~20 batches a second still reads as
        // streaming. Whatever the last batch left unpainted is flushed below.
        final now = clock.elapsedMilliseconds;
        if (now - painted < _streamPaintMs) continue;
        painted = now;
        paint();
      }
      // Fold in whatever arrived after the last paint.
      paint();
      // A block the model never closed, or a reply that was thinking and nothing
      // else, still gets a duration once the stream ends.
      if (thinkingMs == null && thinking.trim().isNotEmpty) {
        thinkingMs = clock.elapsedMilliseconds;
      }
      if (answer.trim().isEmpty) {
        // A continuation that came back with nothing leaves the reply it was
        // extending exactly as it was — overwriting a finished message with a
        // failure notice would be the worst possible reading of "continue".
        if (continueAt != null) {
          _appendErrorTurn(
              conversation, 'The model had nothing more to add to that reply.');
        } else {
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
        }
      } else {
        _replaceAt(conversation, target,
            content: prefix + answer,
            reasoning: _joinThinking(prefixReasoning, thinking),
            thinkingMs: thinkingMs);
      }
    } on ChatApiException catch (e) {
      if (_stopRequested) {
        // Fold in anything the last paint left behind, so stopping keeps every
        // word that actually arrived rather than the last painted batch.
        paint();
        _finishStopped(conversation, target, prefix + answer,
            reasoning: _joinThinking(prefixReasoning, thinking),
            thinkingMs: thinkingMs);
      } else {
        // A failed request rotates an error-based pool to the next key.
        _advanceKeyOnError(base);
        // Same again for a failed continuation: the reply stands, and the
        // failure is reported under it instead of on top of it.
        if (continueAt != null) {
          _replaceAt(conversation, target,
              content: prefix + answer,
              reasoning: _joinThinking(prefixReasoning, thinking));
          _appendErrorTurn(conversation, e.message);
        } else {
          _replaceAt(conversation, target,
              content: e.message, reasoning: '', error: true);
        }
      }
    } finally {
      _streaming = false;
      _stopRequested = false;
      JankLogger.instance.activity('idle');
      conversation.updatedAt = DateTime.now();
      // Record what this reply used. A host that reported nothing gets an
      // estimate from the app's own tokenizer, marked as one — a missing number
      // would quietly under-report the bill, which is the worse failure.
      recordUsage(
        base,
        provider.model,
        reported ??
            TokenUsage(
              inputTokens: assembled.totalTokens,
              outputTokens: _tokenizer.estimate(answer) +
                  _tokenizer.estimate(thinking),
              estimated: true,
            ),
      );
      notifyListeners();
      // The finished reply is on screen the moment that notification is handled;
      // saving is not. Writing the store means encoding every message of every
      // chat, which is tens of milliseconds of JSON even on a desktop, so it
      // waits for the frame carrying the last of the reply rather than holding
      // it back — the alternative is a visible hitch exactly as a reply lands.
      await _letTheFrameLand();
      await _saveConversations();
      await _persistUsage();
      // Deliberately *not* saving the macro scopes here. The engine never
      // touches MacroVariables (grep macro_engine.dart), so this was a second
      // full rewrite of the entire preferences store after every single reply —
      // on Android each write rewrites the whole file, avatars included.
    }
    // Kick off a background summary if this chat is due one. Fire-and-forget so
    // the send completes immediately; it runs off the streaming path, saves and
    // notifies itself.
    unawaited(maybeSummarize(conversation));
    // Re-index this chat's messages for semantic recall (no-op unless recall is
    // on and embeddings are ready). Off the send path, like the summary.
    unawaited(_indexChat(conversation));
  }

  /// Waits for the frame that is about to be built to reach the screen, so the
  /// synchronous work that follows cannot swallow it.
  ///
  /// The ceiling matters as much as the wait: where frames are not being
  /// produced at all — a widget test's fake clock, a headless run — there is no
  /// end-of-frame to wait for, and a plain `await endOfFrame` would hang the
  /// send for ever. It is a real timer rather than a `Future.delayed` race so
  /// that the frame landing first leaves nothing behind (a stray pending timer
  /// fails a widget test on its own).
  Future<void> _letTheFrameLand() async {
    SchedulerBinding? binding;
    try {
      binding = SchedulerBinding.instance;
    } catch (_) {
      return; // No binding (a pure Dart test): nothing to wait for.
    }
    final landed = Completer<void>();
    final ceiling = Timer(const Duration(milliseconds: 32), () {
      if (!landed.isCompleted) landed.complete();
    });
    binding.endOfFrame.then((_) {
      if (!landed.isCompleted) landed.complete();
    });
    await landed.future;
    ceiling.cancel();
  }

  /// The assembled payload with the tails a generation may need added:
  /// [instruction] always, [nudge] only when the model would otherwise be
  /// looking at its own last message, and [continuation] when it is being handed
  /// the reply it is extending. Order matters — the continuation is a prefill and
  /// must be the very last thing on the wire.
  List<ChatMessage> _wirePayload(
    List<ChatMessage> messages, {
    String? continuation,
    String? nudge,
    String? instruction,
  }) {
    if (continuation == null && nudge == null && instruction == null) {
      return messages;
    }
    final out = List<ChatMessage>.of(messages);
    // Only worth saying when the payload would otherwise end on the character's
    // own words; with a user turn or a preset's trailing block last, the model
    // already knows a new message is wanted.
    if (nudge != null && out.isNotEmpty && out.last.role == 'assistant') {
      out.add(ChatMessage(role: 'user', content: nudge));
    }
    if (instruction != null) {
      out.add(ChatMessage(role: 'user', content: instruction));
    }
    if (continuation != null) {
      // Prefill: the reply so far goes out as the beginning of the model's own
      // answer, which is how all three dialects are told "keep writing this"
      // (Anthropic calls it exactly that; OpenAI and Gemini continue a trailing
      // assistant/model turn the same way). Trailing whitespace has to go —
      // Anthropic rejects a prefill that ends in it — while the message in the
      // chat keeps the text it always had.
      final seed = continuation.trimRight();
      if (seed.isNotEmpty) {
        out.add(ChatMessage(role: 'assistant', content: seed));
      }
    }
    // Merge again: the wire never carries two turns of the same role in a row.
    return mergeSameRole(out);
  }

  /// The line appended when a reply is asked for with no new user turn in front
  /// of it. Without it the model is looking at its own last message and will
  /// often just carry on writing that instead of answering afresh.
  String _newReplyNudge(Conversation conversation, {Character? speaker}) {
    final who = speaker?.displayName ??
        characterFor(conversation, conversation.characterId)?.displayName ??
        conversation.characterName ??
        '';
    final name = who.trim().isEmpty ? 'the character' : who.trim();
    return '[Write $name’s next message. Begin a new message rather than '
        'continuing or repeating the previous one.]';
  }

  /// Adds an assistant turn that only carries an error, for the failures that
  /// happen before a request is ever made — a budget standing in the way, say.
  void _appendErrorTurn(Conversation conversation, String message) {
    conversation.messages.add(ChatMessage(
      role: 'assistant',
      swipes: <MessageVariant>[MessageVariant(content: message, error: true)],
    ));
    conversation.updatedAt = DateTime.now();
    _moveToTop(conversation);
    notifyListeners();
    unawaited(_saveConversations());
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
  /// and returns its id — the "branch from here" action. Messages are
  /// deep-copied so the branch and its source diverge independently.
  ///
  /// The branch is not a loose new chat: [Conversation.parentId] and
  /// [Conversation.forkIndex] record where it split, which is what lets the
  /// Chat Graph draw the family and the chat lists show the whole tree as one
  /// row.
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
      // Branches are named after the tree's root rather than piling up
      // "(fork) (fork)" suffixes: the graph already says where each split, and
      // the root's title is what the chat lists show.
      title: _branchTitle(source),
      messages: copied,
      updatedAt: DateTime.now(),
    );
    // Record where this branch split from, so the Chat Graph can draw the
    // family tree. The parent is the immediate source (a branch of a branch
    // points at the branch it came from, not the original root).
    fork.parentId = source.id;
    fork.forkIndex = end;
    _conversations.insert(0, fork);
    _activeId = fork.id;
    notifyListeners();
    await _saveActiveId(fork.id);
    await _saveConversations();
    return fork.id;
  }

  /// "Tavern · Branch 3" — named after the tree's **root** and numbered across
  /// the whole tree, so a branch of a branch does not pile up suffixes and no
  /// two branches in one family read alike. The graph row says which chat it
  /// actually split from, so the title does not have to.
  String _branchTitle(Conversation source) {
    final rootId = rootIdOf(_conversations, source.id);
    final root = _conversationById(rootId) ?? source;
    final inTree = _conversations
        .where((c) => c.id != rootId && rootIdOf(_conversations, c.id) == rootId)
        .length;
    return '${root.title} · Branch ${inTree + 1}';
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
    final ranges = cfg.pendingRanges(count, force: force);
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
        // Always surface a failure — the user needs to know why nothing appeared,
        // regardless of the "notify" preference.
        final err = results
            .map((r) => r.error)
            .firstWhere((e) => e != null && e.isNotEmpty, orElse: () => null);
        _lastSummaryError = err ?? 'The summariser returned nothing.';
        _raiseSummaryNotice(err == null
            ? 'The summariser returned nothing.'
            : 'Summary failed: $err');
        return;
      }
      _lastSummaryError = null;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      if (cfg.method == SummaryMethod.rolling) {
        final content = ok.map((r) => r.text).join('\n\n');
        // Keep the user's hand-written blocks; only the generated one is replaced.
        final manual = cfg.segments.where((s) => s.manual).toList();
        cfg.segments
          ..clear()
          ..add(SummarySegment(
            id: '$stamp',
            title: 'Summary through message ${ok.last.endIndex}',
            content: content,
            startIndex: 0,
            endIndex: ok.last.endIndex,
            tokens: estimateTokens(content),
          ))
          ..addAll(manual);
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
      if (cfg.title.trim().isEmpty) cfg.title = '${c.title} summary';
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

    // Which of the three scenarios this turn runs under, resolved once here so
    // the marker block, the fallbacks below and the inspectors all agree.
    final scenario = scenarioFor(conversation, character);
    final cardScenario = character?.activeScenario.trim() ?? '';
    final chosenScenario =
        scenario.trim().isNotEmpty && scenario.trim() != cardScenario;

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
      forceActivate: _forcedLore[conversation.id] ?? const <String>{},
    );

    // Semantic-recall text, retrieved before this call by [_refreshMemory].
    final memoryText = _memoryInjection[conversation.id] ?? '';
    final docsText = _docInjection[conversation.id] ?? '';

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
        memoryText: memoryText,
        docsText: docsText,
        memoryDepth: _embeddingConfig.depth,
        scenario: scenario,
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
        addPrefix('Character definition',
            character.definition(userName: userName, scenario: scenario));
      }
      // A scenario the user *chose* — plugged in from the library, or written for
      // this chat — must reach the model even under a preset that carries no
      // scenario marker, which is otherwise where it would silently vanish. Only
      // the chosen case is rescued: a card's own scenario under a marker-less
      // preset behaves exactly as it always has.
      if (chosenScenario &&
          !_presetEmitsScenario(preset) &&
          !(character != null && !_presetEmitsDefinition(preset))) {
        addPrefix('Scenario', scenario);
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
      //
      // A chosen scenario forces the same rebuild in a one-to-one thread. The
      // stored prompt is a snapshot taken when the chat was created and it has
      // the *card's* scenario baked into it, so merely prefixing the new one
      // would send both and leave the model to guess which setting it is in.
      // Rebuilding costs anything an import had merged into that snapshot, which
      // is the lesser loss — and only happens on a thread with no preset at all.
      final rebuild = character != null &&
          (conversation.isGroup || chosenScenario);
      addPrefix(
        'Character (stored)',
        rebuild
            ? character.composedSystemPrompt(
                userName: userName, scenario: scenario)
            : conversation.systemPrompt,
      );
      // With the card gone there is nothing to rebuild from, so a scenario
      // chosen since then rides as its own block rather than not at all.
      if (chosenScenario && character == null) {
        addPrefix('Scenario', scenario);
      }
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
      // No preset means no depth slots, so recalled memory/documents ride as
      // leading blocks too rather than being retrieved and then discarded.
      addPrefix('Recalled memory', memoryText);
      addPrefix('Related documents', docsText);
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
      messages: _wireImages(mergeSameRole(messages)),
      params: params,
      sections: sections,
      totalTokens: total,
      maxContext: maxContext,
    );
  }

  // --- attachments on the wire ---------------------------------------------

  /// How many pictures one request may carry, newest first.
  ///
  /// There is no size limit on a picture anywhere in this app (see [AvatarStore])
  /// and there should not be one — but a *request* is different from a file: ten
  /// photographs straight off a camera become tens of megabytes of base64 on
  /// every single turn, re-uploaded for the rest of the chat. Capping the count
  /// keeps "the model remembers the picture" true for the pictures that are still
  /// being talked about, without a chat quietly becoming unsendable.
  static const int kMaxWireImages = 8;

  /// Base64 payloads by picture reference, so a chat that keeps re-sending the
  /// same attachment reads and encodes it once. Bounded by [_maxImageDataBytes];
  /// nothing here is persisted.
  final Map<String, String> _imageData = <String, String>{};

  static const int _maxImageDataBytes = 32 * 1024 * 1024;

  /// [messages] with each attachment's bytes resolved, newest [kMaxWireImages]
  /// kept and the rest dropped.
  ///
  /// Reading the files is synchronous on purpose: this is the one place both a
  /// real send and the "View prompt" / "Info" inspectors pass through, and those
  /// two are synchronous by construction. It happens once per send, off any
  /// animation, and the cache above means a long chat pays for each picture once.
  List<ChatMessage> _wireImages(List<ChatMessage> messages) {
    if (!messages.any((m) => m.hasImages)) return messages;
    var budget = kMaxWireImages;
    final out = List<ChatMessage>.of(messages);
    for (var i = out.length - 1; i >= 0; i--) {
      final message = out[i];
      if (!message.hasImages) continue;
      final kept = <MessageImage>[];
      for (final image in message.images.reversed) {
        if (budget <= 0) break;
        if (image.isUrl) {
          // The host fetches it itself; there is nothing to read or cache.
          kept.insert(0, image);
          budget--;
          continue;
        }
        final data = _imagePayload(image.ref);
        if (data == null) continue; // The file has gone: send the text alone.
        kept.insert(0, image.withData(data));
        budget--;
      }
      out[i] = message.copyWith(images: kept);
    }
    return out;
  }

  /// The base64 of the picture [ref] names, or null when there is no readable
  /// file behind it.
  String? _imagePayload(String ref) {
    final trimmed = ref.trim();
    if (trimmed.isEmpty) return null;
    final cached = _imageData[trimmed];
    if (cached != null) return cached;
    final file = avatarRefFile(trimmed);
    if (file == null) return null;
    try {
      if (!file.existsSync()) return null;
      final encoded = base64Encode(file.readAsBytesSync());
      var held = _imageData.values.fold<int>(0, (sum, d) => sum + d.length);
      // Evict oldest-first until the newcomer fits; the map preserves insertion
      // order, which is close enough to least-recently-added for this.
      while (_imageData.isNotEmpty &&
          held + encoded.length > _maxImageDataBytes) {
        final oldest = _imageData.keys.first;
        held -= _imageData.remove(oldest)?.length ?? 0;
      }
      _imageData[trimmed] = encoded;
      return encoded;
    } catch (error) {
      debugPrint('MaiChat: could not read an attachment ($error)');
      return null;
    }
  }

  /// Files [bytes] as a chat attachment, returning what a message should carry —
  /// or null when there is nowhere to write it. The picture becomes a file in the
  /// pictures directory like every other picture in the app; nothing about an
  /// attachment goes into the preferences store but its reference.
  Future<MessageImage?> storeAttachment(Uint8List bytes) async {
    if (bytes.isEmpty) return null;
    final ref = await storePicture(bytes);
    if (ref == null) return null;
    return MessageImage(ref: ref, mime: mimeForBytes(bytes));
  }

  /// Posts a picture into a thread as a turn of its own — the image studio's
  /// "share in the chat". Nothing is generated: the picture simply joins the
  /// transcript, so it is on screen and (like any other attachment) rides along
  /// with the next request.
  Future<void> postImageToChat(
    String conversationId,
    MessageImage image, {
    String text = '',
  }) async {
    final conversation = _conversationById(conversationId);
    if (conversation == null || image.ref.trim().isEmpty) return;
    conversation.messages.add(ChatMessage(
      role: 'user',
      content: text.trim(),
      images: <MessageImage>[image],
    ));
    if (conversation.title.trim().isEmpty || conversation.messages.length == 1) {
      conversation.retitleFrom(text.trim().isEmpty ? 'Picture' : text);
    }
    conversation.updatedAt = DateTime.now();
    _moveToTop(conversation);
    notifyListeners();
    await _saveConversations();
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

  /// Whether [preset] has an enabled scenario marker to put the scenario in.
  /// A preset can carry the rest of the definition and still leave this one out,
  /// which is why it is asked separately from [_presetEmitsDefinition].
  bool _presetEmitsScenario(Preset preset) {
    for (final entry in preset.promptOrder) {
      if (entry.identifier == PromptId.scenario && entry.enabled) {
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
