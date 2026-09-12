package com.example.cairn

import android.content.Context
import android.content.Intent

/**
 * The contract shared by the home-screen widget, the quick-settings tile, and
 * the Flutter side.
 *
 * Principle #4 in requirements.md is "cold-start to recording in <=2 taps". The
 * in-app path already meets that (FAB, then record). These entry points exist to
 * beat it: from the home screen or the notification shade, recording is one tap.
 *
 * Deliberately implemented with a plain AppWidgetProvider and TileService rather
 * than a plugin. A launcher widget needs no Flutter rendering, and adding a
 * package for it would mean auditing another AAR's manifest against the
 * four-permission promise for no gain.
 */
object QuickCapture {
    /** Extra carried on the launch intent. Values below. */
    const val EXTRA = "cairn.quick_capture"

    /** Open capture on the remembered medium -- what the tile does. */
    const val ANY = "any"
    const val AUDIO = "audio"
    const val VIDEO = "video"

    /**
     * An intent that opens the app straight into capture.
     *
     * `CLEAR_TOP` plus MainActivity's `singleTop` launch mode means a tap while
     * the app is already open reuses the existing activity and arrives through
     * `onNewIntent`, rather than stacking a second copy of the app.
     */
    fun launchIntent(context: Context, medium: String): Intent =
        Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA, medium)
        }
}
