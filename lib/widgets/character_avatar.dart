import 'package:flutter/material.dart';

import '../models/character.dart';
import '../models/chat_interface.dart';

/// An avatar for a character: its picture when it has one (a URL or the base64
/// image an imported card carried), falling back to a tinted monogram.
///
/// Sizing: [AvatarFit.cover]/[AvatarFit.contain] draw a square [size] (or
/// [radius]) frame; [AvatarFit.free] keeps the picture's own aspect ratio,
/// sizing the frame so its longest side equals [size] — so a 16:9 and a 3:4
/// avatar each keep their real proportions. The intrinsic ratio is resolved
/// from the decoded image; until it is known (or for the monogram) the frame
/// stays square.
class CharacterAvatar extends StatefulWidget {
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
  State<CharacterAvatar> createState() => _CharacterAvatarState();
}

class _CharacterAvatarState extends State<CharacterAvatar> {
  ImageProvider? _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// Intrinsic width / height of the resolved image, when known.
  double? _ratio;

  double get _diameter => widget.size ?? widget.radius * 2;

  ImageProvider? _resolveProvider() {
    final c = widget.character;
    if (c.avatarIsUrl) return NetworkImage(c.avatar.trim());
    final bytes = c.avatarBytes;
    if (bytes != null) return MemoryImage(bytes);
    return null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncStream();
  }

  @override
  void didUpdateWidget(CharacterAvatar old) {
    super.didUpdateWidget(old);
    if (old.character.avatar != widget.character.avatar ||
        old.fit != widget.fit) {
      _ratio = null;
      _syncStream();
    }
  }
// APPEND-STATE

  /// Only free mode needs the intrinsic ratio, so only then do we resolve the
  /// image stream just to measure it.
  void _syncStream() {
    final provider = _resolveProvider();
    final needsRatio = widget.fit == AvatarFit.free && provider != null;
    if (!needsRatio) {
      _detach();
      _provider = provider;
      return;
    }
    if (provider == _provider && _stream != null) return;
    _detach();
    _provider = provider;
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) {
      final w = info.image.width.toDouble();
      final h = info.image.height.toDouble();
      if (h <= 0 || w <= 0) return;
      final ratio = w / h;
      if (mounted && ratio != _ratio) setState(() => _ratio = ratio);
    }, onError: (_, _) {
      // Bad image: leave the frame square and let the monogram show.
    });
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _detach() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final provider = _provider;
    final size = _diameter;

    // Frame dimensions: square unless we're in free mode with a known ratio.
    double w = size;
    double h = size;
    final ratio = _ratio;
    if (widget.fit == AvatarFit.free && ratio != null && provider != null) {
      if (ratio >= 1) {
        w = size;
        h = size / ratio;
      } else {
        h = size;
        w = size * ratio;
      }
    }

    final radius = widget.shape.radiusFor(w < h ? w : h);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: w,
        height: h,
        color: scheme.secondaryContainer,
        alignment: Alignment.center,
        child: provider == null
            ? _monogram(scheme, size)
            : Image(
                image: provider,
                width: w,
                height: h,
                fit: widget.fit.boxFit,
                errorBuilder: (_, _, _) => _monogram(scheme, size),
              ),
      ),
    );
  }

  Widget _monogram(ColorScheme scheme, double size) {
    final name = widget.character.displayName.trim();
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return Text(
      initial,
      style: TextStyle(
        fontSize: size * 0.4,
        fontWeight: FontWeight.w600,
        color: scheme.onSecondaryContainer,
      ),
    );
  }
}

