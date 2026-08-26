import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/budget.dart';
import 'package:maichat/models/model_pricing.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';

void main() {
  group('wire formats', () {
    test('every kind names a dialect the client can speak', () {
      for (final kind in ProviderKind.values) {
        expect(WireFormat.values, contains(kind.wire));
      }
    });

    test('the local kinds share the OpenAI chat dialect', () {
      expect(ProviderKind.localLlm.wire, WireFormat.openaiChat);
      expect(ProviderKind.koboldCpp.wire, WireFormat.openaiChat);
    });

    test('the local kinds default to http, not https', () {
      for (final kind in ProviderKind.values.where((k) => k.prefersHttp)) {
        expect(kind.defaultBaseUrl, startsWith('http://'));
      }
    });

    test('a key is optional exactly where the host is local', () {
      expect(ProviderKind.localLlm.requiresKey, isFalse);
      expect(ProviderKind.koboldCpp.requiresKey, isFalse);
      expect(ProviderKind.openai.requiresKey, isTrue);
      expect(ProviderKind.anthropic.requiresKey, isTrue);
    });

    test('usage is only asked of hosts that reliably report it', () {
      expect(ProviderKind.localLlm.usageReporting, isFalse);
      expect(ProviderKind.koboldCpp.usageReporting, isFalse);
      expect(ProviderKind.openai.usageReporting, isTrue);
    });

    test('every kind has helper text and a model hint', () {
      for (final kind in ProviderKind.values) {
        expect(kind.baseUrlHelper, isNotEmpty, reason: kind.name);
        expect(kind.modelHint, isNotEmpty, reason: kind.name);
      }
    });

    test('an unknown stored kind falls back to the commonest format', () {
      expect(ProviderKind.byName('nonsense'), ProviderKind.openai);
      expect(ProviderKind.byName(null), ProviderKind.openai);
    });
  });

  group('storing the new provider fields', () {
    test('an untouched provider writes none of them', () {
      final json = Provider.create(ProviderKind.openai).toJson();
      expect(json.containsKey('prices'), isFalse);
      expect(json.containsKey('fallbackModels'), isFalse);
      expect(json.containsKey('customHeaders'), isFalse);
      expect(json.containsKey('claudeCodeHeaders'), isFalse);
      expect(json.containsKey('budgets'), isFalse);
    });

    test('a provider stored before any of this existed still loads', () {
      final provider = Provider.fromJson(<String, dynamic>{
        'id': '1',
        'name': 'Old',
        'kind': 'openai',
        'baseUrl': 'https://api.openai.com/v1',
        'apiKey': 'sk-old',
        'model': 'gpt-4o-mini',
      });
      expect(provider.prices, isEmpty);
      expect(provider.fallbackModels, isEmpty);
      expect(provider.customHeaders, isEmpty);
      expect(provider.claudeCodeHeaders, isFalse);
      expect(provider.budgets, isEmpty);
      expect(provider.apiKey, 'sk-old');
    });

    test('a full round trip keeps everything', () {
      final original = Provider(
        id: '7',
        name: 'Everything',
        kind: ProviderKind.openaiResponses,
        baseUrl: 'https://example.test/v1',
        model: 'gpt-5',
        apiKeys: const <String>['a', 'b'],
        keyStrategy: KeyRotationStrategy.errorBased,
        prices: const <ModelPrice>[
          ModelPrice(model: 'gpt-5', input: 1.25, output: 10),
        ],
        fallbackModels: const <String>['gpt-4o', 'gpt-4o-mini'],
        customHeaders: const <String, String>{'x-team': 'blue'},
        claudeCodeHeaders: true,
        budgets: const <Budget>[
          Budget(id: 'b1', limit: 20, block: true),
        ],
      );
      final restored = Provider.fromJson(original.toJson());
      expect(restored.kind, ProviderKind.openaiResponses);
      expect(restored.apiKeys, <String>['a', 'b']);
      expect(restored.keyStrategy, KeyRotationStrategy.errorBased);
      expect(restored.prices.single.output, 10);
      expect(restored.fallbackModels, <String>['gpt-4o', 'gpt-4o-mini']);
      expect(restored.customHeaders, <String, String>{'x-team': 'blue'});
      expect(restored.claudeCodeHeaders, isTrue);
      expect(restored.budgets.single.block, isTrue);
    });
  });

  group('endpoints', () {
    Provider of(ProviderKind kind, String url) => Provider(
          id: 'p',
          name: 'p',
          kind: kind,
          baseUrl: url,
          model: 'm',
        );

    test('a scheme-less hosted address is upgraded to https', () {
      expect(
        ChatClient.requestUri(of(ProviderKind.openai, 'api.openai.com/v1'))
            .scheme,
        'https',
      );
    });

    test('a scheme-less local address stays on http', () {
      // `localhost:11434` plainly means http; upgrading it produced a TLS error
      // against a server that speaks none.
      for (final kind in <ProviderKind>[
        ProviderKind.localLlm,
        ProviderKind.koboldCpp,
      ]) {
        expect(
          ChatClient.requestUri(of(kind, '127.0.0.1:11434/v1')).scheme,
          'http',
          reason: kind.name,
        );
      }
    });

    test('an explicit scheme is always honoured', () {
      expect(
        ChatClient.requestUri(of(ProviderKind.localLlm, 'https://lan.test/v1'))
            .scheme,
        'https',
      );
      expect(
        ChatClient.requestUri(of(ProviderKind.openai, 'http://127.0.0.1/v1'))
            .scheme,
        'http',
      );
    });

    test('each dialect posts to its own path', () {
      expect(
        ChatClient.requestUri(of(ProviderKind.openai, 'https://h.test/v1')).path,
        '/v1/chat/completions',
      );
      expect(
        ChatClient.requestUri(of(ProviderKind.openaiResponses, 'https://h.test/v1'))
            .path,
        '/v1/responses',
      );
      expect(
        ChatClient.requestUri(of(ProviderKind.anthropic, 'https://h.test/v1')).path,
        '/v1/messages',
      );
      expect(
        ChatClient.requestUri(of(ProviderKind.gemini, 'https://h.test/v1beta')).path,
        '/v1beta/models/m:streamGenerateContent',
      );
    });
  });
}
