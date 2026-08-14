import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Keeping stored avatars to a sane size.
///
/// A character's picture is persisted as base64 *inside* the preferences store,
/// which the app reads in full at every launch and rewrites in full on every
/// save. A picture straight off the camera roll can be 10 MB, and at that point
/// the picture — not the chat — is what makes the app slow to start and slow to
/// save. Nothing in the UI draws an avatar larger than a few hundred pixels, so
/// anything beyond [kMaxAvatarSide] is cost with no benefit.

/// Longest side, in pixels, kept for a stored avatar. Comfortably above the
/// largest place one is drawn (the character card grid) even on a 3x screen.
const int kMaxAvatarSide = 768;

/// Encoded size above which an avatar is re-encoded on its way into storage.
/// Below it the original bytes are kept untouched, so ordinary card art (and
/// its exact round-trip) is left exactly as it was.
const int kAvatarShrinkAboveBytes = 512 * 1024;

/// Returns [bytes] shrunk to fit [kMaxAvatarSide], or the original bytes when
/// they are already small enough, not an image, or would not get smaller.
///
/// Never throws: a picture that cannot be decoded is stored as-is rather than
/// lost.
Future<Uint8List> shrinkAvatarBytes(
  Uint8List bytes, {
  int maxSide = kMaxAvatarSide,
  int shrinkAbove = kAvatarShrinkAboveBytes,
}) async {
  if (bytes.length <= shrinkAbove) return bytes;
  try {
    final probe = await ui.instantiateImageCodec(bytes);
    final frame = await probe.getNextFrame();
    final width = frame.image.width;
    final height = frame.image.height;
    frame.image.dispose();
    probe.dispose();
    if (width <= 0 || height <= 0) return bytes;

    // Already small in pixel terms (a big file for other reasons): leave it.
    if (width <= maxSide && height <= maxSide) return bytes;

    final codec = width >= height
        ? await ui.instantiateImageCodec(bytes, targetWidth: maxSide)
        : await ui.instantiateImageCodec(bytes, targetHeight: maxSide);
    final resized = await codec.getNextFrame();
    final data =
        await resized.image.toByteData(format: ui.ImageByteFormat.png);
    resized.image.dispose();
    codec.dispose();
    if (data == null) return bytes;
    final out = data.buffer.asUint8List();
    // A PNG re-encode of a photo can be bigger than the JPEG it came from.
    return out.length < bytes.length ? out : bytes;
  } catch (error) {
    debugPrint('MaiChat: could not resize avatar ($error); storing as-is');
    return bytes;
  }
}

/// The base64 form of [avatar] shrunk to fit, or [avatar] unchanged when it is a
/// URL, is already small, or cannot be decoded.
Future<String> shrinkAvatarBase64(String avatar) async {
  final trimmed = avatar.trim();
  if (trimmed.isEmpty) return avatar;
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return avatar;
  }
  if (trimmed.length <= kAvatarShrinkAboveBytes) return avatar;
  try {
    final bytes = base64Decode(trimmed);
    final shrunk = await shrinkAvatarBytes(bytes);
    if (shrunk.length == bytes.length) return avatar;
    return base64Encode(shrunk);
  } catch (_) {
    return avatar;
  }
}
