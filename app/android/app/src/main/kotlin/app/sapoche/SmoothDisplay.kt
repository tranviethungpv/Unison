package app.sapoche

import android.app.Activity
import android.os.Build
import android.view.Surface
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterSurfaceView

/**
 * Asks Android for the display's fastest refresh rate while someone moves the screen. A Flutter app does not ask for
 * anything, so from Android 15 on the system gives it its "normal" rate (60 Hz on a phone that can do 120) as soon as a
 * finger lets go, and the sheet that settles after a drag, a fling or a page change is shown at half of what the
 * display can do. The UI tells which pace the screen moves at ([pace]); when it is still, the request is taken
 * back so that a still screen does not hold the display at any rate.
 *
 * What moves by itself (a scrolling title, a drifting background) asks for 60 Hz on the app's own surface: left to
 * choose, a phone can show it at 120 Hz, as the Sharp does, which draws twice the frames for the same movement. The
 * surface of a video is left to the system then, which matches it to the film.
 */
class SmoothDisplay(private val activity: Activity) {

    /** As the UI names them: "free", "steady" or "fast". */
    private var pace = "free"

    /** The fastest rate of the display's modes that keep the screen's size. */
    private val fastest: Float
        get() {
            val display = activity.display ?: return 0f
            val mode = display.mode
            return display.supportedModes
                .filter { it.physicalWidth == mode.physicalWidth && it.physicalHeight == mode.physicalHeight }
                .maxOfOrNull { it.refreshRate } ?: mode.refreshRate
        }

    /** The display's normal rate: the fastest of its modes up to 60 Hz that keep the screen's size. */
    private val normal: Float
        get() {
            val display = activity.display ?: return 0f
            val mode = display.mode
            return display.supportedModes
                .filter { it.physicalWidth == mode.physicalWidth && it.physicalHeight == mode.physicalHeight }
                .map { it.refreshRate }
                .filter { it <= 61f }
                .maxOrNull() ?: 0f
        }

    fun pace(wanted: String) {
        if (wanted == pace) return
        pace = wanted
        apply()
    }

    /** The surface can be made again (the app came back to the front), and the request has to be made on the new one. */
    fun reapply() {
        if (pace != "free") apply()
    }

    private fun apply() {
        if (Build.VERSION.SDK_INT >= 30) {
            surfaces(activity.window.decorView).forEach { (surface, app) ->
                val rate = when (pace) {
                    "fast" -> fastest
                    "steady" -> if (app) normal else 0f
                    else -> 0f
                }
                if (surface.isValid) {
                    // 0 takes the request back; the system then decides by itself again
                    if (Build.VERSION.SDK_INT >= 31) {
                        surface.setFrameRate(rate, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT, Surface.CHANGE_FRAME_RATE_ALWAYS)
                    } else {
                        surface.setFrameRate(rate, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
                    }
                }
            }
        } else {
            // Before Android 11 the only way is a preference of the window, which has the video in it too
            val attributes = activity.window.attributes
            attributes.preferredRefreshRate = if (pace == "fast") fastest else 0f
            activity.window.attributes = attributes
        }
        EventLog.d("display", "pace $pace")
    }

    /** Every surface of the screen, and whether it is the one Flutter draws on: the video picture is another. */
    private fun surfaces(view: View): List<Pair<Surface, Boolean>> = when (view) {
        is SurfaceView -> listOf(view.holder.surface to (view is FlutterSurfaceView))
        is ViewGroup -> (0 until view.childCount).flatMap { surfaces(view.getChildAt(it)) }
        else -> emptyList()
    }
}
