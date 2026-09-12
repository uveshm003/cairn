package com.example.cairn

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews

/**
 * Home-screen widget: two targets, audio and video, each opening capture
 * directly.
 *
 * Static RemoteViews rather than a rendered Flutter surface. The widget shows no
 * library data, so there is nothing to keep in sync and nothing to update -- it
 * is a pair of buttons, and treating it as anything more would mean waking the
 * app up to redraw a picture of two buttons.
 */
class QuickRecordWidget : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        widgetIds: IntArray,
    ) {
        for (id in widgetIds) {
            val views = RemoteViews(context.packageName, R.layout.quick_record_widget)
            views.setOnClickPendingIntent(
                R.id.quick_record_audio,
                pendingIntent(context, QuickCapture.AUDIO, requestCode = 1),
            )
            views.setOnClickPendingIntent(
                R.id.quick_record_video,
                pendingIntent(context, QuickCapture.VIDEO, requestCode = 2),
            )
            manager.updateAppWidget(id, views)
        }
    }

    /**
     * Distinct request codes per medium.
     *
     * With the same code, the second `getActivity` call would return the first
     * intent and both buttons would open the same medium -- PendingIntent
     * equality ignores extras.
     */
    private fun pendingIntent(context: Context, medium: String, requestCode: Int) =
        PendingIntent.getActivity(
            context,
            requestCode,
            QuickCapture.launchIntent(context, medium),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
}
