import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/model_context.dart';

void main() {
  test('resolves the major families', () {
    expect(knownMaxContext('gpt-4o'), 128000);
    expect(knownMaxContext('claude-3-5-sonnet-20241022'), 200000);
    expect(knownMaxContext('gemini-2.5-pro'), 1048576);
    expect(knownMaxContext('deepseek-reasoner'), 65536);
  });

  test('a longer key wins, so gpt-4o never resolves through gpt-4', () {
    expect(knownMaxContext('gpt-4'), 8192);
    expect(knownMaxContext('gpt-4o-mini-2024-07-18'), 128000);
    expect(knownMaxContext('gpt-4-32k'), 32768);
  });

  test('ignores case and a gateway vendor prefix', () {
    expect(knownMaxContext('OpenAI/GPT-4o'), 128000);
    expect(knownMaxContext('anthropic/claude-sonnet-4-5'), 200000);
    expect(knownMaxContext('meta-llama/llama-3.3-70b-instruct'), 131072);
  });

  test('drops an OpenRouter routing suffix', () {
    expect(knownMaxContext('deepseek/deepseek-r1:free'), 65536);
  });

  test('a window stated in the id wins over the table', () {
    expect(knownMaxContext('moonshot-v1-128k'), 128 * 1024);
    expect(knownMaxContext('yi-34b-200k'), 200 * 1024);
    expect(knownMaxContext('qwen2.5-7b-instruct-1m'), 1024 * 1024);
  });

  test('a size-like fragment that is not a window is not mistaken for one', () {
    // "8b" is a parameter count, "3.5" a version — neither states a window.
    expect(knownMaxContext('llama-3.1-8b-instruct'), 131072);
    expect(knownMaxContext('gpt-3.5-turbo'), 16385);
  });

  test('an unknown model resolves to nothing rather than a guess', () {
    expect(knownMaxContext('some-local-finetune-v2'), isNull);
    expect(knownMaxContext(''), isNull);
    expect(knownMaxContext('   '), isNull);
  });
}
