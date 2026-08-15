import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/discover/janny_page.dart';

/// Whether this platform has a WebView implementation at all. The desktop
/// builds do not, so every caller has to ask before offering the route.
///
/// Mutable because a widget test needs to drive the offer-a-browser-view path on
/// a host that has no WebView. Production never assigns it.
bool webViewSupported = Platform.isAndroid || Platform.isIOS;

/// Opens [url] in a real browsing context and returns the page's HTML once it
/// stops being a bot check, or null if the user backed out or nothing usable
/// arrived.
///
/// This exists for one reason: a Cloudflare challenge is a JavaScript
/// computation plus a browser fingerprint check, and no amount of header-dressing
/// gets a plain HTTP client past it. The device's own WebView is a genuine
/// Chromium, so it simply passes — and then the page it is holding is the page we
/// wanted. The user sees the check happen rather than it being done behind their
/// back.
Future<String?> solveInBrowserView(
  BuildContext context, {
  required String url,
  required String siteLabel,
}) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => _BrowserViewScreen(url: url, siteLabel: siteLabel),
      ),
    );

class _BrowserViewScreen extends StatefulWidget {
  const _BrowserViewScreen({required this.url, required this.siteLabel});

  final String url;
  final String siteLabel;

  @override
  State<_BrowserViewScreen> createState() => _BrowserViewScreenState();
}

class _BrowserViewScreenState extends State<_BrowserViewScreen> {
  late final WebViewController _controller;
  Timer? _poll;
  bool _done = false;
  int _progress = 0;
  String _status = 'Loading…';

  /// A challenge replaces the page contents without a navigation event, so the
  /// page is re-read on a timer as well as on page-finished.
  static const Duration _pollEvery = Duration(milliseconds: 1200);
  static const Duration _giveUpAfter = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      // The challenge is JavaScript; without this it can never complete.
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (value) => setState(() => _progress = value),
        onPageFinished: (_) => _check(),
        onWebResourceError: (error) =>
            setState(() => _status = error.description),
      ))
      ..loadRequest(Uri.parse(widget.url));

    _poll = Timer.periodic(_pollEvery, (_) => _check());
    Timer(_giveUpAfter, () {
      if (mounted && !_done) {
        setState(() => _status =
            'Still being checked. You can wait, or tap Use this page.');
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Reads the live document and finishes as soon as it is the real page.
  Future<void> _check({bool force = false}) async {
    if (_done) return;
    final html = await _html();
    if (!mounted || _done) return;
    if (html == null) return;
    if (!force) {
      if (looksLikeChallenge(html) || !looksLikeCharacterPage(html)) {
        setState(() => _status = looksLikeChallenge(html)
            ? 'Passing the site\'s bot check…'
            : 'Waiting for the page…');
        return;
      }
    }
    _done = true;
    _poll?.cancel();
    Navigator.of(context).pop(html);
  }

  /// The current document, unwrapped from the JSON string Android hands back.
  Future<String?> _html() async {
    try {
      final result = await _controller
          .runJavaScriptReturningResult('document.documentElement.outerHTML');
      final raw = result is String ? result : '$result';
      if (raw.isEmpty) return null;
      if (raw.startsWith('"')) {
        final decoded = jsonDecode(raw);
        return decoded is String ? decoded : raw;
      }
      return raw;
    } catch (_) {
      // Mid-navigation the controller can refuse; the next poll will retry.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Opening ${widget.siteLabel}'),
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: () => _check(force: true),
            child: const Text('Use this page'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: _progress >= 100
              ? const SizedBox(height: 4)
              : LinearProgressIndicator(
                  value: _progress / 100,
                  minHeight: 4,
                ),
        ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: scheme.surfaceContainerHighest,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Text(
              _status,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
