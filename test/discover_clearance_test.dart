import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/discover/browser_clearance.dart';

/// The point of a clearance is to take the browser back out of the loop: pass
/// Cloudflare's check once in a WebView, then keep fetching pages with a plain
/// HTTP client wearing the same credentials. That only works if the cookie and
/// the User-Agent travel together and a stale one is thrown away, so both are
/// pinned here.
void main() {
  setUp(browserClearances.clear);

  BrowserClearance cleared({
    String cookies = 'cf_clearance=abc123; other=1',
    String userAgent = 'Mozilla/5.0 (Linux; Android 14; Pixel) Chrome/124',
    DateTime? obtainedAt,
  }) =>
      BrowserClearance(
        cookies: cookies,
        userAgent: userAgent,
        obtainedAt: obtainedAt,
      );

  test('a clearance travels as a cookie and the UA that earned it', () {
    final clearance = cleared();
    expect(clearance.headers, <String, String>{
      'Cookie': 'cf_clearance=abc123; other=1',
      // Cloudflare binds the clearance to the User-Agent, so replaying the
      // cookie under a different one is worse than not replaying it.
      'User-Agent': 'Mozilla/5.0 (Linux; Android 14; Pixel) Chrome/124',
    });
    expect(clearance.hasClearance, isTrue);
    expect(clearance.isFresh, isTrue);
  });

  test('cookies without a clearance in them are not worth keeping', () {
    final useless = cleared(cookies: 'analytics=1; session=2');
    expect(useless.hasClearance, isFalse);
    browserClearances.remember('jannyai.com', useless);
    expect(browserClearances.forHost('jannyai.com'), isNull);
    expect(browserClearances.isEmpty, isTrue);
  });

  test('a clearance is found again under the host that earned it', () {
    browserClearances.remember('jannyai.com', cleared());
    expect(browserClearances.forHost('jannyai.com'), isNotNull);
  });

  test('www is not a different site', () {
    // Cloudflare sets its cookie for the whole domain, so a clearance earned on
    // one spelling has to be found under the other.
    browserClearances.remember('www.jannyai.com', cleared());
    expect(browserClearances.forHost('jannyai.com'), isNotNull);
    expect(browserClearances.forHost('WWW.JannyAI.com'), isNotNull);
    expect(BrowserClearanceStore.keyFor('www.Example.COM'), 'example.com');
  });

  test('another site does not get to use it', () {
    browserClearances.remember('jannyai.com', cleared());
    expect(browserClearances.forHost('chub.ai'), isNull);
  });

  test('a clearance past its life is dropped rather than replayed', () {
    // It does not slide: it expires on a fixed timer from when it was issued.
    browserClearances.remember(
      'jannyai.com',
      cleared(
        obtainedAt: DateTime.now().subtract(BrowserClearance.lifetime * 2),
      ),
    );
    expect(browserClearances.forHost('jannyai.com'), isNull);
    // And it is not merely hidden — it is gone.
    expect(browserClearances.isEmpty, isTrue);
  });

  test('one right at the edge of its life is still used', () {
    browserClearances.remember(
      'jannyai.com',
      cleared(
        obtainedAt: DateTime.now()
            .subtract(BrowserClearance.lifetime - const Duration(minutes: 1)),
      ),
    );
    expect(browserClearances.forHost('jannyai.com'), isNotNull);
  });

  test('forgetting one leaves the others alone', () {
    browserClearances
      ..remember('jannyai.com', cleared())
      ..remember('example.com', cleared());
    browserClearances.forget('jannyai.com');
    expect(browserClearances.forHost('jannyai.com'), isNull);
    expect(browserClearances.forHost('example.com'), isNotNull);
  });
}
