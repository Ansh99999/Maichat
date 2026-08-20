package me.maitavern.maichat

import android.view.ViewGroup
import android.webkit.CookieManager
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The activity adds two native channels to the default Flutter one:
 *
 *  - `webview_cookies` — reads the WebView cookie jar for Discover's Cloudflare
 *    clearance. Passing a check earns an HttpOnly `cf_clearance` cookie that the
 *    ordinary HTTP client then reuses; `document.cookie` can't see it but the
 *    platform `CookieManager` can. `webview_flutter` only exposes a writer.
 *
 *  - `float_overlay` — draws the chat's floating pictures as native Android views
 *    laid over the FlutterView. Flutter drags a picture smoothly (a pure layer
 *    move) but pinching/rotating it lags, because Flutter re-rasterises the layer
 *    on the GPU every frame it is scaled. Android's view system composites
 *    translation/scale/rotation on the GPU with no re-draw — the model that makes
 *    Agnai smooth — so the floats live here, driven from Dart.
 */
class MainActivity : FlutterActivity() {
    private var overlay: FloatOverlayView? = null
    private var floatChannel: MethodChannel? = null

    // Render Flutter into a TextureView, not the default SurfaceView. A native
    // view (the float overlay) laid over a Flutter SurfaceView pulls the whole
    // window into GPU composition — which is why even scrolling went laggy once
    // the overlay was present. A TextureView composites with sibling views the
    // normal way, so the overlay costs only itself. This is the documented mode
    // for putting Android views over Flutter.
    override fun getRenderMode(): RenderMode = RenderMode.texture

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, COOKIE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "readCookies" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("no_url", "readCookies needs a url", null)
                    } else {
                        result.success(CookieManager.getInstance().getCookie(url))
                    }
                }
                else -> result.notImplemented()
            }
        }

        val floats = MethodChannel(messenger, FLOAT_CHANNEL)
        floatChannel = floats
        floats.setMethodCallHandler { call, result ->
            when (call.method) {
                "sync" -> {
                    handleSync(call)
                    result.success(null)
                }
                "hide" -> {
                    overlay?.clearAll()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun ensureOverlay(): FloatOverlayView {
        overlay?.let { return it }
        val o = FloatOverlayView(this)
        o.callbacks = object : FloatCallbacks {
            override fun onSettle(
                key: String,
                xFrac: Double,
                yFrac: Double,
                widthDip: Double,
                rotationRad: Double,
            ) {
                runOnUiThread {
                    floatChannel?.invokeMethod(
                        "settle",
                        mapOf(
                            "key" to key,
                            "xFrac" to xFrac,
                            "yFrac" to yFrac,
                            "widthDip" to widthDip,
                            "rotationRad" to rotationRad,
                        ),
                    )
                }
            }

            override fun onDismiss(key: String) {
                runOnUiThread {
                    floatChannel?.invokeMethod("dismiss", mapOf("key" to key))
                }
            }
        }
        val content = findViewById<ViewGroup>(android.R.id.content)
        content.addView(
            o,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        overlay = o
        return o
    }

    @Suppress("UNCHECKED_CAST")
    private fun handleSync(call: MethodCall) {
        val o = ensureOverlay()
        val dpr = (call.argument<Double>("dpr") ?: 1.0).toFloat()
        val areaArg = call.argument<Map<String, Double>>("area")
        val area = AreaRect(
            (areaArg?.get("x") ?: 0.0).toFloat(),
            (areaArg?.get("y") ?: 0.0).toFloat(),
            (areaArg?.get("w") ?: 0.0).toFloat(),
            (areaArg?.get("h") ?: 0.0).toFloat(),
        )
        val floatsArg =
            call.argument<List<Map<String, Any>>>("floats") ?: emptyList()
        val specs = floatsArg.mapNotNull { m ->
            val key = m["key"] as? String ?: return@mapNotNull null
            val path = m["path"] as? String ?: return@mapNotNull null
            FloatSpec(
                key = key,
                path = path,
                xFrac = (m["xFrac"] as? Number)?.toDouble() ?: 0.5,
                yFrac = (m["yFrac"] as? Number)?.toDouble() ?: 0.5,
                widthDip = (m["widthDip"] as? Number)?.toDouble() ?: 180.0,
                rotationRad = (m["rotationRad"] as? Number)?.toDouble() ?: 0.0,
            )
        }
        o.sync(dpr, area, specs)
    }

    companion object {
        private const val COOKIE_CHANNEL = "me.maitavern.maichat/webview_cookies"
        private const val FLOAT_CHANNEL = "me.maitavern.maichat/float_overlay"
    }
}
