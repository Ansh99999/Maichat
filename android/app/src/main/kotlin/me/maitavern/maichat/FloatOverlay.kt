package me.maitavern.maichat

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Path
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.roundToInt

// Native floating-picture overlay.
//
// Why this exists at all: dragging a picture in Flutter is smooth (a pure layer
// move) but pinching/rotating it lags, because Flutter re-rasterises the layer
// on the GPU every frame it is scaled. Android's own view system composites
// translationX/Y, scaleX/Y and rotation on the GPU WITHOUT re-drawing the view —
// exactly what a browser does with a CSS transform, and what makes Agnai smooth.
// So the floats are rendered as native Views laid over the FlutterView and driven
// from Dart over a MethodChannel.
//
// Touch: the overlay is a plain FrameLayout that is NOT clickable, so a touch
// that misses every float is not consumed and falls straight through to the
// FlutterView beneath — the chat keeps scrolling normally. A touch that lands on
// a float is hit-tested against its *transformed* bounds (Android does this for
// us) and handled by that FloatView.

/** What Flutter is told when a gesture finishes or the ✕ is tapped. */
interface FloatCallbacks {
    fun onSettle(
        key: String,
        xFrac: Double,
        yFrac: Double,
        widthDip: Double,
        rotationRad: Double,
    )

    fun onDismiss(key: String)
}

/** One float's state, as pushed from Dart. Position is the CENTRE as a fraction
 *  of the chat area; width is in logical (dip) pixels; rotation in radians. */
data class FloatSpec(
    val key: String,
    val path: String,
    val xFrac: Double,
    val yFrac: Double,
    val widthDip: Double,
    val rotationRad: Double,
)

/** The chat area the fractions are measured against, in physical pixels. */
data class AreaRect(val x: Float, val y: Float, val w: Float, val h: Float)

/** The full-window container holding the float views. Placed above the
 *  FlutterView; passes through any touch that does not hit a float. */
class FloatOverlayView(context: Context) : FrameLayout(context) {
    var dpr: Float = 1f
    var area: AreaRect = AreaRect(0f, 0f, 0f, 0f)
    var callbacks: FloatCallbacks? = null

    private val bitmaps = HashMap<String, Bitmap>()

    /** Reconcile the live views with the specs Dart just pushed. */
    fun sync(dpr: Float, area: AreaRect, specs: List<FloatSpec>) {
        this.dpr = dpr
        this.area = area
        val wanted = specs.map { it.key }.toSet()
        // Remove views (and bitmaps) for floats that are gone.
        for (i in childCount - 1 downTo 0) {
            val v = getChildAt(i) as FloatView
            if (!wanted.contains(v.key)) {
                bitmaps.remove(v.key)?.recycle()
                removeViewAt(i)
            }
        }
        // Add or update the rest, in z-order (specs are back-to-front).
        for ((index, spec) in specs.withIndex()) {
            var view = findViewByKey(spec.key)
            if (view == null) {
                val bmp = loadBitmap(spec.path) ?: continue
                bitmaps[spec.key] = bmp
                view = FloatView(context, spec.key, bmp, this)
                addView(view)
            }
            // Keep the child order matching the spec order (z-order).
            val current = indexOfChild(view)
            if (current != index && index < childCount) {
                removeViewAt(current)
                addView(view, index)
            }
            if (!view.gesturing) view.applySpec(spec)
        }
    }

    fun clearAll() {
        removeAllViews()
        for (b in bitmaps.values) b.recycle()
        bitmaps.clear()
    }

    private fun findViewByKey(key: String): FloatView? {
        for (i in 0 until childCount) {
            val v = getChildAt(i) as FloatView
            if (v.key == key) return v
        }
        return null
    }

    private fun loadBitmap(path: String): Bitmap? =
        try {
            BitmapFactory.decodeFile(path)
        } catch (_: Throwable) {
            null
        }

    // ---- Touch. Handled here, in the overlay's own (untransformed) coordinate
    // space, so the gesture maths never feeds back through the float's live
    // transform. A DOWN that misses every float returns false → it falls through
    // to the FlutterView and the chat scrolls. ----

    private var target: FloatView? = null
    private var lastFocalX = 0f
    private var lastFocalY = 0f
    private var startSpan = 0f
    private var startAngleRad = 0f
    private var startScale = 1f
    private var startRotationDeg = 0f
    private var downX = 0f
    private var downY = 0f
    private var moved = false
    private val touchSlop = (8f * resources.displayMetrics.density)

    private fun focal(e: MotionEvent): FloatArray {
        var sx = 0f
        var sy = 0f
        val n = e.pointerCount
        for (i in 0 until n) {
            sx += e.getX(i)
            sy += e.getY(i)
        }
        return floatArrayOf(sx / n, sy / n)
    }

    private fun spanAndAngle(e: MotionEvent): FloatArray {
        val dx = e.getX(1) - e.getX(0)
        val dy = e.getY(1) - e.getY(0)
        return floatArrayOf(hypot(dx, dy), atan2(dy, dx))
    }

    private fun floatAt(x: Float, y: Float): FloatView? {
        val r = Rect()
        for (i in childCount - 1 downTo 0) {
            val v = getChildAt(i) as FloatView
            v.getHitRect(r) // accounts for translation/scale (bounding box for rotation)
            if (r.contains(x.roundToInt(), y.roundToInt())) return v
        }
        return null
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val v = floatAt(e.x, e.y) ?: return false // miss → passthrough
                target = v
                v.gesturing = true
                v.bringToFront()
                downX = e.x
                downY = e.y
                moved = false
                val f = focal(e)
                lastFocalX = f[0]
                lastFocalY = f[1]
                return true
            }

            MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_POINTER_UP -> {
                val f = focal(e)
                lastFocalX = f[0]
                lastFocalY = f[1]
                val v = target
                if (v != null && e.pointerCount >= 2) {
                    val sa = spanAndAngle(e)
                    startSpan = if (sa[0] < 1f) 1f else sa[0]
                    startAngleRad = sa[1]
                    startScale = v.scaleX
                    startRotationDeg = v.rotation
                }
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                val v = target ?: return true
                val f = focal(e)
                v.translationX += f[0] - lastFocalX
                v.translationY += f[1] - lastFocalY
                lastFocalX = f[0]
                lastFocalY = f[1]
                if (e.pointerCount >= 2 && startSpan > 0f) {
                    val sa = spanAndAngle(e)
                    val scale = (startScale * (sa[0] / startSpan))
                        .coerceIn(0.2f, 8f)
                    v.scaleX = scale
                    v.scaleY = scale
                    v.rotation = startRotationDeg +
                        Math.toDegrees((sa[1] - startAngleRad).toDouble()).toFloat()
                }
                if (!moved && (hypot(f[0] - downX, f[1] - downY) > touchSlop)) {
                    moved = true
                }
                return true
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                val v = target
                target = null
                if (v == null) return true
                v.gesturing = false
                if (!moved && e.actionMasked == MotionEvent.ACTION_UP &&
                    isDismissCorner(v)
                ) {
                    callbacks?.onDismiss(v.key)
                    return true
                }
                if (moved) reportSettle(v)
                return true
            }
        }
        return true
    }

    private fun reportSettle(v: FloatView) {
        if (area.w <= 0f || area.h <= 0f) return
        val centerX = v.left + v.width / 2f + v.translationX
        val centerY = v.top + v.height / 2f + v.translationY
        val widthPx = v.width * v.scaleX
        val xFrac = ((centerX - area.x) / area.w).toDouble()
        val yFrac = ((centerY - area.y) / area.h).toDouble()
        val widthDip = (widthPx / max(1f, dpr)).toDouble()
        val rotationRad = Math.toRadians(v.rotation.toDouble())
        callbacks?.onSettle(v.key, xFrac, yFrac, widthDip, rotationRad)
    }

    /** Whether the DOWN landed in the float's top-right corner, where the ✕ is
     *  drawn. Uses the transformed bounding box, so it is exact at rest (the
     *  usual time you dismiss) and approximate when the float is rotated. */
    private fun isDismissCorner(v: FloatView): Boolean {
        val r = Rect()
        v.getHitRect(r)
        val s = 40f * dpr
        return downX >= r.right - s && downX <= r.right + s * 0.4f &&
            downY >= r.top - s * 0.4f && downY <= r.top + s
    }
}

/** A single float: a decoration-free display view. It holds no gesture logic —
 *  the overlay drives its `translationX/Y`, `scaleX/Y` and `rotation` directly,
 *  which Android composites on the GPU with no re-raster (a hardware layer),
 *  so a pinch/rotate is as smooth as dragging. It only draws the rounded bitmap
 *  and the ✕ badge. */
class FloatView(
    context: Context,
    val key: String,
    private val bitmap: Bitmap,
    private val overlay: FloatOverlayView,
) : View(context) {
    var gesturing = false

    private val bitmapPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        isFilterBitmap = true
    }
    private val badgeFill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val badgeLine = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
    }
    private val clipPath = Path()

    init {
        // A hardware layer: the bitmap rasterises once and the compositor moves,
        // scales and rotates that texture — the whole reason this is smooth.
        setLayerType(LAYER_TYPE_HARDWARE, null)
        outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, o: Outline) {
                o.setRoundRect(0, 0, view.width, view.height, 12f * overlay.dpr)
            }
        }
        elevation = 8f * overlay.dpr
        clipToOutline = false // so the ✕ badge is not clipped by the corners
    }

    /** Lay out at the float's resting centre/size/rotation and clear any live
     *  transform. Skipped while [gesturing] (the overlay guards that). */
    fun applySpec(spec: FloatSpec) {
        val d = overlay.dpr
        val area = overlay.area
        val wPx = (spec.widthDip * d).toFloat()
        val aspect = if (bitmap.width > 0) {
            bitmap.height.toFloat() / bitmap.width
        } else {
            0.75f
        }
        val hPx = wPx * aspect
        val cx = area.x + spec.xFrac.toFloat() * area.w
        val cy = area.y + spec.yFrac.toFloat() * area.h
        val lp = (layoutParams as? FrameLayout.LayoutParams)
            ?: FrameLayout.LayoutParams(0, 0)
        lp.width = wPx.roundToInt().coerceAtLeast(1)
        lp.height = hPx.roundToInt().coerceAtLeast(1)
        lp.leftMargin = (cx - wPx / 2f).roundToInt()
        lp.topMargin = (cy - hPx / 2f).roundToInt()
        layoutParams = lp
        translationX = 0f
        translationY = 0f
        scaleX = 1f
        scaleY = 1f
        rotation = Math.toDegrees(spec.rotationRad).toFloat()
    }

    override fun onSizeChanged(w: Int, h: Int, ow: Int, oh: Int) {
        pivotX = w / 2f
        pivotY = h / 2f
        invalidateOutline()
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) return
        val r = 12f * overlay.dpr
        val save = canvas.save()
        clipPath.reset()
        clipPath.addRoundRect(0f, 0f, w, h, r, r, Path.Direction.CW)
        canvas.clipPath(clipPath)
        canvas.drawBitmap(bitmap, null, RectF(0f, 0f, w, h), bitmapPaint)
        canvas.restoreToCount(save)
        drawDismiss(canvas, w)
    }

    private fun drawDismiss(canvas: Canvas, w: Float) {
        val d = overlay.dpr
        val radius = 11f * d
        val cx = w - radius - 2f * d
        val cy = radius + 2f * d
        badgeFill.color = Color.argb(230, 20, 20, 20)
        canvas.drawCircle(cx, cy, radius, badgeFill)
        val arm = 4.5f * d
        badgeLine.strokeWidth = 2f * d
        canvas.drawLine(cx - arm, cy - arm, cx + arm, cy + arm, badgeLine)
        canvas.drawLine(cx - arm, cy + arm, cx + arm, cy - arm, badgeLine)
    }
}


