import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/chat_client.dart';

/// Regression test for the "adding any file fails: check base URL, usually ends
/// in /v1" bug. A user commonly pastes the full chat endpoint as the base URL;
/// chat works (ChatClient.endpoint detects the suffix) but naively appending
/// /embeddings produced .../chat/completions/embeddings → 404.
void main() {
  group('embeddingsUri', () {
    test('appends /embeddings to a plain /v1 base', () {
      expect(
        ChatClient.embeddingsUri('https://api.openai.com/v1').toString(),
        'https://api.openai.com/v1/embeddings',
      );
    });

    test('strips a trailing /chat/completions before appending', () {
      expect(
        ChatClient.embeddingsUri('https://host/v1/chat/completions').toString(),
        'https://host/v1/embeddings',
      );
    });

    test('tolerates a trailing slash', () {
      expect(
        ChatClient.embeddingsUri('https://host/v1/').toString(),
        'https://host/v1/embeddings',
      );
    });

    test('strips a trailing /messages (Anthropic-style paste)', () {
      expect(
        ChatClient.embeddingsUri('https://host/v1/messages').toString(),
        'https://host/v1/embeddings',
      );
    });

    test('adds https when the scheme is missing', () {
      expect(
        ChatClient.embeddingsUri('host/v1').toString(),
        'https://host/v1/embeddings',
      );
    });
  });
}
