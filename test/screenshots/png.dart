// Part of the screenshot generator (see developer notes/screenshots.md). Not a
// test: nothing here ends in `_test.dart`, so `flutter test` never collects it.
//
// A minimal PNG writer plus the procedural art the demo world wears. The app
// draws a character's picture from real bytes, so a screenshot needs bytes —
// and shipping stock art in the repo would mean shipping somebody's licence
// with it. These gradients are generated from nothing but arithmetic.
import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

/// CRC-32 (the PNG flavour), table built once.
final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

List<int> _chunk(String type, List<int> data) {
  final head = ascii.encode(type);
  final length = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, _crc32(<int>[...head, ...data]));
  return <int>[
    ...length.buffer.asUint8List(),
    ...head,
    ...data,
    ...crc.buffer.asUint8List(),
  ];
}

/// Encodes [rgb] (3 bytes per pixel, row-major) as an 8-bit truecolour PNG.
Uint8List encodePngRgb(int width, int height, Uint8List rgb) {
  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 2) // colour type: truecolour
    ..setUint8(10, 0) // deflate
    ..setUint8(11, 0) // adaptive filtering
    ..setUint8(12, 0); // no interlace
  // One filter byte (0 = None) in front of every scanline.
  final raw = Uint8List(height * (1 + width * 3));
  var out = 0;
  for (var y = 0; y < height; y++) {
    raw[out++] = 0;
    raw.setRange(out, out + width * 3, rgb, y * width * 3);
    out += width * 3;
  }
  return Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ..._chunk('IHDR', ihdr.buffer.asUint8List()),
    ..._chunk('IDAT', ZLibCodec(level: 6).encode(raw)),
    ..._chunk('IEND', const <int>[]),
  ]);
}

/// HSV → RGB, written out rather than borrowed from `HSVColor` so this file
/// stays independent of Flutter's colour API.
void _hsv(double h, double s, double v, Uint8List into, int at) {
  final hh = (h % 360) / 60.0;
  final c = v * s;
  final x = c * (1 - (hh % 2 - 1).abs());
  final m = v - c;
  final (double r, double g, double b) = switch (hh.floor()) {
    0 => (c, x, 0.0),
    1 => (x, c, 0.0),
    2 => (0.0, c, x),
    3 => (0.0, x, c),
    4 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  into[at] = ((r + m) * 255).round().clamp(0, 255);
  into[at + 1] = ((g + m) * 255).round().clamp(0, 255);
  into[at + 2] = ((b + m) * 255).round().clamp(0, 255);
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// A soft two-tone gradient with an off-centre highlight: abstract enough to be
/// honest about being a stand-in, warm enough that a populated screen doesn't
/// look broken. [hue] picks the family; the second tone is derived from it, so
/// one number gives one distinguishable picture.
Uint8List demoArt({
  required int width,
  required int height,
  required double hue,
  double spread = 46,
  double light = 0.86,
}) {
  final rgb = Uint8List(width * height * 3);
  final cx = width * 0.34;
  final cy = height * 0.28;
  final reach = 0.72 * (width < height ? height : width);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      // Diagonal ramp, weighted so the light corner reads as top-left.
      final t = (x / width * 0.55 + y / height * 0.45).clamp(0.0, 1.0);
      final dx = (x - cx) / reach;
      final dy = (y - cy) / reach;
      final glow = (1 - (dx * dx + dy * dy)).clamp(0.0, 1.0);
      // Edges fall away so a circular avatar crop keeps a soft rim.
      final ex = (x / width - 0.5).abs() * 2;
      final ey = (y / height - 0.5).abs() * 2;
      final edge = (ex > ey ? ex : ey);
      final value = (_lerp(0.30, light, t) + 0.12 * glow * glow - 0.14 * edge * edge)
          .clamp(0.04, 1.0);
      _hsv(
        hue + spread * t,
        _lerp(0.62, 0.30, t),
        value,
        rgb,
        (y * width + x) * 3,
      );
    }
  }
  return encodePngRgb(width, height, rgb);
}

/// The same picture as the app stores a legacy avatar: base64, no file needed.
/// `avatarImage` decodes that shape straight into a `MemoryImage`, which is what
/// keeps the generator off the filesystem.
String demoArtBase64({
  required int size,
  required double hue,
  int? height,
}) =>
    base64Encode(demoArt(width: size, height: height ?? size, hue: hue));

