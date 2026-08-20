package me.maitavern.maichat

import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Adds one thing to the default activity: a way to read the WebView's cookie
 * jar from Dart.
 *
 * Discover needs it for exactly one job. Passing a Cloudflare check earns a
 * `cf_clearance` cookie, and that cookie is what lets the ordinary HTTP client
 * fetch pages afterwards without a browser in the loop. The cookie is HttpOnly,
 * so `document.cookie` inside the WebView cannot see it — but the platform's own
 * `CookieManager` can, because HttpOnly restricts scripts, not the native store.
 *
 * `webview_flutter` only exposes a cookie *writer*, hence this channel rather
 * than another plugin. Read-only, and only for a URL Dart names.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readCookies" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.error("no_url", "readCookies needs a url", null)
                        } else {
                            // The Cookie header the WebView would send for this
                            // URL, or null when it holds nothing for it.
                            result.success(CookieManager.getInstance().getCookie(url))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val CHANNEL = "me.maitavern.maichat/webview_cookies"
    }
}
