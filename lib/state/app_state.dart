import 'package:flutter/foundation.dart';

import '../models/appearance.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../models/settings.dart';
import '../services/chat_client.dart';
import '../services/storage.dart';

/// Single source of truth for settings, threads and the in-flight reply.
class AppState extends ChangeNotifier {
  AppState({Storage? storage, ChatClient? client})
      : _storage = storage ?? Storage(),
        _client = client ?? ChatClient();

  final Storage _storage;
  final ChatClient _client;

  final List<Conversation> _conversations = <Conversation>[];
  AppSettings _settings = const AppSettings();
  Appearance _appearance = const Appearance();
  String? _activeId;
  bool _ready = false;
  bool _streaming = false;
  bool _stopRequested = false;

  List<Conversation> get conversations => List.unmodifiable(_conversations);
  AppSettings get settings => _settings;
  Appearance get appearance => _appearance;
  bool get ready => _ready;
  bool get streaming => _streaming;

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
    _settings = await _storage.loadSettings();
    _appearance = await _storage.loadAppearance();
    final stored = await _storage.loadConversations()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _conversations
      ..clear()
      ..addAll(stored);
    _activeId = await _storage.loadActiveId();
    _ready = true;
    notifyListeners();
  }

  Future<void> updateSettings(AppSettings next) async {
    _settings = next;
    notifyListeners();
    await _storage.saveSettings(next);
  }

  Future<void> updateAppearance(Appearance next) async {
    if (next == _appearance) return;
    _appearance = next;
    notifyListeners();
    await _storage.saveAppearance(next);
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

    final conversation = active;
    if (conversation.isEmpty) conversation.retitleFrom(prompt);
    conversation.messages.add(ChatMessage(role: 'user', content: prompt));
    // Failure notices are display-only, so they never go back to the model.
    final history = List<ChatMessage>.unmodifiable(
      conversation.messages.where((m) => !m.error),
    );
    conversation.messages.add(ChatMessage(role: 'assistant', content: ''));
    conversation.updatedAt = DateTime.now();
    _moveToTop(conversation);
    _streaming = true;
    _stopRequested = false;
    notifyListeners();

    final reply = StringBuffer();
    try {
      final deltas =
          _client.streamChat(settings: _settings, history: history);
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

  Future<List<String>> fetchModels() => _client.listModels(_settings);

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
