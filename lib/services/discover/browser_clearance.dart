import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What a real browser earned by passing a bot check: the cookies it now holds
/// for a site, and the exact User-Agent that earned them.
///
/// Both halves matter. Cloudflare binds `cf_clearance` to the IP **and** the
/// User-Agent that solved the challenge, so replaying the cookie under a
/// different UA is not merely useless — it looks like a stolen cookie. They
/// travel together or not at all.
class BrowserClearance {
  BrowserClearance({
    required this.cookies,
    required this.userAgent,
    DateTime? obtainedAt,
  }) : obtainedAt = obtainedAt ?? DateTime.now();

  /// A ready-made `Cookie` header value, as the WebView would send it.
  final String cookies;

  final String userAgent;
  final DateTime obtainedAt;

  /// How long a clearance is assumed good for.
  ///
  /// Cloudflare's clearance does not slide — it expires on a fixed timer from
  /// when it was issued, commonly half an hour. This is only an optimisation to
  /// avoid a request that is certain to be refused; the real correctness comes
  /// from noticing a check and throwing the clearance away.
  static const Duration lifetime = Duration(minutes: 20);

  bool get isFresh => DateTime.now().difference(obtainedAt) < lifetime;

  /// The headers to send so a plain HTTP request looks like the browser that
  /// passed the check.
  Map<String, String> get headers => <String, String>{
        'Cookie': cookies,
        'User-Agent': userAgent,
      };

  /// Whether this actually carries a Cloudflare clearance, as opposed to some
  /// unrelated analytics cookie. Without it there is no point replaying anything.
  bool get hasClearance => cookies.contains('cf_clearance');
}

/// Clearances by host, for this run of the app only.
///
/// Deliberately never persisted. A clearance is tied to the current IP, so a
/// stored one would be wrong the moment the phone changed network, and it is a
/// credential besides.
class BrowserClearanceStore {
  final Map<String, BrowserClearance> _byHost = <String, BrowserClearance>{};

  /// `www.` is dropped so a clearance earned on one spelling is found under the
  /// other — Cloudflare sets its cookie for the whole domain.
  static String keyFor(String host) {
    final lower = host.toLowerCase();
    return lower.startsWith('www.') ? lower.substring(4) : lower;
  }

  /// The usable clearance for [host], or null. A stale one is dropped on the way
  /// out rather than being handed over.
  BrowserClearance? forHost(String host) {
    final key = keyFor(host);
    final found = _byHost[key];
    if (found == null) return null;
    if (!found.isFresh || !found.hasClearance) {
      _byHost.remove(key);
      return null;
    }
    return found;
  }

  void remember(String host, BrowserClearance clearance) {
    if (!clearance.hasClearance) return; // Nothing worth keeping.
    _byHost[keyFor(host)] = clearance;
  }

  void forget(String host) => _byHost.remove(keyFor(host));

  void clear() => _byHost.clear();

  bool get isEmpty => _byHost.isEmpty;
}

/// The app-wide store. The browser view writes to it; the sources read from it.
///
/// A library-level singleton on purpose: the platform WebView's cookie jar is
/// itself process-wide, so anything narrower would be pretending.
final BrowserClearanceStore browserClearances = BrowserClearanceStore();

const MethodChannel _cookieChannel =
    MethodChannel('me.maitavern.maichat/webview_cookies');

/// The Cookie header the platform WebView would send for [url], including the
/// HttpOnly cookies JavaScript cannot see. Null when there is nothing, or on a
/// platform without the channel.
///
/// Replaceable so tests can stand in for the platform; production never assigns
/// it.
Future<String?> Function(String url) readWebViewCookies = _readWebViewCookies;

Future<String?> _readWebViewCookies(String url) async {
  // The channel lives in MainActivity, so only Android answers it. Everywhere
  // else this simply reports nothing and the browser stays in the loop.
  if (!Platform.isAndroid) return null;
  try {
    final value = await _cookieChannel.invokeMethod<String>(
      'readCookies',
      <String, Object?>{'url': url},
    );
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  } on MissingPluginException {
    // An older build of the host app: fall back to using the browser each time.
    return null;
  } catch (error) {
    debugPrint('MaiChat: could not read WebView cookies ($error)');
    return null;
  }
}
