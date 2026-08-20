import 'dart:io';

import 'package:flutter/services.dart';

/// The picture floats are drawn by a **native Android** overlay, not by Flutter,
/// because Android composites view transforms (translate/scale/rotate) on the
/// GPU without re-rasterising — so a pinch is buttery, which Flutter's own layer
/// cannot guarantee. This is the Dart end of the `float_overlay` MethodChannel.
/// Only Android has the native side; everywhere else the Flutter
/// `FloatingImagesLayer` is used instead.
bool get floatOverlaySupported => Platform.isAndroid;

/// Geometry of one float sent to native. Position is the **centre** as a
/// fraction of the chat area; width in logical (dip) pixels; rotation in radians.
class FloatOverlaySpec {
  const FloatOverlaySpec({
    required this.key,
    required this.path,
    required this.xFrac,
    required this.yFrac,
    required this.widthDip,
    required this.rotationRad,
  });

  final String key;
  final String path;
  final double xFrac;
  final double yFrac;
  final double widthDip;
  final double rotationRad;

  Map<String, Object> toMap() => <String, Object>{
        'key': key,
        'path': path,
        'xFrac': xFrac,
        'yFrac': yFrac,
        'widthDip': widthDip,
        'rotationRad': rotationRad,
      };
}

/// Thin typed wrapper over the platform channel. Dart pushes [sync]/[hide];
/// native calls back with `settle` (a manipulation finished) and `dismiss` (the
/// ✕ was tapped), routed to the callbacks.
class FloatOverlayChannel {
  FloatOverlayChannel({required this.onSettle, required this.onDismiss}) {
    _channel.setMethodCallHandler(_handle);
  }

  /// (key, xFrac, yFrac, widthDip, rotationRad) once the fingers leave.
  final void Function(String, double, double, double, double) onSettle;
  final void Function(String key) onDismiss;

  final MethodChannel _channel =
      const MethodChannel('me.maitavern.maichat/float_overlay');

  Future<void> sync({
    required Map<String, double> areaPx,
    required double dpr,
    required List<FloatOverlaySpec> floats,
  }) =>
      _channel.invokeMethod<void>('sync', <String, Object>{
        'area': areaPx,
        'dpr': dpr,
        'floats': floats.map((f) => f.toMap()).toList(),
      });

  Future<void> hide() => _channel.invokeMethod<void>('hide');

  Future<dynamic> _handle(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
    switch (call.method) {
      case 'settle':
        onSettle(
          args['key'] as String,
          (args['xFrac'] as num).toDouble(),
          (args['yFrac'] as num).toDouble(),
          (args['widthDip'] as num).toDouble(),
          (args['rotationRad'] as num).toDouble(),
        );
      case 'dismiss':
        onDismiss(args['key'] as String);
    }
    return null;
  }

  void dispose() => _channel.setMethodCallHandler(null);
}
