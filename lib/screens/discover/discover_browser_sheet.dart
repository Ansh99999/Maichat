import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/discover/browser_clearance.dart';
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
typedef BrowserViewSolver = Future<String?> Function(
  BuildContext context, {
  required String url,
  required String siteLabel,
});

/// Opens [url] in a real browsing context and returns the page's HTML once it
/// stops being a bot check, or null if the user backed out or nothing usable
/// arrived.
///
/// This exists for one reason: a Cloudflare challenge is a JavaScript
/// computation plus a browser fingerprint check, and no amount of header-dressing
/// gets a plain HTTP client past it. The device's own WebView is a genuine
/// Chromium, so it simply passes — and then the page it is holding is the page we
/// wanted.
///
/// Replaceable because a widget test has no WebView to drive; production never
/// assigns it.
BrowserViewSolver solveInBrowserView = _openBrowserView;

Future<String?> _openBrowserView(
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
  Timer? _reveal;
  bool _done = false;
  bool _revealed = false;
  int _progress = 0;
  String _status = 'Checking…';

  /// A challenge replaces the page contents without a navigation event, so the
  /// page is re-read on a timer as well as on page-finished.
  static const Duration _pollEvery = Duration(milliseconds: 700);

  /// How long the page stays behind its cover. A non-interactive check clears
  /// well inside this, and covering it means the common case reads as the app
  /// doing something rather than a foreign page flashing past. Past this, the
  /// check probably wants tapping, so hand it over.
  static const Duration _revealAfter = Duration(seconds: 6);

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
    _reveal = Timer(_revealAfter, () {
      if (mounted && !_done) {
        setState(() {
          _revealed = true;
          _status = 'This check wants you to complete it.';
        });
      }
    });
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
    _reveal?.cancel();
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
        setState(() => _revealed
            ? _status = looksLikeChallenge(html)
                ? 'Still being checked.'
                : 'Waiting for the page…'
            : _status = 'Checking…');
        return;
      }
    }
    _done = true;
    _poll?.cancel();
    // Take the clearance with us. This is the whole point of having done it in a
    // browser: the cookie it earned lets the ordinary HTTP client fetch the next
    // character without a browser at all.
    await _rememberClearance();
    if (!mounted) return;
    Navigator.of(context).pop(html);
  }

  /// Stores the cookies and User-Agent this browsing context now has for the
  /// site, so plain requests can present the same credentials.
  Future<void> _rememberClearance() async {
    final host = Uri.tryParse(widget.url)?.host;
    if (host == null || host.isEmpty) return;
    final cookies = await readWebViewCookies(widget.url);
    if (cookies == null) return;
    // The UA has to be the one this WebView actually sent, not a guess —
    // Cloudflare ties the clearance to it.
    String? userAgent;
    try {
      userAgent = _unwrap(
        await _controller.runJavaScriptReturningResult('navigator.userAgent'),
      );
    } catch (_) {
      return;
    }
    if (userAgent == null || userAgent.isEmpty) return;
    browserClearances.remember(
      host,
      BrowserClearance(cookies: cookies, userAgent: userAgent),
    );
  }

  /// The current document, unwrapped from the JSON string Android hands back.
  Future<String?> _html() async {
    try {
      return _unwrap(await _controller
          .runJavaScriptReturningResult('document.documentElement.outerHTML'));
    } catch (_) {
      // Mid-navigation the controller can refuse; the next poll will retry.
      return null;
    }
  }

  /// A JavaScript result as a Dart string. Android returns it JSON-encoded, iOS
  /// returns it bare.
  String? _unwrap(Object? result) {
    final raw = result is String ? result : '$result';
    if (raw.isEmpty) return null;
    if (raw.startsWith('"')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is String) return decoded;
      } catch (_) {
        // Not JSON after all; use it as it came.
      }
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Checking with ${widget.siteLabel}'),
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (!_revealed)
            TextButton(
              onPressed: () => setState(() => _revealed = true),
              child: const Text('Show page'),
            ),
          if (_revealed)
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
      // The page is laid out full size and fully opaque underneath, so it
      // renders and runs exactly as a real page does — a check that is measuring
      // the browser gets a browser. The cover on top is only what the user sees.
      body: Stack(
        fit: StackFit.expand,
        children: [
          WebViewWidget(controller: _controller),
          if (!_revealed)
            ColoredBox(
              color: scheme.surface,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(36),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.shield_outlined,
                          size: 44, color: scheme.onSurfaceVariant),
                      const SizedBox(height: 20),
                      Text(
                        '${widget.siteLabel} is checking the browser',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This takes a second, and then the character loads. '
                        'It only needs doing once in a while.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 24),
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: _revealed
          ? Container(
              width: double.infinity,
              color: scheme.surfaceContainerHighest,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: SafeArea(
                top: false,
                child: Text(
                  _status,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            )
          : null,
    );
  }
}
