import 'package:flutter/material.dart';

import '../models/character.dart';

/// A round avatar for a character: its picture when it has one (a URL or the
/// base64 image an imported PNG card carried), falling back to a tinted
/// monogram so every character still reads at a glance.
class CharacterAvatar extends StatelessWidget {
  const CharacterAvatar({super.key, required this.character, this.radius = 24});

  final Character character;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = character.avatarBytes;
    ImageProvider? image;
    if (character.avatarIsUrl) {
      image = NetworkImage(character.avatar.trim());
    } else if (bytes != null) {
      image = MemoryImage(bytes);
    }

    if (image != null) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: scheme.secondaryContainer,
        backgroundImage: image,
        // A dead URL / bad bytes must not crash the list; the monogram shows
        // through the transparent foreground.
        onBackgroundImageError: (_, _) {},
        child: _monogram(scheme, transparent: true),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.secondaryContainer,
      child: _monogram(scheme),
    );
  }

  Widget _monogram(ColorScheme scheme, {bool transparent = false}) {
    final name = character.displayName.trim();
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return Text(
      initial,
      style: TextStyle(
        fontSize: radius * 0.8,
        fontWeight: FontWeight.w600,
        color: transparent
            ? Colors.transparent
            : scheme.onSecondaryContainer,
      ),
    );
  }
}
