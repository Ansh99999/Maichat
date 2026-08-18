import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/floating_image.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/avatar_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A real 1x1 PNG, so what is written is a picture a decoder would accept.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
    'DUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==');

/// A distinguishable second picture (the trailing bytes make a different file).
Uint8List _picture(int seed) =>
    Uint8List.fromList([..._png, ...List<int>.filled(8, seed)]);

void main() {
  late Directory dir;
  late AvatarStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('gallery');
    store = AvatarStore(dir);
    clearAvatarImageCache();
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
    avatarDirectory = null;
  });

  Future<AppState> app() async {
    final state = AppState(avatars: store);
    await state.init();
    return state;
  }

  File fileFor(String ref) => File('${dir.path}/${avatarRefName(ref)}');

  group('adding pictures', () {
    test('a picture becomes a file and the store holds only its reference',
        () async {
      final state = await app();
      final added = await state.addGalleryImages(
        [_png],
        characterId: 'sumire',
        title: 'Beach outfit',
        tags: ['beach', 'summer'],
      );

      final image = added.single;
      expect(avatarIsLocal(image.image), isTrue);
      expect(fileFor(image.image).readAsBytesSync(), _png);
      expect(image.title, 'Beach outfit');
      expect(image.tags, ['beach', 'summer']);
      expect(image.characterId, 'sumire');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gallery'), isNotNull);
      expect(prefs.getString('gallery'), isNot(contains(base64Encode(_png))),
          reason: 'a picture must never live inside the preferences store');
      // Its own entry, so a photo does not rewrite the character roster.
      expect(prefs.getString('characters'), isNot(contains('gallery')));
    });

    test('several pictures at once are numbered and share their tags', () async {
      final state = await app();
      final added = await state.addGalleryImages(
        [_picture(1), _picture(2), _picture(3)],
        title: 'Trip',
        tags: ['holiday'],
      );
      expect(added.map((i) => i.title), ['Trip 1', 'Trip 2', 'Trip 3']);
      expect(added.every((i) => i.tags.contains('holiday')), isTrue);
      // Three distinct files, not one shared reference.
      expect(added.map((i) => i.image).toSet(), hasLength(3));
    });

    test('a picture may belong to nobody', () async {
      final state = await app();
      final loose = (await state.addGalleryImages([_png])).single;
      expect(loose.characterId, isNull);
      expect(loose.isAttached, isFalse);
      expect(state.galleryFor(null), hasLength(1));
      expect(state.galleryFor('sumire'), isEmpty);
    });

    test('the gallery survives a restart', () async {
      final state = await app();
      await state.addGalleryImages([_png],
          characterId: 'sumire', title: 'Kept', tags: ['a']);

      final reopened = await app();
      final image = reopened.gallery.single;
      expect(image.title, 'Kept');
      expect(image.tags, ['a']);
      expect(image.characterId, 'sumire');
      expect(fileFor(image.image).existsSync(), isTrue);
    });
  });

  group('editing', () {
    test('title, tags, owner and star round-trip', () async {
      final state = await app();
      final image = (await state.addGalleryImages([_png])).single;

      await state.saveGalleryImage(
        image.copyWith(title: 'Renamed', tags: ['x'], characterId: 'sumire'),
      );
      await state.toggleGalleryStar(image.id);

      final reopened = await app();
      final stored = reopened.gallery.single;
      expect(stored.title, 'Renamed');
      expect(stored.tags, ['x']);
      expect(stored.characterId, 'sumire');
      expect(stored.starred, isTrue);
    });

    test('a picture can be detached from its owner again', () async {
      final state = await app();
      final image =
          (await state.addGalleryImages([_png], characterId: 'sumire')).single;
      await state.assignGalleryImage(image.id, null);
      expect(state.galleryImageById(image.id)!.characterId, isNull);
    });

    test('opening a picture records when, without touching updatedAt', () async {
      final state = await app();
      final image = (await state.addGalleryImages([_png])).single;
      final edited = image.updatedAt;
      expect(image.lastViewed, isNull);

      await state.touchGalleryImage(image.id);
      expect(state.galleryImageById(image.id)!.lastViewed, isNotNull);
      expect(state.galleryImageById(image.id)!.updatedAt, edited,
          reason: 'looking at something is not editing it');
    });

    test('tags are collected across the whole gallery, sorted', () async {
      final state = await app();
      await state.addGalleryImages([_picture(1)], tags: ['zebra', 'apple']);
      await state.addGalleryImages([_picture(2)], tags: ['apple', 'moose']);
      expect(state.galleryTags, ['apple', 'moose', 'zebra']);
    });
  });

  group('avatars from the gallery', () {
    test('the pool is the worn picture then the extras, de-duplicated',
        () async {
      final state = await app();
      final character = Character(id: 'c', name: 'Sumire', avatar: 'a');
      character.avatars.addAll(['b', 'a', '', 'c']);
      expect(state.avatarPoolFor(character), ['a', 'b', 'c']);
    });

    test('the first picture set as an avatar is worn straight away', () async {
      final state = await app();
      await state.addCharacter(Character(id: 'c', name: 'Sumire'));
      await state.addAvatarToPool('c', 'local:one.png');

      final character = state.characterById('c')!;
      expect(character.avatar, 'local:one.png');
      expect(character.avatars, isEmpty,
          reason: 'the worn picture is not repeated in the pool');
    });

    test('a second picture joins the pool without changing the face', () async {
      final state = await app();
      await state.addCharacter(
          Character(id: 'c', name: 'Sumire', avatar: 'local:one.png'));
      await state.addAvatarToPool('c', 'local:two.png');

      final character = state.characterById('c')!;
      expect(character.avatar, 'local:one.png');
      expect(character.avatars, ['local:two.png']);
      expect(state.isAvatarOf(character, 'local:two.png'), isTrue);
    });

    test('setting a default swaps faces and keeps the old one in the pool',
        () async {
      final state = await app();
      await state.addCharacter(
          Character(id: 'c', name: 'Sumire', avatar: 'local:one.png'));
      await state.addAvatarToPool('c', 'local:two.png');
      await state.setDefaultAvatar('c', 'local:two.png');

      final character = state.characterById('c')!;
      expect(character.avatar, 'local:two.png');
      expect(character.avatars, ['local:one.png']);
      expect(state.avatarPoolFor(character), ['local:two.png', 'local:one.png']);
    });

    test('removing from the pool falls back to the next picture', () async {
      final state = await app();
      await state.addCharacter(
          Character(id: 'c', name: 'Sumire', avatar: 'local:one.png'));
      await state.addAvatarToPool('c', 'local:two.png');
      await state.removeAvatarFromPool('c', 'local:one.png');

      final character = state.characterById('c')!;
      expect(character.avatar, 'local:two.png');
      expect(character.avatars, isEmpty);
    });

    test('a per-chat choice wins over the card, and clearing gives it back',
        () async {
      final state = await app();
      final character =
          Character(id: 'c', name: 'Sumire', avatar: 'local:one.png');
      await state.addCharacter(character);
      state.startChatWithCharacter(character);
      final chat = state.active.id;

      expect(state.avatarRefFor(state.active, character), 'local:one.png');

      await state.setChatAvatar(chat, 'c', 'local:two.png');
      expect(state.avatarRefFor(state.active, character), 'local:two.png');
      // The card itself is untouched — that is what makes it per-chat.
      expect(state.characterById('c')!.avatar, 'local:one.png');
      // And a different thread still sees the card's own picture.
      expect(state.avatarRefFor(null, character), 'local:one.png');

      await state.setChatAvatar(chat, 'c', null);
      expect(state.avatarRefFor(state.active, character), 'local:one.png');
    });

    test('a per-chat choice survives a restart', () async {
      final state = await app();
      final character =
          Character(id: 'c', name: 'Sumire', avatar: 'local:one.png');
      await state.addCharacter(character);
      state.startChatWithCharacter(character);
      await state.setChatAvatar(state.active.id, 'c', 'local:two.png');

      final reopened = await app();
      expect(reopened.active.avatarOverrides['c'], 'local:two.png');
    });
  });

  group('deleting', () {
    test('deleting a picture unpicks every reference to it', () async {
      final state = await app();
      final character = Character(id: 'c', name: 'Sumire');
      await state.addCharacter(character);
      final worn = (await state.addGalleryImages([_picture(1)],
              characterId: 'c'))
          .single;
      final pooled = (await state.addGalleryImages([_picture(2)],
              characterId: 'c'))
          .single;
      await state.addAvatarToPool('c', worn.image);
      await state.addAvatarToPool('c', pooled.image);

      state.startChatWithCharacter(state.characterById('c')!);
      final chat = state.active.id;
      await state.setChatAvatar(chat, 'c', pooled.image);
      await state.floatImage(chat, pooled.id);
      expect(state.floatingImagesFor(state.active), hasLength(1));

      await state.deleteGalleryImage(pooled.id);

      final fresh = state.characterById('c')!;
      expect(fresh.avatars, isEmpty, reason: 'dropped from the pool');
      expect(fresh.avatar, worn.image, reason: 'the worn picture is untouched');
      expect(state.active.avatarOverrides.containsKey('c'), isFalse,
          reason: 'the chat falls back to the card');
      expect(state.floatingImagesFor(state.active), isEmpty,
          reason: 'a float with nothing to draw is removed');
      expect(fileFor(pooled.image).existsSync(), isFalse,
          reason: 'the file is swept');
      expect(fileFor(worn.image).existsSync(), isTrue);
    });

    test('deleting the worn picture promotes the next one', () async {
      final state = await app();
      await state.addCharacter(Character(id: 'c', name: 'Sumire'));
      final first =
          (await state.addGalleryImages([_picture(1)], characterId: 'c')).single;
      final second =
          (await state.addGalleryImages([_picture(2)], characterId: 'c')).single;
      await state.addAvatarToPool('c', first.image);
      await state.addAvatarToPool('c', second.image);
      expect(state.characterById('c')!.avatar, first.image);

      await state.deleteGalleryImage(first.id);
      final fresh = state.characterById('c')!;
      expect(fresh.avatar, second.image);
      expect(fresh.avatars, isEmpty);
    });

    test('deleting the only picture leaves a monogram, not a dangling ref',
        () async {
      final state = await app();
      await state.addCharacter(Character(id: 'c', name: 'Sumire'));
      final only =
          (await state.addGalleryImages([_png], characterId: 'c')).single;
      await state.addAvatarToPool('c', only.image);

      await state.deleteGalleryImage(only.id);
      expect(state.characterById('c')!.avatar, '');
    });

    test('several pictures delete in one pass', () async {
      final state = await app();
      final images = await state.addGalleryImages(
          [_picture(1), _picture(2), _picture(3)]);
      await state.deleteGalleryImages([images[0].id, images[2].id]);
      expect(state.gallery.map((i) => i.id), [images[1].id]);
    });

    test('deleting a character keeps its photos, detached', () async {
      final state = await app();
      await state.addCharacter(Character(id: 'c', name: 'Sumire'));
      final image =
          (await state.addGalleryImages([_png], characterId: 'c')).single;

      await state.deleteCharacter('c');

      final kept = state.galleryImageById(image.id);
      expect(kept, isNotNull, reason: 'a tagged photo outlives the card');
      expect(kept!.characterId, isNull);
      expect(fileFor(image.image).existsSync(), isTrue,
          reason: 'the sweep must not take a picture the gallery still holds');
    });

    test('deleting a character drops its per-chat avatar choices', () async {
      final state = await app();
      final character =
          Character(id: 'c', name: 'Sumire', avatar: 'local:one.png');
      await state.addCharacter(character);
      state.startChatWithCharacter(character);
      await state.setChatAvatar(state.active.id, 'c', 'local:two.png');

      await state.deleteCharacter('c');
      expect(state.active.avatarOverrides, isEmpty);
    });
  });

  group('the sweep', () {
    test('leaves gallery pictures, pooled avatars and chat choices alone',
        () async {
      final state = await app();
      final character = Character(id: 'c', name: 'Sumire');
      await state.addCharacter(character);

      final galleryOnly = (await state.addGalleryImages([_picture(1)])).single;
      final pooled =
          (await state.addGalleryImages([_picture(2)], characterId: 'c')).single;
      final chatChoice =
          (await state.addGalleryImages([_picture(3)], characterId: 'c')).single;
      await state.addAvatarToPool('c', pooled.image);
      state.startChatWithCharacter(state.characterById('c')!);
      await state.setChatAvatar(state.active.id, 'c', chatChoice.image);

      // Any delete runs a sweep; this is the moment a forgotten keep-list entry
      // would take a picture that is still on screen.
      await state.addCharacter(Character(id: 'other', name: 'Other'));
      await state.deleteCharacter('other');

      for (final ref in [galleryOnly.image, pooled.image, chatChoice.image]) {
        expect(fileFor(ref).existsSync(), isTrue, reason: 'kept: $ref');
      }
    });

    test('collects a picture nothing refers to any more', () async {
      final state = await app();
      final ref = await state.storePicture(_png);
      expect(fileFor(ref!).existsSync(), isTrue);

      // Never committed to a gallery record: the next sweep is entitled to it.
      await state.addCharacter(Character(id: 'x', name: 'X'));
      await state.deleteCharacter('x');
      expect(fileFor(ref).existsSync(), isFalse);
    });
  });

  group('floats', () {
    test('floating, raising, moving and dismissing', () async {
      final state = await app();
      final images =
          await state.addGalleryImages([_picture(1), _picture(2)]);
      state.newConversation();
      final chat = state.active.id;

      await state.floatImage(chat, images[0].id);
      await state.floatImage(chat, images[1].id);
      expect(state.active.floatingImages.map((f) => f.imageId),
          [images[0].id, images[1].id]);
      // Fanned out rather than exactly stacked.
      expect(state.active.floatingImages[0].x,
          isNot(state.active.floatingImages[1].x));

      // Floating the same picture again raises it instead of duplicating.
      await state.floatImage(chat, images[0].id);
      expect(state.active.floatingImages, hasLength(2));
      expect(state.active.floatingImages.last.imageId, images[0].id);

      await state.moveFloatingImage(chat, images[0].id,
          x: 0.5, y: 0.25, width: 300, rotation: 0.4);
      final moved = state.active.floatingImages
          .firstWhere((f) => f.imageId == images[0].id);
      expect(moved.x, 0.5);
      expect(moved.y, 0.25);
      expect(moved.width, 300);
      expect(moved.rotation, closeTo(0.4, 1e-9));

      await state.unfloatImage(chat, images[0].id);
      expect(state.active.floatingImages.map((f) => f.imageId),
          [images[1].id]);
      await state.clearFloatingImages(chat);
      expect(state.active.floatingImages, isEmpty);
    });

    test('a float is clamped to somewhere reachable', () async {
      final state = await app();
      final image = (await state.addGalleryImages([_png])).single;
      state.newConversation();
      final chat = state.active.id;
      await state.floatImage(chat, image.id);

      await state.moveFloatingImage(chat, image.id,
          x: 9, y: -9, width: 100000);
      final float = state.active.floatingImages.single;
      expect(float.x, lessThanOrEqualTo(1));
      expect(float.y, greaterThanOrEqualTo(-1));
      expect(float.width, lessThanOrEqualTo(1600));
    });

    test('floats survive a restart and a fork', () async {
      final state = await app();
      final image = (await state.addGalleryImages([_png])).single;
      final character = Character(id: 'c', name: 'Sumire', firstMes: 'Hi.');
      await state.addCharacter(character);
      state.startChatWithCharacter(character);
      final chat = state.active.id;
      await state.floatImage(chat, image.id);
      await state.moveFloatingImage(chat, image.id, x: 0.4, rotation: 0.2);

      final reopened = await app();
      final restored = reopened.conversationById(chat)!.floatingImages.single;
      expect(restored.imageId, image.id);
      expect(restored.x, 0.4);
      expect(restored.rotation, closeTo(0.2, 1e-9));

      // copyAs is field-blind, but a dropped field here has happened before.
      await reopened.forkConversation(chat, 0);
      final fork = reopened.active;
      expect(fork.id, isNot(chat));
      expect(fork.floatingImages.single.imageId, image.id);
      expect(fork.floatingImages.single.x, 0.4);
    });

    test('floating a picture that does not exist does nothing', () async {
      final state = await app();
      state.newConversation();
      await state.floatImage(state.active.id, 'nope');
      expect(state.active.floatingImages, isEmpty);
    });

    test('a float whose picture is gone is skipped, not drawn blank', () async {
      final state = await app();
      final image = (await state.addGalleryImages([_png])).single;
      state.newConversation();
      final chat = state.active.id;
      await state.floatImage(chat, image.id);
      expect(state.floatingImagesFor(state.active), hasLength(1));

      // A stale float, as a store written before the delete cascade existed (or
      // hand-edited) would carry: the layer must skip it rather than draw an
      // empty frame nobody can explain.
      state.active.floatingImages.add(FloatingImage(imageId: 'vanished'));
      expect(state.active.floatingImages, hasLength(2));
      expect(state.floatingImagesFor(state.active), hasLength(1));
      expect(state.floatingImagesFor(state.active).single.$2.id, image.id);

      await state.deleteGalleryImage(image.id);
      expect(state.floatingImagesFor(state.active), isEmpty);
    });
  });
}
