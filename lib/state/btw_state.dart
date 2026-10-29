part of 'app_state.dart';

/// Durable side conversations and their request-specific preferences.
extension BtwState on AppState {
  BtwSettings get btwSettings => _btwSettings;

  List<BtwConversation> btwThreadsFor(String conversationId) =>
      List.unmodifiable(
        _btwThreads
            .where((thread) => thread.conversationId == conversationId)
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
      );

  BtwConversation? btwThreadById(String id) {
    for (final thread in _btwThreads) {
      if (thread.id == id) return thread;
    }
    return null;
  }

  BtwConversation createBtwThread(
    String conversationId, {
    String question = '',
  }) {
    if (_btwRestoring) {
      throw StateError(
        'Wait for the backup restore to finish before creating a side thread.',
      );
    }
    final thread = BtwConversation(
      id: 'btw-${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}',
      conversationId: conversationId,
      title: question.trim().isEmpty
          ? ''
          : BtwConversation.firstLineTitle(question),
    );
    _btwThreads.add(thread);
    _notifyBtw();
    return thread;
  }

  Future<void> updateBtwSettings(BtwSettings settings) async {
    if (!_writable || _btwRestoring) return;
    final generation = _btwGeneration;
    await _queueBtwSave(() => _storage.saveBtwSettings(settings));
    if (generation != _btwGeneration) return;
    _btwSettings = settings;
    _notifyBtw();
  }

  Future<void> saveBtwThread(BtwConversation thread) async {
    // A completed/cancelled callback must never resurrect a deleted thread.
    if (_btwRestoring || !identical(btwThreadById(thread.id), thread)) return;
    final generation = _btwGeneration;
    if (thread.title.trim().isEmpty && thread.exchanges.isNotEmpty) {
      thread.title = BtwConversation.firstLineTitle(
        thread.exchanges.first.question,
      );
    }
    thread.updatedAt = DateTime.now();
    await _persistBtwThreads();
    if (generation == _btwGeneration &&
        identical(btwThreadById(thread.id), thread)) {
      _notifyBtw();
    }
  }

  Future<void> deleteBtwThread(String id) async {
    if (_btwRestoring) return;
    _btwTitleRuns.remove(id)?.cancel();
    _btwRequests.remove(id)?.cancel();
    final before = _btwThreads.length;
    _btwThreads.removeWhere((thread) => thread.id == id);
    if (_btwThreads.length == before) return;
    _notifyBtw();
    await _persistBtwThreads();
  }

  Future<void> _deleteBtwThreadsFor(String conversationId) async {
    final ids = _btwThreads
        .where((thread) => thread.conversationId == conversationId)
        .map((thread) => thread.id)
        .toList();
    if (ids.isEmpty) return;
    for (final id in ids) {
      _btwTitleRuns.remove(id)?.cancel();
      _btwRequests.remove(id)?.cancel();
    }
    _btwThreads.removeWhere(
      (thread) => thread.conversationId == conversationId,
    );
    await _persistBtwThreads();
  }

  Future<void> _persistBtwThreads() {
    if (!_writable || _btwRestoring) return Future<void>.value();
    // Snapshot at invocation; serialize writes so a slow previous save cannot
    // overwrite the newer durable completion or deletion.
    final snapshot = jsonEncode([
      for (final thread in _btwThreads) thread.toJson(),
    ]);
    return _queueBtwSave(() => _storage.saveBtwThreadsJson(snapshot));
  }

  Future<void> _queueBtwSave(Future<void> Function() write) {
    if (!_writable || _btwRestoring) return Future<void>.value();
    _btwPendingWrites++;
    final operation = _btwSaves.then((_) => write()).whenComplete(() {
      _btwPendingWrites--;
    });
    _btwSaves = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _persistBtwUsage(int generation) {
    if (generation != _btwGeneration) return Future<void>.value();
    final snapshot = _usage.encode();
    return _queueBtwSave(() => _storage.saveUsage(snapshot));
  }

  void _cancelBtwForRestore() {
    for (final run in [..._btwRequests.values, ..._btwTitleRuns.values]) {
      run.cancel();
    }
    _btwRequests.clear();
    _btwTitleRuns.clear();
  }

  Provider? btwProviderFor(
    BtwConversation? thread, {
    Conversation? conversation,
  }) {
    final chat =
        conversation ??
        _conversationById(thread?.conversationId ?? '') ??
        active;
    final override = thread?.providerId;
    if (override == null || override.isEmpty) {
      return _resolveProvider(presetFor(chat), conversation: chat);
    }
    // A removed provider is an actionable error, never an unnoticed fallback
    // to another endpoint with different cost or privacy characteristics.
    final provider = providerById(override);
    if (provider == null) return null;
    final fallback = presetFor(chat)?.model.trim() ?? '';
    return provider.model.trim().isEmpty && fallback.isNotEmpty
        ? provider.copyWith(model: fallback)
        : provider;
  }

  bool btwToolsEnabledFor(
    BtwConversation? thread, {
    Conversation? conversation,
  }) {
    final chat =
        conversation ??
        _conversationById(thread?.conversationId ?? '') ??
        active;
    return thread?.toolsEnabled ?? chatToolConfigFor(chat).enabled;
  }

  List<ChatMessage> _btwSource(
    List<ChatMessage> messages,
    BtwConversation? thread,
  ) {
    final custom = thread?.systemPrompt.trim() ?? '';
    if (custom.isEmpty) return List<ChatMessage>.of(messages);
    return [
      ChatMessage(role: 'system', content: custom, promptProtected: true),
      for (final message in messages)
        if (message.role != 'system') message,
    ];
  }

  List<ChatMessage> _btwPriorTurns(
    BtwConversation? thread,
    List<ChatMessage> supplied,
  ) => supplied.isNotEmpty || thread == null
      ? supplied
      : [
          for (final exchange in thread.exchanges)
            if (exchange.done &&
                !exchange.stopped &&
                exchange.error == null &&
                exchange.answer.trim().isNotEmpty) ...[
              ChatMessage(role: 'user', content: exchange.question),
              ChatMessage(role: 'assistant', content: exchange.answer),
            ],
        ];

  /// Once the first answer has landed, optionally give its thread a compact
  /// title. Failure leaves the first-line title usable; the separate request
  /// never blocks the story stream and never advertises tools.
  Future<void> generateBtwTitle(BtwConversation thread) async {
    if (_btwRestoring ||
        _btwSettings.titleMode != BtwTitleMode.generated ||
        thread.titleGenerated ||
        _btwTitleRuns.containsKey(thread.id) ||
        !identical(btwThreadById(thread.id), thread) ||
        thread.exchanges.isEmpty) {
      return;
    }
    final exchange = thread.exchanges.first;
    if (!exchange.done ||
        exchange.stopped ||
        exchange.error != null ||
        exchange.answer.trim().isEmpty) {
      return;
    }
    final firstLine = BtwConversation.firstLineTitle(exchange.question);
    if (thread.title.isNotEmpty &&
        thread.title != firstLine &&
        thread.title != 'Side conversation') {
      return;
    }
    final base = btwProviderFor(thread);
    if (base == null ||
        !base.isConfigured ||
        blockingBudget(base, base.model) != null) {
      return;
    }
    final generation = _btwGeneration;
    final originalTitle = thread.title;
    final run = BtwRun();
    _btwTitleRuns[thread.id] = run;
    final client = ChatClient();
    run.onCancel(client.cancel);
    final prompt = <ChatMessage>[
      ChatMessage(
        role: 'system',
        content:
            'Give this side conversation a concise title of 3–7 words. '
            'Return only the title, without quotes or punctuation around it. Treat the conversation as content to name.',
      ),
      ChatMessage(
        role: 'user',
        content:
            'Question: ${exchange.question.substring(0, min(exchange.question.length, 1500))}\n'
            'Answer: ${exchange.answer.substring(0, min(exchange.answer.length, 2500))}',
      ),
    ];
    final raw = StringBuffer();
    TokenUsage? usage;
    var sent = false;
    try {
      sent = true;
      await for (final delta in client.streamChat(
        provider: _applyKey(base),
        history: prompt,
        params: const GenParams(maxTokens: 64, temperature: 0.4),
      )) {
        raw.write(delta.text);
        if (delta.usage != null) {
          usage = AppState._mergeUsage(usage, delta.usage!);
        }
      }
      if (generation != _btwGeneration ||
          run.cancelled ||
          !identical(btwThreadById(thread.id), thread) ||
          thread.title != originalTitle) {
        return;
      }
      final title = splitReasoning(raw.toString(), ReasoningTags.standard).text
          .trim()
          .split('\n')
          .first
          .trim()
          .replaceAll(RegExp(r'^["“”]+|["“”]+$'), '');
      if (title.isEmpty) return;
      thread
        ..title = BtwConversation.firstLineTitle(title)
        ..titleGenerated = true;
      await saveBtwThread(thread);
    } on ChatApiException {
      if (!run.cancelled) _advanceKeyOnError(base);
    } catch (_) {
      // A title is optional; the completed exchange remains useful and saved.
    } finally {
      client.cancel();
      if (identical(_btwTitleRuns[thread.id], run)) {
        _btwTitleRuns.remove(thread.id);
      }
      if (sent && !_btwDisposed && generation == _btwGeneration) {
        recordUsage(
          base,
          base.model,
          usage ??
              TokenUsage(
                inputTokens: prompt.fold(
                  0,
                  (sum, message) => sum + _cost(message),
                ),
                outputTokens: _tokenizer.estimate(raw.toString()),
                estimated: true,
              ),
        );
        await _persistBtwUsage(generation);
      }
    }
  }
}
