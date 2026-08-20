import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/floating_image.dart';
import '../services/avatar_store.dart';
import '../services/float_overlay_channel.dart';
import '../state/app_state.dart';
import 'avatar_image.dart' show avatarIsUrl;

/// Drives the **native Android** floating-picture overlay (see
/// [FloatOverlayChannel]). This widget draws nothing itself — it is an
/// invisible, screen-filling box whose only jobs are:
///  * measure the chat area's rect (so native can place floats by fraction),
///  * push the current floats to native whenever they, or the area, change,
///  * turn native's settle/dismiss callbacks back into [AppState] writes.
///
/// It is mounted only where [floatOverlaySupported] (Android); every other
/// platform uses the Flutter `FloatingImagesLayer`.
class NativeFloatingImages extends StatefulWidget {
  const NativeFloatingImages({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<NativeFloatingImages> createState() => _NativeFloatingImagesState();
}

class _NativeFloatingImagesState extends State<NativeFloatingImages>
    with WidgetsBindingObserver {
  final GlobalKey _areaKey = GlobalKey();
  FloatOverlayChannel? _channel;
  final Map<String, String> _pathCache = <String, String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel = FloatOverlayChannel(
      onSettle: _onSettle,
      onDismiss: _onDismiss,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _channel?.hide();
    _channel?.dispose();
    super.dispose();
  }

  /// Keyboard, rotation or a bar appearing all move the chat area — re-push so
  /// native repositions the floats to match.
  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _push());
  }

  FloatingImage? _floatByKey(String key) {
    final conversation =
        context.read<AppState>().conversationById(widget.conversationId);
    if (conversation == null) return null;
    for (final float in conversation.floatingImages) {
      if (float.key == key) return float;
    }
    return null;
  }

  void _onSettle(
    String key,
    double xFrac,
    double yFrac,
    double widthDip,
    double rotationRad,
  ) {
    final float = _floatByKey(key);
    if (float == null) return;
    context.read<AppState>().settleFloatingImage(
          widget.conversationId,
          float,
          x: xFrac,
          y: yFrac,
          width: widthDip,
          rotation: rotationRad,
          raise: true,
        );
    // Re-push so native re-lays-out at the settled base with an identity
    // transform (a settle does not change the float *keys*, so the build-driven
    // push would not fire on its own).
    _push();
  }

  void _onDismiss(String key) {
    final float = _floatByKey(key);
    if (float != null) {
      context.read<AppState>().unfloatImage(widget.conversationId, float);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when the set of floats changes (same string trick the Flutter
    // layer uses: a joined key string, not the list, so streaming replies don't
    // rebuild us). Each rebuild schedules a push after layout.
    context.select<AppState, String>(
      (state) => state
          .floatingImagesFor(state.conversationById(widget.conversationId))
          .map((f) => f.float.key)
          .join(' '),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _push());
    return SizedBox.expand(key: _areaKey);
  }

  /// Measures the chat area and pushes the current floats to native. Called
  /// after layout, on metrics changes, and after a settle.
  Future<void> _push() async {
    if (!mounted) return;
    final state = context.read<AppState>();
    final floats =
        state.floatingImagesFor(state.conversationById(widget.conversationId));
    if (floats.isEmpty) {
      await _channel?.hide();
      return;
    }
    final box = _areaKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    final size = box.size;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final areaPx = <String, double>{
      'x': origin.dx * dpr,
      'y': origin.dy * dpr,
      'w': size.width * dpr,
      'h': size.height * dpr,
    };

    final specs = <FloatOverlaySpec>[];
    for (final f in floats) {
      final path = await _resolvePath(f.ref);
      if (path == null) continue; // e.g. an http-only ref (unsupported in v1)
      specs.add(FloatOverlaySpec(
        key: f.float.key,
        path: path,
        xFrac: f.float.x,
        yFrac: f.float.y,
        widthDip: f.float.width,
        rotationRad: f.float.rotation,
      ));
    }
    if (!mounted) return;
    await _channel?.sync(areaPx: areaPx, dpr: dpr, floats: specs);
  }

  /// Resolves a picture reference to an on-disk file the native side can decode.
  /// Local pictures already are files; legacy base64 is written to a cache file
  /// once. `http(s)` URLs are not supported by the native overlay yet.
  Future<String?> _resolvePath(String ref) async {
    final cached = _pathCache[ref];
    if (cached != null) return cached;
    final trimmed = ref.trim();

    final file = avatarRefFile(trimmed);
    if (file != null && file.existsSync()) {
      _pathCache[ref] = file.path;
      return file.path;
    }

    if (!avatarIsUrl(trimmed) && !avatarIsLocal(trimmed)) {
      try {
        final bytes = base64Decode(trimmed);
        final dir = Directory('${Directory.systemTemp.path}/maichat_floats');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final path = '${dir.path}/${trimmed.hashCode}.img';
        final out = File(path);
        if (!out.existsSync()) out.writeAsBytesSync(bytes);
        _pathCache[ref] = path;
        return path;
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}

