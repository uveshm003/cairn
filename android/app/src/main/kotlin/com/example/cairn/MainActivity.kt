package com.example.cairn

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter app and hands it any pending quick-capture request.
 *
 * The request is *pulled* by Dart rather than pushed from here, because a push
 * can arrive before the Flutter side has a listener attached -- which is exactly
 * what happens on a cold start from the widget, the case this feature exists
 * for. Pulling means the answer waits until someone asks.
 */
class MainActivity : FlutterActivity() {

    /** Consumed once, then cleared, so a resume does not re-enter capture. */
    private var pendingQuickCapture: String? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        pendingQuickCapture = intent?.getStringExtra(QuickCapture.EXTRA)
    }

    /**
     * A tap while the app is already running. `singleTop` plus `CLEAR_TOP` routes
     * it here instead of starting a second activity.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // `setIntent` so a later getIntent() reflects reality; the pending value
        // is what Dart actually reads.
        setIntent(intent)
        intent.getStringExtra(QuickCapture.EXTRA)?.let { pendingQuickCapture = it }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumePendingCapture" -> {
                        val pending = pendingQuickCapture
                        pendingQuickCapture = null
                        result.success(pending)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private companion object {
        const val CHANNEL = "cairn/quick_capture"
    }
}
