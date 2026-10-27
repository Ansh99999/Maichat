part of 'app_state.dart';

class _ChatToolBudget {
  int remaining = 100;
  final Set<ImageClient> imageClients = {};
  void cancelImages() {
    for (final client in imageClients.toList()) {
      client.cancel();
    }
  }
}

/// Chat-owned orchestration. Studio supplies transport types, not a draft session.
extension ChatToolsState on AppState {
  String _toolEndpoint(Provider p) {
    final uri = Uri.tryParse(p.baseUrl);
    return uri == null
        ? ''
        : '${uri.scheme}://${uri.host}:${uri.port}${uri.path}';
  }

  int _toolRequestCost(
    Provider provider,
    List<AgentMessage> messages,
    List<ToolSpec> tools,
    AgentParams params,
  ) {
    final shown = [
      for (final m in messages)
        m.withImages([for (final image in m.images) image.elided()]),
    ];
    return _tokenizer.estimate(
          jsonEncode(AgentClient.body(provider, shown, tools, params)),
        ) +
        messages.fold<int>(0, (sum, m) => sum + m.images.length * 1024);
  }

  ChatToolConfig chatToolConfigFor(Conversation? conversation) =>
      conversation?.chatToolConfig ?? _chatTools;

  Future<void> resetChatToolConfig(String conversationId) async {
    final c = _conversationById(conversationId);
    if (c == null) throw StateError('Chat no longer exists.');
    final previous = c.chatToolConfig;
    c.chatToolConfig = null;
    try {
      await _saveChat(c);
    } catch (_) {
      c.chatToolConfig = previous;
      rethrow;
    }
    _notifyChatTools();
  }

  void _deduplicateChatCalls(List<ToolCall> calls) {
    final unique = <String, ToolCall>{};
    for (final call in calls) {
      final previous = unique[call.id];
      if (previous != null &&
          (previous.name != call.name ||
              jsonEncode(previous.arguments) != jsonEncode(call.arguments))) {
        throw ChatApiException(
          'The model reused a tool call ID with different arguments. No action from that round was run.',
        );
      }
      unique[call.id] = call;
    }
    calls
      ..clear()
      ..addAll(unique.values);
  }

  List<ChatToolDefinition> chatToolDefinitionsFor(Conversation? conversation) {
    final byName = {for (final d in chatToolBuiltIns) d.name: d};
    for (final d in chatToolConfigFor(conversation).customTools) {
      if (!byName.containsKey(d.name) || !byName[d.name]!.builtin) {
        byName[d.name] = d;
      }
    }
    final cfg = chatToolConfigFor(conversation);
    final overrides = cfg.followUpOverrides;
    final tagOverrides = cfg.tagOverrides;
    return [
      for (final definition in byName.values)
        if (definition.builtin &&
            (overrides.containsKey(definition.name) ||
                tagOverrides.containsKey(definition.name)))
          definition.copyWith(
            followUp: overrides[definition.name] ?? definition.followUp,
            tags: tagOverrides[definition.name] ?? definition.tags,
          )
        else
          definition,
    ];
  }

  Future<void> saveChatToolConfig(
    ChatToolConfig config, {
    String? conversationId,
  }) async {
    if (!_writable) {
      throw StateError(
        'The app is read-only until its storage problem is resolved.',
      );
    }
    if (config.maxRounds < 1 ||
        config.maxRounds > 10 ||
        config.maxCalls < 1 ||
        config.maxCalls > 50) {
      throw const FormatException('Use 1–10 rounds and 1–50 calls.');
    }
    for (final d in config.customTools) {
      _validateToolDefinition(d);
    }
    if (conversationId == null) {
      await _storage.saveChatTools(config);
      _chatTools = config;
    } else {
      final c = _conversationById(conversationId);
      if (c == null) throw StateError('Chat no longer exists.');
      final old = c.chatToolConfig;
      c.chatToolConfig = config;
      try {
        await _saveChat(c);
      } catch (_) {
        c.chatToolConfig = old;
        rethrow;
      }
    }
    _notifyChatTools();
  }

  void _validateToolDefinition(ChatToolDefinition d) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$').hasMatch(d.name) ||
        d.description.trim().isEmpty ||
        d.action.isEmpty ||
        chatToolBuiltIns.any((v) => v.name == d.name)) {
      throw const FormatException(
        'A custom tool needs a unique name, description and executable recipe.',
      );
    }
    if (d.parameters['type'] != 'object') {
      throw const FormatException('Tool parameters must be an object schema.');
    }
    validateChatToolSchema(d.parameters);
    validateChatToolRecipe(d.action);
    if (jsonEncode(d.toJson()).length > 100000) {
      throw const FormatException('Tool definition is too large.');
    }
  }

  String exportChatTools({String? conversationId}) {
    final c = conversationId == null ? null : _conversationById(conversationId);
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'maichat-tools',
      'version': 1,
      'tools': chatToolConfigFor(c).customTools.map((d) => d.toJson()).toList(),
    });
  }

  Future<void> importChatTools(String source, {String? conversationId}) async {
    final parsed = jsonDecode(source);
    if (parsed is! Map ||
        parsed['format'] != 'maichat-tools' ||
        parsed['version'] != 1 ||
        parsed['tools'] is! List) {
      throw const FormatException('Choose a MaiChat tools version 1 export.');
    }
    final c = conversationId == null ? null : _conversationById(conversationId);
    final cfg = chatToolConfigFor(c);
    final names = chatToolDefinitionsFor(c).map((v) => v.name).toSet();
    final additions = <ChatToolDefinition>[];
    for (final raw in parsed['tools'] as List) {
      if (raw is! Map) throw const FormatException('Invalid tool definition.');
      final d = ChatToolDefinition.fromJson(Map<String, dynamic>.from(raw));
      _validateToolDefinition(d);
      if (!names.add(d.name)) {
        throw FormatException(
          'A tool named ${d.name} already exists. Rename it before importing.',
        );
      }
      additions.add(d);
    }
    await saveChatToolConfig(
      cfg.copyWith(customTools: [...cfg.customTools, ...additions]),
      conversationId: conversationId,
    );
  }

  String _toolAnchor(Conversation c, int end) {
    var hash = 0x811c9dc5;
    for (final m in c.messages.take(end)) {
      hash = _nextToolHash(hash, m);
    }
    return hash.toRadixString(16);
  }

  int _nextToolHash(int hash, ChatMessage m) {
    for (final ch
        in '${m.role}:${m.content}:${m.swipeIndex}:${m.toolRun?.id ?? ''}\u0000'
            .codeUnits) {
      hash = ((hash ^ ch) * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  ChatToolProjection chatToolProjection(Conversation c, {int? historyEnd}) {
    final end = (historyEnd ?? c.messages.length).clamp(0, c.messages.length);
    // Ordinary streaming frames must not walk or serialize the full transcript.
    // State writes/swipes invalidate explicitly; tail identity handles appended turns.
    final tail = end == 0 ? null : c.messages[end - 1];
    final signature =
        '${c.messages.length}:${c.chatToolControls.length}:'
        '${tail?.swipeIndex}/${tail?.toolRun?.id}/${tail?.toolRun?.effects.length}';
    final cacheKey = '${c.id}:$end';
    final cached = _toolProjectionCache[cacheKey];
    if (cached?.signature == signature) return cached!.projection;
    final ordered = <ChatToolRun>[];
    final contextStale = <String>{};
    var prefixHash = 0x811c9dc5;
    for (var i = 0; i <= end; i++) {
      for (final control in c.chatToolControls) {
        if (control['at'] == i &&
            control['anchor'] == prefixHash.toRadixString(16) &&
            control['run'] is Map) {
          ordered.add(
            ChatToolRun.fromJson(
              Map<String, dynamic>.from(control['run'] as Map),
            ),
          );
        }
      }
      if (i < end && c.messages[i].toolRun != null) {
        final recorded = c.messages[i].toolRun!;
        if (recorded.contextAnchor.isNotEmpty &&
            recorded.contextAnchor != prefixHash.toRadixString(16)) {
          contextStale.add(recorded.id);
          ordered.add(recorded.copyWith(effects: const []));
        } else {
          ordered.add(recorded);
        }
      }
      if (i < end) prefixHash = _nextToolHash(prefixHash, c.messages[i]);
    }
    final folded = projectChatToolRuns(ordered);
    final projection = ChatToolProjection(
      values: folded.values,
      staleRuns: {...folded.staleRuns, ...contextStale},
    );
    if (_toolProjectionCache.length > 32) _toolProjectionCache.clear();
    _toolProjectionCache[cacheKey] = (
      signature: signature,
      projection: projection,
    );
    return projection;
  }

  List<ChatToolDefinition> _availableChatTools(
    Conversation c, {
    bool aside = false,
  }) {
    final cfg = chatToolConfigFor(c);
    return chatToolDefinitionsFor(c)
        .where(
          (d) =>
              d.enabled &&
              !cfg.disabledTools.contains(d.name) &&
              (aside ||
                  ![
                    'list_tools',
                    'save_tool',
                    'delete_tool',
                    'set_prompt_injection',
                  ].contains(d.name)) &&
              (d.name != 'generate_image' || _imageGen.isReady),
        )
        .toList();
  }

  Future<Object?> testChatTool(
    String name,
    Map<String, dynamic> arguments, {
    String? conversationId,
  }) async {
    final c = conversationId == null
        ? active
        : _conversationById(conversationId);
    if (c == null) throw StateError('Choose a chat to test this tool.');
    if (_streaming || !_chatToolWriting.add(c.id)) {
      throw StateError(
        'Wait for this chat to finish before testing an action.',
      );
    }
    final run = ChatToolRun(
      id: 'manual-${DateTime.now().microsecondsSinceEpoch}',
    );
    final effects = <ChatToolEffect>[];
    final images = <MessageImage>[];
    final values = Map<String, dynamic>.from(chatToolProjection(c).values);
    try {
      final definitions = _availableChatTools(c, aside: true);
      final out = await _executeChatTool(
        c,
        name,
        arguments,
        definitions,
        values,
        effects,
        images,
        () => false,
      );
      c.chatToolControls.add({
        'at': c.messages.length,
        'anchor': _toolAnchor(c, c.messages.length),
        'run': run
            .copyWith(effects: effects, images: images, status: 'completed')
            .toJson(),
      });
      await _saveChat(c);
      _notifyChatTools();
      return out;
    } finally {
      _chatToolWriting.remove(c.id);
    }
  }

  Future<Object?> _executeChatTool(
    Conversation c,
    String name,
    Map<String, dynamic> args,
    List<ChatToolDefinition> definitions,
    Map<String, dynamic> values,
    List<ChatToolEffect> effects,
    List<MessageImage> images,
    bool Function() cancelled, {
    int depth = 0,
    _ChatToolBudget? executionBudget,
  }) async {
    final before = depth == 0
        ? Map<String, dynamic>.from(jsonDecode(jsonEncode(values)) as Map)
        : null;
    final effectCount = effects.length;
    try {
      return await _executeChatToolBody(
        c,
        name,
        args,
        definitions,
        values,
        effects,
        images,
        cancelled,
        depth: depth,
        executionBudget: executionBudget,
      );
    } catch (_) {
      if (before != null) {
        values
          ..clear()
          ..addAll(before);
        effects.removeRange(effectCount, effects.length);
      }
      rethrow;
    }
  }

  Future<Object?> _executeChatToolBody(
    Conversation c,
    String name,
    Map<String, dynamic> args,
    List<ChatToolDefinition> definitions,
    Map<String, dynamic> values,
    List<ChatToolEffect> effects,
    List<MessageImage> images,
    bool Function() cancelled, {
    int depth = 0,
    _ChatToolBudget? executionBudget,
  }) async {
    final budget = executionBudget ?? _ChatToolBudget();
    if (--budget.remaining < 0) {
      throw StateError('Recipe operation limit reached.');
    }
    if (cancelled()) throw StateError('Cancelled.');
    if (depth > 16) throw StateError('Tool recipe call limit reached.');
    final matches = definitions.where((d) => d.name == name);
    if (matches.isEmpty) {
      throw FormatException('Tool $name is unavailable or disabled.');
    }
    final d = matches.first;
    final validationArgs = name == 'save_tool' && args['definition'] is Map
        ? {...args, 'definition': jsonEncode(args['definition'])}
        : args;
    validateChatToolArguments(d.parameters, validationArgs);
    if (!d.builtin) {
      return const ChatToolRuntime().execute(
        d.action,
        args,
        (op, input) => _executeChatTool(
          c,
          op,
          input,
          definitions,
          values,
          effects,
          images,
          cancelled,
          depth: depth + 1,
          executionBudget: budget,
        ),
        cancelled: cancelled,
      );
    }
    void write(String key, Object? after) {
      effects.add(ChatToolEffect(key: key, before: values[key], after: after));
      if (after == null) {
        values.remove(key);
      } else {
        values[key] = after;
      }
    }

    switch (name) {
      case 'roll_dice':
        return rollChatDice(args['formula'] as String);
      case 'random_integer':
        final lo = (args['min'] as num).toInt(),
            hi = (args['max'] as num).toInt();
        if (hi < lo || hi - lo > 1000000000) {
          throw const FormatException(
            'Use an ordered range no wider than one billion.',
          );
        }
        return {
          'min': lo,
          'max': hi,
          'value': lo + Random.secure().nextInt(hi - lo + 1),
        };
      case 'read_trackers':
        return {
          for (final entry in values.entries)
            if (entry.key.startsWith('tracker:'))
              entry.key.substring(8): entry.value,
        };
      case 'define_tracker':
        final id = (args['id'] as String).trim();
        if (id.isEmpty || id.length > 100) {
          throw const FormatException('Tracker id must be 1–100 characters.');
        }
        final next = <String, dynamic>{...args, 'id': id};
        _checkTracker(next);
        write('tracker:$id', next);
        return next;
      case 'update_tracker':
        final key = 'tracker:${args['id']}';
        if (values[key] is! Map) {
          throw const FormatException('Read or define this tracker first.');
        }
        if (args.containsKey('value') == args.containsKey('delta')) {
          throw const FormatException('Supply either value or delta.');
        }
        final next = Map<String, dynamic>.from(values[key] as Map);
        next['value'] =
            args['value'] ?? (next['value'] as num) + (args['delta'] as num);
        _checkTracker(next);
        write(key, next);
        return next;
      case 'set_prompt_injection':
        final text = (args['text'] as String).trim();
        if (text.isEmpty || text.length > 10000) {
          throw const FormatException(
            'Correction must contain 1–10000 characters.',
          );
        }
        final value = {
          'text': text,
          'depth': (args['depth'] as num).toInt().clamp(0, 1000),
          'lifetime': args['lifetime'] ?? 'next_reply',
        };
        write('injection:correction', value);
        return value;
      case 'generate_image':
        final imageClient = _chatToolImageClientFactory();
        _chatToolImageClients.add(imageClient);
        budget.imageClients.add(imageClient);
        late List<GalleryImage> pictures;
        try {
          pictures = await generateImages(
            prompt: args['prompt'] as String,
            conversationId: c.id,
            client: imageClient,
          );
        } finally {
          _chatToolImageClients.remove(imageClient);
          budget.imageClients.remove(imageClient);
          imageClient.cancel();
        }
        if (cancelled()) {
          throw StateError(
            'Image request interrupted. A completed remote image may remain in the gallery.',
          );
        }
        images.addAll(
          pictures.map(
            (p) => MessageImage(ref: p.image, mime: mimeForRef(p.image)),
          ),
        );
        return {
          'images': pictures.map((p) => {'id': p.id, 'ref': p.image}).toList(),
        };
      case 'list_tools':
        return chatToolDefinitionsFor(c).map((v) => v.toJson()).toList();
      case 'save_tool':
        final rawDefinition = args['definition'] is String
            ? jsonDecode(args['definition'] as String)
            : args['definition'];
        final tool = ChatToolDefinition.fromJson(
          Map<String, dynamic>.from(rawDefinition as Map),
        );
        _validateToolDefinition(tool);
        final scope = args['scope'] as String;
        final cfg = scope == 'global' ? _chatTools : chatToolConfigFor(c);
        await saveChatToolConfig(
          cfg.copyWith(
            customTools: [
              ...cfg.customTools.where((v) => v.name != tool.name),
              tool,
            ],
          ),
          conversationId: scope == 'global' ? null : c.id,
        );
        return {'saved': tool.name, 'scope': scope};
      case 'delete_tool':
        final scope = args['scope'] as String;
        final cfg = scope == 'global' ? _chatTools : chatToolConfigFor(c);
        await saveChatToolConfig(
          cfg.copyWith(
            customTools: cfg.customTools
                .where((v) => v.name != args['name'])
                .toList(),
          ),
          conversationId: scope == 'global' ? null : c.id,
        );
        return {'deleted': args['name'], 'scope': scope};
    }
    throw FormatException('Unknown operation $name.');
  }

  void _restoreToolEffects(
    Map<String, dynamic> values,
    List<ChatToolEffect> effects,
    Map<String, dynamic> snapshot,
    int count,
  ) {
    values
      ..clear()
      ..addAll(snapshot);
    if (effects.length > count) effects.removeRange(count, effects.length);
  }

  void _checkTracker(Map<String, dynamic> value) {
    final number = value['value'];
    final lo = value['min'], hi = value['max'];
    if (number is! num ||
        !number.isFinite ||
        (lo is num && number < lo) ||
        (hi is num && number > hi) ||
        (lo is num && hi is num && lo > hi)) {
      throw const FormatException(
        'Tracker value must be finite and inside its bounds.',
      );
    }
  }

  List<AgentMessage> _chatToolPayload(
    List<ChatMessage> source,
    Provider provider,
  ) {
    final out = <AgentMessage>[];
    for (final m in source) {
      final run = m.toolRun;
      if (run != null && run.history.isNotEmpty) {
        if (run.providerId == provider.id &&
            run.model == provider.model &&
            run.wire == provider.wire.name &&
            run.endpoint == _toolEndpoint(provider)) {
          final results = run.history
              .where((v) => v.role == AgentRole.tool)
              .map((v) => v.toolCallId)
              .toSet();
          out.addAll(run.history);
          for (final turn in run.history) {
            for (final call in turn.toolCalls) {
              if (!results.contains(call.id)) {
                out.add(
                  AgentMessage.toolResult(
                    call,
                    'Interrupted before a result was recorded. This operation will not be executed again.',
                    isError: true,
                  ),
                );
              }
            }
          }
        } else {
          out.add(
            AgentMessage.user(
              '[Recorded tool results from a previous model; read-only]\n${jsonEncode(run.history.map((v) => v.toJson()).toList())}',
            ),
          );
        }
      }
      final assistants =
          run?.history.where((v) => v.role == AgentRole.assistant).toList() ??
          [];
      final text = assistants.isNotEmpty && assistants.last.text == m.content
          ? ''
          : m.content;
      if (text.isNotEmpty || m.visibleImages.isNotEmpty) {
        out.add(
          AgentMessage(
            role: switch (m.role) {
              'system' => AgentRole.system,
              'assistant' => AgentRole.assistant,
              _ => AgentRole.user,
            },
            text: text,
            images: m.visibleImages,
          ),
        );
      }
    }
    return withWireImages(out);
  }

  Future<void> _generateWithTools(
    Conversation c, {
    int? swipeInto,
    int? continueAt,
    bool nudgeNewReply = false,
    Character? responder,
  }) async {
    final preset = presetFor(c);
    final base = _resolveProvider(preset, conversation: c);
    if (base == null) return;
    final blocked = blockingBudget(base, base.model);
    if (blocked != null) {
      _appendErrorTurn(c, AppState.describeBudgetBlock(blocked));
      return;
    }
    if (!_chatToolWriting.add(c.id)) {
      _appendErrorTurn(
        c,
        'Finish the side action before sending another reply.',
      );
      return;
    }
    final speaker = c.isGroup ? (responder ?? nextSpeaker(c)) : responder;
    ChatToolRun? continuedRun;
    final int target;
    if (continueAt != null) {
      // Continuing a tool-bearing variant creates a new alternative, preserving old effects.
      target = continueAt;
      final old = c.messages[target].active;
      continuedRun = old.toolRun;
      c.messages[target] = c.messages[target].addSwipe(
        old.copyWith(clearToolRun: true),
      );
    } else if (swipeInto != null) {
      target = swipeInto;
      c.messages[target] = c.messages[target].addSwipe(
        const MessageVariant(content: ''),
      );
    } else {
      c.messages.add(
        ChatMessage(
          role: 'assistant',
          speakerId: c.isGroup ? speaker?.id : null,
          speakerName: c.isGroup ? speaker?.displayName : null,
        ),
      );
      target = c.messages.length - 1;
    }
    _streaming = true;
    _stopRequested = false;
    _moveToTop(c);
    final cfg = chatToolConfigFor(c);
    final definitions = cfg.enabled
        ? _availableChatTools(c)
        : <ChatToolDefinition>[];
    final effects = <ChatToolEffect>[...?continuedRun?.effects];
    final images = <MessageImage>[...?continuedRun?.images];
    final history = <AgentMessage>[
      if (continuedRun != null &&
          continuedRun.endpoint == _toolEndpoint(base) &&
          continuedRun.model == base.model &&
          continuedRun.wire == base.wire.name)
        ...continuedRun.history,
    ];
    final values = Map<String, dynamic>.from(
      chatToolProjection(c, historyEnd: target).values,
    );
    if (continuedRun != null) {
      final projected = projectChatToolRuns([continuedRun], base: values);
      values
        ..clear()
        ..addAll(projected.values);
    }
    final startingInjections = {
      for (final v in values.entries)
        if (v.key.startsWith('injection:')) v.key: v.value,
    };
    var run = ChatToolRun(
      id: 'chat-${DateTime.now().microsecondsSinceEpoch}',
      providerId: base.id,
      model: base.model,
      wire: base.wire.name,
      endpoint: _toolEndpoint(base),
      contextAnchor: _toolAnchor(c, target),
    );
    var answer = continueAt == null ? '' : c.messages[target].content;
    final continuationPrefix = answer;
    final initialHistoryCount = history.length;
    final initialEffectCount = effects.length;
    final initialImageCount = images.length;
    var thinking = '';
    final client = AgentClient();
    _chatToolClient = client;
    var runCancelled = false;
    _ChatToolBudget? activeBudget;
    void cancelRun() {
      runCancelled = true;
      client.cancel();
      activeBudget?.cancelImages();
    }

    _cancelChatToolRun = cancelRun;
    bool cancelled() => runCancelled;
    void publish(String status, {bool notify = true}) {
      final previous = c.messages[target].toolRun;
      final projectionChanged =
          previous?.id != run.id || previous?.effects.length != effects.length;
      run = run.copyWith(
        history: List.of(history),
        effects: List.of(effects),
        images: List.of(images),
        status: status,
      );
      c.messages[target] = c.messages[target].copyWith(
        content: answer,
        reasoning: thinking,
        toolRun: run,
      );
      if (notify) _notifyChatTools(stateChanged: projectionChanged);
    }

    publish('running');
    try {
      await _letTheFrameLand();
      await _refreshMemory(c);
      if (cancelled()) {
        publish('cancelled');
        return;
      }
      final assembled = _assemble(
        c,
        historyEnd: target,
        responder: speaker,
        commitMacroEffects: true,
      );
      final source = List<ChatMessage>.of(
        _wirePayload(
          assembled.messages,
          nudge: nudgeNewReply ? _newReplyNudge(c, speaker: speaker) : null,
          continuation: continueAt == null ? null : answer,
        ),
      );
      final messages = _chatToolPayload(source, base);
      if (history.isNotEmpty) {
        messages.insertAll(max(1, messages.length - 1), history);
      }
      final raw = StringBuffer();
      final tags = ReasoningTags(
        start: preset?.thinkStartTag.trim() ?? '',
        end: preset?.thinkEndTag.trim() ?? '',
      );
      var callsUsed = 0;
      for (var round = 0; round < cfg.maxRounds; round++) {
        if (cancelled()) break;
        final budget = blockingBudget(base, base.model);
        if (budget != null) {
          throw ChatApiException(AppState.describeBudgetBlock(budget));
        }
        final provider = _applyKey(base);
        final offered = definitions.map((v) => v.spec).toList();
        final params = AgentParams(
          stream: assembled.params.stream,
          generation: assembled.params,
          requireToolCompletion: true,
          toolsOff: round == cfg.maxRounds - 1,
        );
        var bodyCost = _toolRequestCost(provider, messages, offered, params);
        while (bodyCost + (assembled.params.maxTokens ?? 1024) >
            assembled.maxContext) {
          var removable = -1;
          for (var index = 1; index < source.length - 1; index++) {
            if (!source[index].promptProtected) {
              removable = index;
              break;
            }
          }
          if (removable < 0) break;
          source.removeAt(removable);
          final rebuilt = _chatToolPayload(source, base);
          if (initialHistoryCount > 0) {
            rebuilt.insertAll(
              max(1, rebuilt.length - 1),
              history.take(initialHistoryCount),
            );
          }
          rebuilt.addAll(history.skip(initialHistoryCount));
          messages
            ..clear()
            ..addAll(rebuilt);
          bodyCost = _toolRequestCost(provider, messages, offered, params);
        }
        if (bodyCost + (assembled.params.maxTokens ?? 1024) >
            assembled.maxContext) {
          throw ChatApiException(
            'The tool exchange does not fit this model’s context. Reduce the prompt or tool selection.',
          );
        }
        final calls = <ToolCall>[];
        raw.clear();
        final snapshots = _chatToolRequests.putIfAbsent(run.id, () => []);
        snapshots.add(
          AgentWireRequest(
            provider: provider,
            messages: messages,
            tools: offered,
            params: params,
          ).preview(),
        );
        if (_chatToolRequests.length > 8) {
          _chatToolRequests.remove(_chatToolRequests.keys.first);
        }
        final metadata = <String, dynamic>{};
        final roundText = StringBuffer();
        TokenUsage? reported;
        final clock = Stopwatch()..start();
        var lastPaint = -AppState._streamPaintMs;
        try {
          await for (final delta in client.stream(
            provider: provider,
            messages: messages,
            tools: offered,
            params: params,
          )) {
            if (delta.usage != null) {
              reported = AppState._mergeUsage(reported, delta.usage!);
            }
            roundText.write(delta.text);
            raw.write(delta.text);
            thinking += delta.reasoning;
            calls.addAll(delta.toolCalls);
            metadata.addAll(delta.providerData);
            if (clock.elapsedMilliseconds - lastPaint >=
                AppState._streamPaintMs) {
              lastPaint = clock.elapsedMilliseconds;
              answer =
                  continuationPrefix +
                  splitReasoning(raw.toString(), tags).text;
              publish('running');
            }
          }
        } finally {
          recordUsage(
            base,
            base.model,
            reported ??
                TokenUsage(
                  inputTokens: bodyCost,
                  outputTokens: _tokenizer.estimate(roundText.toString()),
                  estimated: true,
                ),
          );
          await _persistUsage();
        }
        if (cancelled()) break;
        answer = continuationPrefix + splitReasoning(raw.toString(), tags).text;
        _deduplicateChatCalls(calls);
        if (calls.isEmpty) {
          if (answer.trim().isEmpty && history.isEmpty) {
            throw ChatApiException('The model returned an empty response.');
          }
          for (final injection in startingInjections.entries) {
            if (injection.value is Map &&
                (injection.value as Map)['lifetime'] == 'next_reply' &&
                values[injection.key] == injection.value) {
              effects.add(
                ChatToolEffect(key: injection.key, before: injection.value),
              );
            }
          }
          publish('completed');
          break;
        }
        final assistant = AgentMessage(
          role: AgentRole.assistant,
          text: roundText.toString(),
          reasoning: thinking,
          toolCalls: calls,
          providerData: metadata,
        );
        history.add(assistant);
        messages.add(assistant);
        publish('running');
        await _saveChat(c);
        var followUp = true;
        for (final call in calls) {
          String text;
          var failed = false;
          final effectCount = effects.length;
          final valueSnapshot = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(values)) as Map,
          );
          try {
            if (++callsUsed > cfg.maxCalls) {
              throw StateError('Tool call limit reached.');
            }
            if (cancelled()) throw StateError('Cancelled.');
            if (round == cfg.maxRounds - 1) {
              throw StateError('Tool round limit reached.');
            }
            if (call.argumentError != null) {
              throw FormatException(call.argumentError!);
            }
            final result =
                await _executeChatTool(
                  c,
                  call.name,
                  call.arguments,
                  definitions,
                  values,
                  effects,
                  images,
                  cancelled,
                  executionBudget: activeBudget = _ChatToolBudget(),
                ).timeout(
                  const Duration(minutes: 4),
                  onTimeout: () {
                    cancelRun();
                    throw TimeoutException(
                      'Tool deadline reached. Remote work was not automatically retried.',
                    );
                  },
                );
            text = result is String ? result : jsonEncode(result);
            final definition = definitions
                .where((v) => v.name == call.name)
                .first;
            followUp = followUp && definition.followUp;
          } catch (e) {
            _restoreToolEffects(values, effects, valueSnapshot, effectCount);
            text = '$e';
            failed = true;
          }
          final result = AgentMessage.toolResult(call, text, isError: failed);
          history.add(result);
          messages.add(result);
          publish(cancelled() ? 'cancelled' : 'running', notify: false);
          try {
            await _saveChat(c);
          } catch (error) {
            _restoreToolEffects(values, effects, valueSnapshot, effectCount);
            final failure = AgentMessage.toolResult(
              call,
              'This action was not saved: $error',
              isError: true,
            );
            history[history.length - 1] = failure;
            messages[messages.length - 1] = failure;
            publish('failed');
            rethrow;
          }
          _notifyChatTools();
        }
        if (!followUp || cancelled()) {
          publish(cancelled() ? 'cancelled' : 'completed');
          break;
        }
        if (round == cfg.maxRounds - 1) publish('limited');
      }
      if (cancelled()) publish('cancelled');
      answer = applyRegexToOutput(
        answer,
        target: RegexTarget.aiOutput,
        conversation: c,
      );
      c.messages[target] = c.messages[target].copyWith(content: answer);
    } catch (e) {
      publish(cancelled() ? 'cancelled' : 'failed');
      if (!cancelled()) {
        c.messages[target] = c.messages[target].copyWith(
          content: answer.isEmpty ? '$e' : '$answer\n\n$e',
          error: history.isEmpty,
        );
      }
    } finally {
      if (cancelled() &&
          answer == continuationPrefix &&
          thinking.isEmpty &&
          history.length == initialHistoryCount &&
          effects.length == initialEffectCount &&
          images.length == initialImageCount) {
        final message = c.messages[target];
        if (message.swipeCount > 1) {
          c.messages[target] = message.removeSwipe(message.swipeIndex);
        } else if (answer.isEmpty) {
          c.messages.removeAt(target);
        }
      }
      _chatToolClient = null;
      _cancelChatToolRun = null;
      runCancelled = true;
      _chatToolWriting.remove(c.id);
      _streaming = false;
      _stopRequested = false;
      c.updatedAt = DateTime.now();
      _notifyChatTools();
      await _saveChat(c);
    }
    unawaited(maybeSummarize(c));
    unawaited(_indexChat(c));
  }

  Future<String> _askAsideWithTools(
    String question,
    Conversation c, {
    List<ChatMessage> sideHistory = const [],
    BtwRun? run,
    void Function(String)? onProgress,
  }) async {
    final preset = presetFor(c);
    final base = _resolveProvider(preset, conversation: c);
    if (base == null) {
      throw ChatApiException('Set up a provider in Settings first.');
    }
    final canWrite = !_streaming && _chatToolWriting.add(c.id);
    var stopped = run?.cancelled ?? false;
    _ChatToolBudget? activeBudget;
    final client = AgentClient();
    run?.onCancel(() {
      stopped = true;
      client.cancel();
      if (canWrite) {
        activeBudget?.cancelImages();
      }
    });
    final end = _streaming && c.messages.isNotEmpty
        ? c.messages.length - 1
        : c.messages.length;
    final anchor = _toolAnchor(c, end);
    final effects = <ChatToolEffect>[];
    final images = <MessageImage>[];
    final values = Map<String, dynamic>.from(
      chatToolProjection(c, historyEnd: end).values,
    );
    final asideRun = ChatToolRun(
      id: 'aside-${DateTime.now().microsecondsSinceEpoch}',
    );
    int? controlIndex;
    var answer = '';
    var callsUsed = 0;
    try {
      final localVariables = Map<String, String>.of(c.variables);
      final globalVariables = Map<String, String>.of(_globalVars);
      late AssembledPrompt assembled;
      try {
        assembled = _assemble(c, historyEnd: end);
      } finally {
        c.variables
          ..clear()
          ..addAll(localVariables);
        _globalVars
          ..clear()
          ..addAll(globalVariables);
      }
      final source = List<ChatMessage>.of(assembled.messages);
      final prior = _chatToolPayload(btwHistory(sideHistory), base);
      final messages = _chatToolPayload(source, base)
        ..addAll(prior)
        ..add(
          AgentMessage.user(
            '${chatBtwInstruction(question)}\n\n'
            'You may use tools for requested changes, outside the story. '
            'Only save tools in the scope the user requests; use chat scope if unspecified. '
            'Custom tools use Recipe JSON: {"steps":[{"id":"result","call":"roll_dice",'
            '"arguments":{"formula":{"ref":"args.formula"}}},{"return":{"ref":"vars.result"}}]}. '
            'Use set_prompt_injection for OOC corrections, choosing depth in ordinary RP messages '
            'and lifetime next_reply or persistent. '
            '${canWrite ? '' : 'A reply/action is in progress; only read-only tools are available.'}',
          ),
        );
      final cfg = chatToolConfigFor(c);
      final questionMessage = messages.last;
      final toolHistory = <AgentMessage>[];
      final knownDefinitions = <String, ChatToolDefinition>{};
      for (var round = 0; round < cfg.maxRounds && !stopped; round++) {
        for (final d in _availableChatTools(c, aside: true)) {
          if (canWrite ||
              [
                'read_trackers',
                'list_tools',
                'roll_dice',
                'random_integer',
              ].contains(d.name)) {
            knownDefinitions[d.name] = d;
          }
        }
        final definitions = knownDefinitions.values.toList();
        final offered = definitions.map((v) => v.spec).toList();
        final budget = blockingBudget(base, base.model);
        if (budget != null) {
          throw ChatApiException(AppState.describeBudgetBlock(budget));
        }
        final provider = _applyKey(base);
        final params = AgentParams(
          stream: assembled.params.stream,
          generation: assembled.params,
          requireToolCompletion: true,
          toolsOff: round == cfg.maxRounds - 1,
        );
        var cost = _toolRequestCost(provider, messages, offered, params);
        while (cost + (assembled.params.maxTokens ?? 1024) >
            assembled.maxContext) {
          var removable = -1;
          for (var index = 1; index < source.length - 1; index++) {
            if (!source[index].promptProtected) {
              removable = index;
              break;
            }
          }
          if (removable < 0) break;
          source.removeAt(removable);
          messages
            ..clear()
            ..addAll(_chatToolPayload(source, base))
            ..addAll(prior)
            ..add(questionMessage)
            ..addAll(toolHistory);
          cost = _toolRequestCost(provider, messages, offered, params);
        }
        if (cost + (assembled.params.maxTokens ?? 1024) >
            assembled.maxContext) {
          throw ChatApiException(
            'The side question and tools exceed this model’s context.',
          );
        }
        final raw = StringBuffer();
        final thoughts = StringBuffer();
        final calls = <ToolCall>[];
        final metadata = <String, dynamic>{};
        TokenUsage? usage;
        try {
          await for (final delta in client.stream(
            provider: provider,
            messages: messages,
            tools: offered,
            params: params,
          )) {
            raw.write(delta.text);
            thoughts.write(delta.reasoning);
            calls.addAll(delta.toolCalls);
            metadata.addAll(delta.providerData);
            if (delta.usage != null) {
              usage = AppState._mergeUsage(usage, delta.usage!);
            }
            answer = splitReasoning(
              raw.toString(),
              ReasoningTags(
                start: preset?.thinkStartTag.trim() ?? '',
                end: preset?.thinkEndTag.trim() ?? '',
              ),
            ).text;
            onProgress?.call(answer);
          }
        } on ChatApiException {
          if (!stopped) rethrow;
        } finally {
          recordUsage(
            base,
            base.model,
            usage ??
                TokenUsage(
                  inputTokens: cost,
                  outputTokens: _tokenizer.estimate(raw.toString()),
                  estimated: true,
                ),
          );
          await _persistUsage();
        }
        if (stopped || calls.isEmpty) break;
        _deduplicateChatCalls(calls);
        final assistant = AgentMessage(
          role: AgentRole.assistant,
          text: raw.toString(),
          reasoning: thoughts.toString(),
          toolCalls: calls,
          providerData: metadata,
        );
        messages.add(assistant);
        toolHistory.add(assistant);
        for (final call in calls) {
          String text;
          var failed = false;
          final beforeEffects = effects.length;
          final valueSnapshot = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(values)) as Map,
          );
          try {
            if (++callsUsed > cfg.maxCalls || round == cfg.maxRounds - 1) {
              throw StateError('Side tool limit reached.');
            }
            if (stopped) throw StateError('Cancelled.');
            if (_toolAnchor(c, end) != anchor) {
              throw StateError(
                'The roleplay changed. Ask again with the current context.',
              );
            }
            if (call.argumentError != null) {
              throw FormatException(call.argumentError!);
            }
            final result =
                await _executeChatTool(
                  c,
                  call.name,
                  call.arguments,
                  definitions,
                  values,
                  effects,
                  images,
                  () => stopped,
                  executionBudget: activeBudget = _ChatToolBudget(),
                ).timeout(
                  const Duration(minutes: 4),
                  onTimeout: () {
                    stopped = true;
                    client.cancel();
                    if (canWrite) {
                      activeBudget?.cancelImages();
                    }
                    throw TimeoutException(
                      'Side tool deadline reached. Remote work was not automatically retried.',
                    );
                  },
                );
            if (canWrite && effects.length > beforeEffects) {
              final control = {
                'at': end,
                'anchor': anchor,
                'run': asideRun
                    .copyWith(effects: List.of(effects), status: 'completed')
                    .toJson(),
              };
              final previous = controlIndex == null
                  ? null
                  : c.chatToolControls[controlIndex];
              if (controlIndex == null) {
                controlIndex = c.chatToolControls.length;
                c.chatToolControls.add(control);
              } else {
                c.chatToolControls[controlIndex] = control;
              }
              try {
                await _saveChat(c);
              } catch (_) {
                if (previous == null) {
                  c.chatToolControls.removeAt(controlIndex);
                  controlIndex = null;
                } else {
                  c.chatToolControls[controlIndex] = previous;
                }
                rethrow;
              }
              _notifyChatTools();
            }
            text = result is String ? result : jsonEncode(result);
          } catch (e) {
            _restoreToolEffects(values, effects, valueSnapshot, beforeEffects);
            text = '$e';
            failed = true;
          }
          final resultMessage = AgentMessage.toolResult(
            call,
            text,
            isError: failed,
          );
          messages.add(resultMessage);
          toolHistory.add(resultMessage);
        }
      }
      return answer;
    } finally {
      client.cancel();
      stopped = true;
      if (canWrite) _chatToolWriting.remove(c.id);
      _notifyChatTools();
    }
  }
}
