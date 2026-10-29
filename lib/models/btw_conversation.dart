/// A durable side conversation, kept separately from the roleplay transcript.
class BtwConversation {
  BtwConversation({
    required this.id,
    required this.conversationId,
    this.title = '',
    List<BtwExchange>? exchanges,
    this.systemPrompt = '',
    this.providerId,
    this.toolsEnabled,
    this.titleGenerated = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : exchanges = exchanges ?? <BtwExchange>[],
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now();

  final String id;
  final String conversationId;
  String title;
  final List<BtwExchange> exchanges;
  String systemPrompt;
  String? providerId;
  bool? toolsEnabled;
  bool titleGenerated;
  final DateTime createdAt;
  DateTime updatedAt;

  static String firstLineTitle(String question) {
    for (final line in question.split('\n')) {
      final text = line.trim();
      if (text.isEmpty) continue;
      return text.length > 80 ? '${text.substring(0, 77)}…' : text;
    }
    return 'Side conversation';
  }

  String get displayTitle => title.trim().isNotEmpty
      ? title.trim()
      : firstLineTitle(exchanges.isEmpty ? '' : exchanges.first.question);

  Map<String, dynamic> toJson() => {
    'id': id,
    'conversationId': conversationId,
    'title': title,
    'exchanges': [for (final exchange in exchanges) exchange.toJson()],
    if (systemPrompt.isNotEmpty) 'systemPrompt': systemPrompt,
    if (providerId != null) 'providerId': providerId,
    if (toolsEnabled != null) 'toolsEnabled': toolsEnabled,
    if (titleGenerated) 'titleGenerated': true,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  static BtwConversation? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final conversationId = json['conversationId'];
    if (id is! String ||
        id.isEmpty ||
        conversationId is! String ||
        conversationId.isEmpty) {
      return null;
    }
    return BtwConversation(
      id: id,
      conversationId: conversationId,
      title: json['title'] is String ? json['title'] as String : '',
      exchanges: [
        if (json['exchanges'] is List)
          for (final value in json['exchanges'] as List)
            ?BtwExchange.fromJson(value),
      ],
      systemPrompt: json['systemPrompt'] is String
          ? json['systemPrompt'] as String
          : '',
      providerId: json['providerId'] is String
          ? json['providerId'] as String
          : null,
      toolsEnabled: json['toolsEnabled'] is bool
          ? json['toolsEnabled'] as bool
          : null,
      titleGenerated: json['titleGenerated'] == true,
      createdAt: DateTime.tryParse('${json['createdAt']}'),
      updatedAt: DateTime.tryParse('${json['updatedAt']}'),
    );
  }
}

class BtwExchange {
  BtwExchange(
    this.question, {
    this.answer = '',
    this.error,
    this.done = false,
    this.stopped = false,
  });

  final String question;
  String answer;
  String? error;
  bool done;
  bool stopped;

  Map<String, dynamic> toJson() => {
    'question': question,
    'answer': answer,
    if (error != null) 'error': error,
    'done': done,
    'stopped': stopped,
  };

  static BtwExchange? fromJson(Object? json) {
    if (json is! Map || json['question'] is! String) return null;
    // A process cannot resume a former HTTP stream. Preserve its partial text
    // and present it as stopped instead of leaving a permanent spinner.
    final interrupted = json['done'] != true;
    return BtwExchange(
      json['question'] as String,
      answer: json['answer'] is String ? json['answer'] as String : '',
      error: json['error'] is String ? json['error'] as String : null,
      done: true,
      stopped: interrupted || json['stopped'] == true,
    );
  }
}
