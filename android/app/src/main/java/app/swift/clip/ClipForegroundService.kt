package app.swift.clip

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** Keeps the process alive on Xiaomi, Samsung, and Pixel after the screen locks. */
class ClipForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val channelId = "clipboard"
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(channelId, "Clipboard", NotificationManager.IMPORTANCE_LOW)
        )
        val paired = ClipSync.isPaired(this)
        val notification = Notification.Builder(this, channelId)
            .setContentTitle("SWIFT")
            .setContentText(
                if (paired) "Copies on this phone paste on your Mac with ⌘V"
                else "This phone is visible to your Mac"
            )
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(1, notification)
        }
        Presence.start(this)
        PhotoWeb.start(this)
        ClipSync.startWatch(this)
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: android.content.Intent?) {
        try {
            applicationContext.startForegroundService(
                android.content.Intent(applicationContext, ClipForegroundService::class.java)
            )
        } catch (_: Exception) {
        }
        super.onTaskRemoved(rootIntent)
    }

    companion object {
        fun start(context: Context) {
            val intent = Intent(context, ClipForegroundService::class.java)
            context.startForegroundService(intent)
        }

        fun update(context: Context, text: String) {
            val channelId = "clipboard"
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(channelId, "Clipboard", NotificationManager.IMPORTANCE_LOW)
            )
            val notification = Notification.Builder(context, channelId)
                .setContentTitle("SWIFT clipboard")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .build()
            manager.notify(1, notification)
        }
    }
}
