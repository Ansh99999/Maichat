import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/btw_conversation.dart';
import '../models/message.dart';
import '../services/btw.dart';
import '../services/chat_client.dart';
import '../state/app_state.dart';

typedef BtwThreadAsk =
    Future<String> Function(
      String question,
      List<ChatMessage> history,
      BtwRun run,
      void Function(String) onProgress,
    );

/// Keeps side threads separate from the main conversation, with optional storage.
class BtwThreadController extends ChangeNotifier {
  BtwThreadController({required this.ask});

  final BtwThreadAsk ask;
  final List<BtwExchange> _local = [];
  AppState? _state;
  String? _conversationId;
  BtwConversation? _activeThread;
  final Map<String, String> _selectedIds = {};
  final List<bool Function()> _transientDismissHandlers = [];
  UnmodifiableListView<BtwExchange>? _exchangeView;
  BtwRun? _run;
  Timer? _paint;
  String _pending = '';
  bool _disposed = false;

  AppState? get state => _state;
  String? get conversationId => _conversationId;
  BtwConversation? get activeThread => _activeThread;
  List<BtwExchange> get _exchanges => _activeThread?.exchanges ?? _local;
  List<BtwExchange> get exchanges =>
      _exchangeView ??= UnmodifiableListView(_exchanges);
  List<BtwConversation> get threads => _state != null && _conversationId != null
      ? _state!.btwThreadsFor(_conversationId!)
      : const [];
  bool get busy => _run != null;

  void addTransientDismissHandler(bool Function() handler) =>
      _transientDismissHandlers.add(handler);
  void removeTransientDismissHandler(bool Function() handler) =>
      _transientDismissHandlers.remove(handler);
  bool dismissTransientUi() {
    for (final handler in _transientDismissHandlers.reversed) {
      if (handler()) return true;
    }
    return false;
  }

  /// Called during the chat's build: updates the binding without notifying.
  /// A blank thread is created on an explicit command or the first question.
  void bind(AppState state, String conversationId) {
    if (_disposed) return;
    if (_state == state && _conversationId == conversationId) {
      final current = _activeThread;
      if (current != null && state.btwThreadById(current.id) == current) return;
    } else {
      stop(notify: false);
      _state = state;
      _conversationId = conversationId;
      _activeThread = null;
      _local.clear();
    }
    final saved = threads;
    _activeThread =
        state.btwThreadById(_selectedIds[conversationId] ?? '') ??
        (saved.isEmpty ? null : saved.first);
    _exchangeView = null;
  }

  void startThread({bool notify = true}) {
    if (_disposed) return;
    stop(notify: false);
    final state = _state;
    final conversationId = _conversationId;
    _activeThread = state != null && conversationId != null
        ? state.createBtwThread(conversationId)
        : null;
    if (_activeThread != null) {
      _selectedIds[_activeThread!.conversationId] = _activeThread!.id;
    }
    _local.clear();
    _exchangeView = null;
    _pending = '';
    unawaited(_save(_activeThread));
    if (notify) notifyListeners();
  }

  void selectThread(BtwConversation thread) {
    if (_disposed || thread.conversationId != _conversationId) return;
    if (_activeThread?.id == thread.id) return;
    stop(notify: false);
    _activeThread = thread;
    _selectedIds[thread.conversationId] = thread.id;
    _exchangeView = null;
    _pending = '';
    notifyListeners();
  }

  Future<void> deleteThread(BtwConversation thread) async {
    final state = _state;
    if (state == null || _disposed) return;
    final selected = _activeThread?.id == thread.id;
    if (selected) stop(notify: false);
    await state.deleteBtwThread(thread.id);
    if (_disposed) return;
    if (selected) {
      _selectedIds.remove(thread.conversationId);
      final saved = threads;
      _activeThread = saved.isEmpty ? null : saved.first;
      _exchangeView = null;
      _local.clear();
    }
    notifyListeners();
  }

  Future<void> updateThread({
    String? systemPrompt,
    String? providerId,
    bool setProvider = false,
    bool? toolsEnabled,
    bool setTools = false,
  }) async {
    if (_disposed) return;
    if (_activeThread == null) startThread(notify: false);
    final thread = _activeThread;
    if (thread == null) return;
    if (systemPrompt != null) thread.systemPrompt = systemPrompt;
    if (setProvider) thread.providerId = providerId;
    if (setTools) thread.toolsEnabled = toolsEnabled;
    notifyListeners();
    await _save(thread);
  }

  Future<void> _save(BtwConversation? thread) async {
    if (thread == null || _state == null) return;
    await _state!.saveBtwThread(thread);
  }

  Future<void> submit(String text) async {
    final question = text.trim();
    if (question.isEmpty || busy || _disposed) return;
    if (_state != null && _activeThread == null) startThread(notify: false);
    final thread = _activeThread;
    final history = <ChatMessage>[
      for (final exchange in _exchanges)
        if (exchange.done && exchange.error == null && !exchange.stopped) ...[
          ChatMessage(role: 'user', content: exchange.question),
          ChatMessage(role: 'assistant', content: exchange.answer),
        ],
    ];
    final exchange = BtwExchange(question);
    final run = _run = BtwRun();
    _pending = '';
    _exchanges.add(exchange);
    if (thread != null && thread.title.trim().isEmpty) {
      thread.title = BtwConversation.firstLineTitle(question);
    }
    notifyListeners();
    unawaited(_save(thread));
    try {
      final answer = await ask(question, history, run, (text) {
        if (_disposed || _run != run) return;
        _pending = text;
        _paint ??= Timer(const Duration(milliseconds: 50), () {
          _paint = null;
          if (_disposed || _run != run) return;
          exchange.answer = _pending;
          notifyListeners();
        });
      });
      if (_disposed || _run != run) return;
      exchange.answer = answer;
    } catch (error) {
      if (_disposed || _run != run) return;
      exchange.answer = _pending;
      exchange.error = error is ChatApiException ? error.message : '$error';
    } finally {
      if (!_disposed && _run == run) {
        _paint?.cancel();
        _paint = null;
        _run = null;
        exchange.done = true;
        notifyListeners();
        await _save(thread);
        if (thread != null &&
            thread.exchanges.length == 1 &&
            exchange.error == null &&
            !exchange.stopped &&
            exchange.answer.isNotEmpty) {
          await _state?.generateBtwTitle(thread);
          if (!_disposed && _activeThread == thread) notifyListeners();
        }
      }
    }
  }

  void stop({bool notify = true}) {
    final run = _run;
    if (run == null) return;
    _run = null;
    _paint?.cancel();
    _paint = null;
    final exchange = _exchanges.last;
    exchange
      ..answer = _pending
      ..done = true
      ..stopped = true;
    run.cancel();
    unawaited(_save(_activeThread));
    if (notify && !_disposed) notifyListeners();
  }

  void reset({bool notify = false}) => startThread(notify: notify);

  @override
  void dispose() {
    _disposed = true;
    stop(notify: false);
    super.dispose();
  }
}
