import 'dart:math' as math;

/// One picture floating over a chat: which picture, where it sits, how big it is,
/// and how far it has been turned.
///
/// A float names its picture one of two ways. [imageId] points at a gallery
/// record, so editing or re-pointing that record is reflected and deleting it
/// takes the float with it. [imageRef] carries a picture reference directly, for
/// something that was never a gallery entry — an avatar that arrived on an
/// imported card, say. Exactly one of the two is set.
///
/// [x] and [y] are **fractions of the chat area** (0..1 from its top left), not
/// logical pixels. A phone rotated, a tablet, or a different text scale all change
/// the area's size, and a float stored in pixels would drift off screen or bunch
/// into a corner; a fraction lands in the same visual place everywhere. [width] is
/// in logical pixels, because a picture should not grow just because the window
/// did.
class FloatingImage {
  FloatingImage({
    this.imageId = '',
    this.imageRef = '',
    this.x = 0.08,
    this.y = 0.12,
    this.width = kFloatingImageDefaultWidth,
    this.rotation = 0,
  });

  /// The [GalleryImage.id] being shown, or empty when this float carries its own
  /// [imageRef].
  final String imageId;

  /// A picture reference (`local:<file>` or an http(s) URL) for a float that is
  /// not backed by a gallery record.
  final String imageRef;

  /// Position of the float's top-left corner, as a fraction of the chat area.
  double x;
  double y;

  /// The drawn width in logical pixels; the height follows the picture's own
  /// aspect ratio.
  double width;

  /// Rotation in radians, clockwise.
  double rotation;

  /// What identifies this float within a chat — a gallery id or a picture
  /// reference, tagged so the two can never collide.
  String get key => imageId.isNotEmpty ? 'g:$imageId' : 'r:$imageRef';

  /// Whether this float names something at all.
  bool get isEmpty => imageId.isEmpty && imageRef.isEmpty;

  FloatingImage copyWith({
    double? x,
    double? y,
    double? width,
    double? rotation,
  }) =>
      FloatingImage(
        imageId: imageId,
        imageRef: imageRef,
        x: x ?? this.x,
        y: y ?? this.y,
        width: width ?? this.width,
        rotation: rotation ?? this.rotation,
      );

  Map<String, dynamic> toJson() => {
        if (imageId.isNotEmpty) 'imageId': imageId,
        if (imageRef.isNotEmpty) 'imageRef': imageRef,
        'x': x,
        'y': y,
        'width': width,
        if (rotation != 0) 'rotation': rotation,
      };

  factory FloatingImage.fromJson(Map<String, dynamic> json) => FloatingImage(
        imageId: (json['imageId'] as String?)?.trim() ?? '',
        imageRef: (json['imageRef'] as String?)?.trim() ?? '',
        // Clamped on the way in as well as on the way out: a stored value can
        // come from an older build, a hand-edited store, or a screen that has
        // since changed shape, and a float nobody can reach is a float nobody can
        // dismiss.
        x: _fraction(json['x']),
        y: _fraction(json['y']),
        width: ((json['width'] as num?)?.toDouble() ??
                kFloatingImageDefaultWidth)
            .clamp(kFloatingImageMinWidth, kFloatingImageMaxWidth)
            .toDouble(),
        rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      );

  static double _fraction(Object? value) {
    final n = (value as num?)?.toDouble() ?? 0;
    if (n.isNaN || n.isInfinite) return 0;
    return n.clamp(kFloatingImageMinFraction, kFloatingImageMaxFraction)
        .toDouble();
  }

  /// Keeps a float's corner inside the chat area, leaving a sliver of it always
  /// reachable so it can be dragged back or closed.
  static double clampFraction(double value) => _fraction(value);

  /// Rotation, normalised into (-π, π] so repeated turns do not accumulate into
  /// a huge number in the store.
  static double normaliseRotation(double radians) {
    if (radians.isNaN || radians.isInfinite) return 0;
    const twoPi = math.pi * 2;
    var r = radians % twoPi;
    if (r > math.pi) r -= twoPi;
    if (r <= -math.pi) r += twoPi;
    return r;
  }
}

/// A float paired with the picture it draws — what the layer actually needs.
class FloatedPicture {
  const FloatedPicture({
    required this.float,
    required this.ref,
    required this.title,
  });

  final FloatingImage float;

  /// The picture reference to draw.
  final String ref;

  /// What to call it, when there is anything to call it.
  final String title;
}

/// How wide a picture arrives on the chat, in logical pixels — big enough to see,
/// small enough that it does not bury the conversation.
const double kFloatingImageDefaultWidth = 180;

/// The pinch-to-resize bounds. The floor keeps the ✕ tappable; the ceiling is
/// generous because "as big as the screen" is a legitimate thing to want.
const double kFloatingImageMinWidth = 72;
const double kFloatingImageMaxWidth = 1600;

/// A float may hang a little off the edge, but never so far that its handle
/// leaves the chat area.
const double kFloatingImageMinFraction = -0.15;
const double kFloatingImageMaxFraction = 0.95;
