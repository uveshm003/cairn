package com.example.cairn

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.os.Build
import android.service.quicksettings.TileService

/**
 * Quick-settings tile: one tap from the notification shade into capture.
 *
 * This is the fastest path the platform offers -- the shade is reachable from
 * the lock screen and from inside other apps, which is exactly the situation
 * S3's "leave myself a 30-second spoken note" describes.
 *
 * The tile opens on the *remembered* medium rather than choosing one. A tile has
 * room for one action, and overriding the user's last choice would be a
 * surprise.
 */
class QuickRecordTileService : TileService() {

    @SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        super.onClick()
        val intent = QuickCapture.launchIntent(this, QuickCapture.ANY)

        // Android 14 stopped honouring the Intent overload from the shade and
        // requires a PendingIntent; older releases only have the Intent form.
        // Both overloads exist at compile time, so this is a runtime branch.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(
                    this,
                    0,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
