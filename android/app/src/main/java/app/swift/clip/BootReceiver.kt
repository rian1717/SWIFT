package app.swift.clip

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Brings the clipboard watcher back after the phone restarts. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (!ClipSync.isPaired(context)) return
        ClipForegroundService.start(context)
    }
}
