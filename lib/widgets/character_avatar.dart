import 'package:flutter/material.dart';

import '../models/character.dart';
import '../models/chat_interface.dart';

/// An avatar for a character: its picture when it has one (a URL or the base64
/// image an imported card carried), falling back to a tinted monogram so every
/// character still reads at a glance.
///
/// Defaults to a circle sized by [radius] (used by the roster and detail
/// screens); the chat drives it by explicit [size] (diameter) plus [shape] and
/// [fit] so it can honour the Chat Interface settings.
class CharacterAvatar extends StatelessWidget {
  const CharacterAvatar({
    super.key,
    required this.character,
    this.radius = 24,
    this.size,
    this.shape = AvatarShape.circle,
    this.fit = AvatarFit.cover,
  });

  final Character character;
  final double radius;

  /// Diameter in logical pixels; overrides [radius] when set.
  final double? size;
  final AvatarShape shape;
  final AvatarFit fit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diameter = size ?? radius * 2;
    final bytes = character.avatarBytes;
    ImageProvider? image;
    if (character.avatarIsUrl) {
      image = NetworkImage(character.avatar.trim());
    } else if (bytes != null) {
      image = MemoryImage(bytes);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(shape.radiusFor(diameter)),
      child: Container(
        width: diameter,
        height: diameter,
        color: scheme.secondaryContainer,
        alignment: Alignment.center,
        child: image == null
            ? _monogram(scheme, diameter)
            : Image(
                image: image,
                width: diameter,
                height: diameter,
                fit: fit.boxFit,
                // A dead URL / bad bytes must not crash the list; the monogram
                // shows through instead.
                errorBuilder: (_, _, _) => _monogram(scheme, diameter),
              ),
      ),
    );
  }

  Widget _monogram(ColorScheme scheme, double diameter) {
    final name = character.displayName.trim();
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return Text(
      initial,
      style: TextStyle(
        fontSize: diameter * 0.4,
        fontWeight: FontWeight.w600,
        color: scheme.onSecondaryContainer,
      ),
    );
  }
}
