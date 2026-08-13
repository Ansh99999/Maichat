import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';

/// The inspector's "copy raw request" must be the literal payload, built by the
/// same code that sends it, with credentials never placed on the clipboard.
void main() {
  final history = [
    ChatMessage(role: 'system', content: 'DEFINITION_TOKEN the sheet.'),
    ChatMessage(role: 'user', content: 'hello'),
  ];

  Provider provider(ProviderKind kind) => Provider(
        id: 'p',
        name: 'p',
        kind: kind,
        baseUrl: 'https://example.com/v1',
        model: 'some-model',
        apiKey: 'sk-secret-value',
      );

  test('the preview carries the endpoint, headers and the real body', () {
    final preview =
        ChatClient().requestPreview(provider(ProviderKind.openai), history);

    expect(preview, contains('POST https://example.com/v1/chat/completions'));
    expect(preview, contains('DEFINITION_TOKEN'));
    // The body is the actual JSON that would be posted.
    final body = jsonDecode(preview.substring(preview.indexOf('{')))
        as Map<String, dynamic>;
    expect(body['model'], 'some-model');
    expect((body['messages'] as List).length, 2);
    expect((body['messages'] as List).first, {
      'role': 'system',
      'content': 'DEFINITION_TOKEN the sheet.',
    });
  });

  test('the API key is never copied', () {
    for (final kind in ProviderKind.values) {
      final preview = ChatClient().requestPreview(provider(kind), history);
      expect(preview, isNot(contains('sk-secret-value')),
          reason: '$kind must redact its credential');
      expect(preview, contains('<redacted>'));
    }
  });

  test('each provider format previews its own endpoint and shape', () {
    final gemini =
        ChatClient().requestPreview(provider(ProviderKind.gemini), history);
    expect(gemini, contains(':streamGenerateContent'));
    expect(gemini, contains('systemInstruction'));

    final anthropic =
        ChatClient().requestPreview(provider(ProviderKind.anthropic), history);
    expect(anthropic, contains('https://example.com/v1/messages'));
    // Anthropic carries the system prompt out of band; it must still be visible.
    expect(anthropic, contains('DEFINITION_TOKEN'));
  });
}
