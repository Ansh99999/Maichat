import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/chat_client.dart';

void main() {
  group('ChatClient.endpoint', () {
    test('appends the path to a plain base URL', () {
      expect(
        ChatClient.endpoint('https://api.openai.com/v1', '/chat/completions')
            .toString(),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('tolerates trailing slashes', () {
      expect(
        ChatClient.endpoint('https://api.openai.com/v1//', '/models')
            .toString(),
        'https://api.openai.com/v1/models',
      );
    });

    test('does not double up when the base already names the endpoint', () {
      expect(
        ChatClient.endpoint(
          'https://host.tld/v1/chat/completions',
          '/chat/completions',
        ).toString(),
        'https://host.tld/v1/chat/completions',
      );
    });

    test('assumes https when no scheme is given', () {
      expect(
        ChatClient.endpoint('host.tld/v1', '/models').toString(),
        'https://host.tld/v1/models',
      );
    });

    test('keeps an explicit http scheme for local hosts', () {
      expect(
        ChatClient.endpoint('http://127.0.0.1:1234/v1', '/models').toString(),
        'http://127.0.0.1:1234/v1/models',
      );
    });

    test('rejects an empty base URL with an actionable message', () {
      expect(
        () => ChatClient.endpoint('   ', '/models'),
        throwsA(
          isA<ChatApiException>().having(
            (e) => e.message,
            'message',
            contains('base URL'),
          ),
        ),
      );
    });
  });
}
