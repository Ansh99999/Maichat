import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/appearance.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/settings.dart';

void main() {
  test('conversation survives a JSON round trip', () {
    final original = Conversation.empty()
      ..title = 'Tides'
      ..messages.addAll([
        ChatMessage(role: 'user', content: 'hi'),
        ChatMessage(role: 'assistant', content: 'hello'),
        ChatMessage(role: 'assistant', content: 'boom', error: true),
      ]);

    final restored = Conversation.fromJson(original.toJson());

    expect(restored.id, original.id);
    expect(restored.title, 'Tides');
    expect(restored.messages.length, 3);
    expect(restored.messages[1].content, 'hello');
    expect(restored.messages[2].error, isTrue);
    expect(restored.messages[0].isUser, isTrue);
  });

  test('retitleFrom collapses whitespace and truncates long prompts', () {
    final short = Conversation.empty()..retitleFrom('  hello   there \n');
    expect(short.title, 'hello there');

    final long = Conversation.empty()..retitleFrom('x' * 80);
    expect(long.title.length, 43);
    expect(long.title.endsWith('...'), isTrue);
  });

  test('retitleFrom ignores blank input', () {
    final conversation = Conversation.empty()..retitleFrom('   ');
    expect(conversation.title, 'New chat');
  });

  test('settings are only configured once a model is chosen', () {
    const bare = AppSettings();
    expect(bare.isConfigured, isFalse);
    expect(bare.baseUrl, AppSettings.defaultBaseUrl);
    expect(bare.copyWith(model: 'gpt-4o-mini').isConfigured, isTrue);
  });

  test('settings survive a JSON round trip', () {
    const original = AppSettings(
      baseUrl: 'https://host.tld/v1',
      apiKey: 'sk-test',
      model: 'm',
    );
    final restored = AppSettings.fromJson(original.toJson());
    expect(restored.baseUrl, 'https://host.tld/v1');
    expect(restored.apiKey, 'sk-test');
    expect(restored.model, 'm');
  });

  test('a provider is only configured once it has a URL and a model', () {
    final bare = Provider.create(ProviderKind.openai);
    expect(bare.baseUrl, ProviderKind.openai.defaultBaseUrl);
    expect(bare.isConfigured, isFalse);
    expect(bare.copyWith(model: 'gpt-4o-mini').isConfigured, isTrue);
  });

  test('provider survives a JSON round trip', () {
    final original = Provider(
      id: 'p1',
      name: 'Work',
      kind: ProviderKind.anthropic,
      baseUrl: 'https://host.tld/v1',
      apiKey: 'sk-test',
      model: 'claude-sonnet-4-5',
    );
    final restored = Provider.fromJson(original.toJson());
    expect(restored.id, 'p1');
    expect(restored.name, 'Work');
    expect(restored.kind, ProviderKind.anthropic);
    expect(restored.baseUrl, 'https://host.tld/v1');
    expect(restored.apiKey, 'sk-test');
    expect(restored.model, 'claude-sonnet-4-5');
  });

  test('an unknown stored provider kind falls back to OpenAI-compatible', () {
    expect(ProviderKind.byName('mystery'), ProviderKind.openai);
    expect(ProviderKind.byName(null), ProviderKind.openai);
    expect(ProviderKind.byName('anthropic'), ProviderKind.anthropic);
    expect(ProviderKind.byName('gemini'), ProviderKind.gemini);
  });

  test('a provider carries a pool of keys with a rotation strategy', () {
    final original = Provider(
      id: 'p2',
      name: 'Pool',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      apiKeys: const ['  k1 ', 'k2', '   '],
      keyStrategy: KeyRotationStrategy.random,
      model: 'm',
    );
    // Blank entries are ignored at use time; the first usable key is the
    // single-key view.
    expect(original.usableKeys, ['k1', 'k2']);
    expect(original.apiKey, 'k1');

    final restored = Provider.fromJson(original.toJson());
    expect(restored.usableKeys, ['k1', 'k2']);
    expect(restored.keyStrategy, KeyRotationStrategy.random);

    // Pinning a key for one request leaves the strategy intact.
    final pinned = original.withActiveKey('k2');
    expect(pinned.apiKey, 'k2');
    expect(pinned.usableKeys, ['k2']);
  });

  test('a legacy single-key provider reads back as a one-key pool', () {
    final restored = Provider.fromJson(<String, dynamic>{
      'id': 'p3',
      'name': 'Legacy',
      'kind': 'openai',
      'baseUrl': 'https://host.tld/v1',
      'apiKey': 'sk-legacy',
      'model': 'm',
    });
    expect(restored.usableKeys, ['sk-legacy']);
    expect(restored.keyStrategy, KeyRotationStrategy.roundRobin);
  });

  test('an unknown key strategy falls back to round robin', () {
    expect(KeyRotationStrategy.byName('mystery'), KeyRotationStrategy.roundRobin);
    expect(KeyRotationStrategy.byName(null), KeyRotationStrategy.roundRobin);
    expect(
      KeyRotationStrategy.byName('error-based'),
      KeyRotationStrategy.errorBased,
    );
  });

  test('an unnamed provider shows its format label instead', () {
    final unnamed = Provider.create(ProviderKind.anthropic).copyWith(name: '  ');
    expect(unnamed.displayName, ProviderKind.anthropic.label);
  });

  test('appearance follows the system until told otherwise', () {
    const fresh = Appearance();
    expect(fresh.dynamicColor, isTrue);
    expect(fresh.mode, AppThemeMode.system);
    expect(fresh.seedColor, kDefaultSeedColor);
  });

  test('appearance survives a JSON round trip', () {
    const original = Appearance(
      dynamicColor: false,
      mode: AppThemeMode.dark,
      seedColor: 0xFF10B981,
    );
    final restored = Appearance.fromJson(original.toJson());
    expect(restored, original);
    expect(restored.seedColor, 0xFF10B981);
  });

  test('an unknown stored theme mode falls back to the system setting', () {
    final restored = Appearance.fromJson(<String, dynamic>{'mode': 'sepia'});
    expect(restored.mode, AppThemeMode.system);
    expect(restored.dynamicColor, isTrue);
  });

  test('the AMOLED mode round-trips and counts as dark', () {
    const original = Appearance(mode: AppThemeMode.amoled);
    final restored = Appearance.fromJson(original.toJson());
    expect(restored.mode, AppThemeMode.amoled);
    expect(restored.mode.isDark, isTrue);
    expect(AppThemeMode.dark.isDark, isTrue);
    expect(AppThemeMode.light.isDark, isFalse);
    expect(AppThemeMode.system.isDark, isFalse);
  });

  test('a stored appearance without a seed keeps the default colour', () {
    final restored = Appearance.fromJson(<String, dynamic>{
      'dynamicColor': false,
      'mode': 'dark',
    });
    expect(restored.seedColor, kDefaultSeedColor);
  });

  test('the app font round-trips and is omitted from JSON when unset', () {
    // Default: no font key written, so the stored shape stays minimal.
    expect(const Appearance().fontFamily, isNull);
    expect(const Appearance().toJson().containsKey('fontFamily'), isFalse);

    const original = Appearance(fontFamily: 'Roboto Slab');
    final restored = Appearance.fromJson(original.toJson());
    expect(restored, original);
    expect(restored.fontFamily, 'Roboto Slab');

    // copyWith clears the font back to the system default via the sentinel.
    expect(original.copyWith().fontFamily, 'Roboto Slab');
    expect(original.copyWith(fontFamily: null).fontFamily, isNull);
    // A blank stored value reads as "no font".
    expect(Appearance.fromJson(<String, dynamic>{'fontFamily': '  '}).fontFamily,
        isNull);
  });

  test('Discover preferences round-trip, per-section sorts included', () {
    const original = DiscoverPrefs(
      sourceId: 'chub',
      nsfw: true,
      sorts: <String, String>{'character': 'trending', 'lorebook': 'id'},
    );
    final restored = DiscoverPrefs.fromJson(original.toJson());

    expect(restored, original);
    expect(restored.sortFor(DiscoverKind.character), 'trending');
    expect(restored.sortFor(DiscoverKind.lorebook), 'id');
    expect(restored.sortFor(DiscoverKind.preset), isNull);

    // Setting one section's order leaves the others alone.
    final changed = original.withSort(DiscoverKind.lorebook, 'random');
    expect(changed.sortFor(DiscoverKind.lorebook), 'random');
    expect(changed.sortFor(DiscoverKind.character), 'trending');
    expect(changed == original, isFalse);
  });

  test('Discover preferences survive junk in the stored sorts map', () {
    final restored = DiscoverPrefs.fromJson(<String, dynamic>{
      'sourceId': 'janny',
      'nsfw': 'not a bool',
      'sorts': <String, dynamic>{'character': 'newest', 'lorebook': 7},
    });
    expect(restored.sourceId, 'janny');
    expect(restored.nsfw, isFalse);
    expect(restored.sortFor(DiscoverKind.character), 'newest');
    // A non-string order is dropped rather than crashing the launch read.
    expect(restored.sortFor(DiscoverKind.lorebook), isNull);
    expect(DiscoverPrefs.fromJson(const <String, dynamic>{}),
        const DiscoverPrefs());
  });
}
