import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/budget.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/providers/providers_io.dart';

/// Import and export of providers. The rule that matters: keys do not leave the
/// device unless the user said so.
void main() {
  Provider withKeys() => Provider(
        id: 'p1',
        name: 'Mine',
        kind: ProviderKind.anthropic,
        baseUrl: 'https://api.anthropic.com/v1',
        model: 'claude-sonnet-4-5',
        apiKeys: const <String>['sk-secret-one', 'sk-secret-two'],
        budgets: const <Budget>[Budget(id: 'b', limit: 10)],
      );

  group('export', () {
    test('keys are absent unless asked for', () {
      final json = encodeProviders(<Provider>[withKeys()]);
      expect(json, isNot(contains('sk-secret-one')));
      expect(json, isNot(contains('sk-secret-two')));
      // Everything else still travels.
      expect(json, contains('claude-sonnet-4-5'));
      expect(json, contains('api.anthropic.com'));
    });

    test('keys are included when explicitly asked for', () {
      final json = encodeProviders(<Provider>[withKeys()], includeKeys: true);
      expect(json, contains('sk-secret-one'));
      expect(json, contains('sk-secret-two'));
    });

    test('one provider exports as an object, several as an envelope', () {
      final single = decodeProviders(encodeProviders(<Provider>[withKeys()]));
      expect(single.length, 1);

      final many = encodeProviders(<Provider>[
        withKeys(),
        Provider.create(ProviderKind.openai),
      ]);
      expect(many, contains('"providers"'));
      expect(decodeProviders(many).length, 2);
    });
  });

  group('import', () {
    test('a fresh id is issued so a re-import does not collide', () {
      final original = withKeys();
      final imported =
          decodeProviders(encodeProviders(<Provider>[original])).single;
      expect(imported.id, isNot(original.id));
      expect(imported.displayName, original.displayName);
      expect(imported.kind, original.kind);
      expect(imported.model, original.model);
    });

    test('several providers in one file each get their own id', () {
      final json = encodeProviders(<Provider>[
        withKeys(),
        Provider.create(ProviderKind.gemini),
        Provider.create(ProviderKind.openai),
      ]);
      final imported = decodeProviders(json);
      expect(imported.map((p) => p.id).toSet().length, 3);
    });

    test('a bare list of providers is accepted too', () {
      final imported = decodeProviders(
        '[{"name":"A","kind":"openai","baseUrl":"https://a.test/v1"}]',
      );
      expect(imported.single.displayName, 'A');
    });

    test('prices, budgets and headers survive the trip', () {
      final json = encodeProviders(<Provider>[
        withKeys().copyWith(
          customHeaders: const <String, String>{'x-team': 'blue'},
          claudeCodeHeaders: true,
          fallbackModels: const <String>['claude-haiku-4-5'],
        ),
      ]);
      final imported = decodeProviders(json).single;
      expect(imported.customHeaders['x-team'], 'blue');
      expect(imported.claudeCodeHeaders, isTrue);
      expect(imported.fallbackModels, <String>['claude-haiku-4-5']);
      expect(imported.budgets.single.limit, 10);
    });

    test('nonsense is reported in a sentence, not a stack trace', () {
      expect(
        () => decodeProviders('not json at all'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', 'That is not JSON.')),
      );
    });

    test('the wrong kind of export is rejected rather than half-read', () {
      // A character card, say: valid JSON with nothing provider-shaped in it.
      expect(
        () => decodeProviders('{"name":"Aria","description":"a character"}'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', 'No provider in that file.')),
      );
      expect(() => decodeProviders('[]'), throwsA(isA<FormatException>()));
      expect(() => decodeProviders('42'), throwsA(isA<FormatException>()));
    });
  });
}
