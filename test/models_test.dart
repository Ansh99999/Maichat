import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/appearance.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/models/floating_image.dart';
import 'package:maichat/models/gallery_image.dart';
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

  group('gallery pictures', () {
    test('a gallery image survives a JSON round trip', () {
      final original = GalleryImage.create(
        image: 'local:beach.png',
        title: 'Beach outfit',
        tags: ['beach', 'summer'],
        characterId: 'sumire',
      )
        ..starred = true
        ..lastViewed = DateTime(2026, 4, 24, 9, 30);

      final restored = GalleryImage.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.image, 'local:beach.png');
      expect(restored.title, 'Beach outfit');
      expect(restored.tags, ['beach', 'summer']);
      expect(restored.characterId, 'sumire');
      expect(restored.starred, isTrue);
      expect(restored.lastViewed, DateTime(2026, 4, 24, 9, 30));
      expect(restored.createdAt, original.createdAt);
    });

    test('an unnamed, unowned picture writes a minimal record', () {
      final json = GalleryImage.create(image: 'local:a.png').toJson();
      expect(json.keys, containsAll(['id', 'image', 'createdAt', 'updatedAt']));
      expect(json.containsKey('title'), isFalse);
      expect(json.containsKey('tags'), isFalse);
      expect(json.containsKey('characterId'), isFalse);
      expect(json.containsKey('starred'), isFalse);
      expect(json.containsKey('lastViewed'), isFalse);
    });

    test('an empty owner reads back as no owner', () {
      final restored = GalleryImage.fromJson(<String, dynamic>{
        'image': 'local:a.png',
        'characterId': '   ',
      });
      expect(restored.characterId, isNull);
      expect(restored.displayTitle, 'Untitled');
    });

    test('tags flattened into a string are still read as tags', () {
      final restored = GalleryImage.fromJson(<String, dynamic>{
        'image': 'local:a.png',
        'tags': 'beach, summer ,, smile',
      });
      expect(restored.tags, ['beach', 'summer', 'smile']);
    });

    test('copyWith can detach an owner, which a null default could not', () {
      final owned = GalleryImage.create(image: 'a', characterId: 'sumire');
      expect(owned.copyWith(title: 'x').characterId, 'sumire');
      expect(owned.copyWith(characterId: null).characterId, isNull);
    });

    test('the zoom ladder steps and stops at both ends', () {
      expect(kDefaultGalleryZoom, GalleryZoom.pair);
      expect(GalleryZoom.pair.columns, 2);
      expect(GalleryZoom.pair.grouping, DateGrouping.day);
      expect(GalleryZoom.pair.out, GalleryZoom.quad);
      expect(GalleryZoom.quad.grouping, DateGrouping.week);
      expect(GalleryZoom.quad.out, GalleryZoom.month);
      expect(GalleryZoom.month.grouping, DateGrouping.month);
      expect(GalleryZoom.month.out, GalleryZoom.month, reason: 'ladder ends');
      expect(GalleryZoom.pair.inward, GalleryZoom.single);
      expect(GalleryZoom.single.inward, GalleryZoom.single);
    });

    test('only date orderings carry date headings', () {
      expect(GallerySort.newest.isChronological, isTrue);
      expect(GallerySort.oldest.isChronological, isTrue);
      for (final sort in [
        GallerySort.titleAsc,
        GallerySort.titleDesc,
        GallerySort.lastViewed,
        GallerySort.character,
      ]) {
        expect(sort.isChronological, isFalse, reason: sort.name);
      }
      expect(GallerySort.byName('titleDesc'), GallerySort.titleDesc);
      expect(GallerySort.byName('nonsense'), GallerySort.newest);
    });
  });

  group('floating pictures', () {
    test('a float survives a JSON round trip', () {
      final original = FloatingImage(
        imageId: 'img-1',
        x: 0.4,
        y: 0.2,
        width: 240,
        rotation: 0.35,
      );
      final restored = FloatingImage.fromJson(original.toJson());
      expect(restored.imageId, 'img-1');
      expect(restored.x, 0.4);
      expect(restored.y, 0.2);
      expect(restored.width, 240);
      expect(restored.rotation, closeTo(0.35, 1e-9));
    });

    test('an unrotated float omits its rotation', () {
      expect(FloatingImage(imageId: 'a').toJson().containsKey('rotation'),
          isFalse);
    });

    test('a stored position out of range is pulled back into reach', () {
      final restored = FloatingImage.fromJson(<String, dynamic>{
        'imageId': 'a',
        'x': 40.0,
        'y': -40.0,
        'width': 99999.0,
      });
      expect(restored.x, kFloatingImageMaxFraction);
      expect(restored.y, kFloatingImageMinFraction);
      expect(restored.width, kFloatingImageMaxWidth);
    });

    test('nonsense numbers do not escape into the layout', () {
      final restored = FloatingImage.fromJson(<String, dynamic>{
        'imageId': 'a',
        'x': double.nan,
        'y': double.infinity,
      });
      expect(restored.x, 0);
      expect(restored.y, 0);
    });

    test('rotation normalises into a single turn', () {
      expect(FloatingImage.normaliseRotation(0.5), closeTo(0.5, 1e-9));
      // Seven half-turns is one half-turn.
      expect(FloatingImage.normaliseRotation(7 * 3.141592653589793),
          closeTo(3.141592653589793, 1e-9));
      expect(FloatingImage.normaliseRotation(double.nan), 0);
    });

    test('avatar choices persist; floats are ephemeral but copied on a fork',
        () {
      final original = Conversation.empty()
        ..avatarOverrides['sumire'] = 'local:two.png'
        ..floatingImages.add(FloatingImage(imageId: 'img-1', x: 0.3));

      // Floats live in memory only — deliberately not written to disk, so a
      // load of the store has none (they vanish when the app is fully closed).
      final restored = Conversation.fromJson(original.toJson());
      expect(restored.avatarOverrides, {'sumire': 'local:two.png'});
      expect(restored.floatingImages, isEmpty,
          reason: 'floats are not serialized');

      // But a fork within the session deep-copies them (copyAs is field-blind,
      // and a dropped field here has bitten before).
      final fork = original.copyAs(id: 'fork');
      expect(fork.avatarOverrides, {'sumire': 'local:two.png'});
      expect(fork.floatingImages.single.x, 0.3);
      // Copied, not shared: the two threads must be able to diverge.
      fork.floatingImages.single.x = 0.9;
      fork.avatarOverrides['sumire'] = 'local:three.png';
      expect(original.floatingImages.single.x, 0.3);
      expect(original.avatarOverrides['sumire'], 'local:two.png');
    });

    test('an empty avatar choice is dropped rather than hiding a picture', () {
      final restored = Conversation.fromJson(<String, dynamic>{
        'id': 'c',
        'avatarOverrides': {'sumire': '  ', 'aoi': 'local:a.png'},
        'floatingImages': [
          {'imageId': ''},
          {'imageId': 'ok'},
        ],
        'messages': <dynamic>[],
      });
      expect(restored.avatarOverrides, {'aoi': 'local:a.png'});
      expect(restored.floatingImages.map((f) => f.imageId), ['ok']);
    });

    test('a chat with no gallery state writes no gallery keys', () {
      final json = Conversation.empty().toJson();
      expect(json.containsKey('avatarOverrides'), isFalse);
      expect(json.containsKey('floatingImages'), isFalse);
    });
  });

  group('character avatar pool', () {
    test('extra avatars round-trip and are omitted when empty', () {
      final plain = Character(id: 'c', name: 'Sumire', avatar: 'local:a.png');
      expect(plain.toJson().containsKey('avatars'), isFalse);

      plain.avatars.addAll(['local:b.png', 'local:c.png']);
      final restored = Character.fromJson(plain.toJson());
      expect(restored.avatar, 'local:a.png');
      expect(restored.avatars, ['local:b.png', 'local:c.png']);
    });

    test('a copy owns its own pool', () {
      final original = Character(id: 'c', name: 'Sumire')
        ..avatars.add('local:a.png');
      final copy = original.clone();
      copy.avatars.add('local:b.png');
      expect(original.avatars, ['local:a.png']);
      expect(copy.avatars, ['local:a.png', 'local:b.png']);
    });
  });
}
