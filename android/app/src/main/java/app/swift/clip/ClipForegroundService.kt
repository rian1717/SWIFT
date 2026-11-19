package app.swift.clip

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps SWIFT running after the screen locks, so a copy still reaches the Mac.
 *
 * It is a "connected device" service: it keeps a link to the paired Mac. Android 15
 * gives the "data sync" type only 6 hours a day, then stops the app with
 * "SWIFT keeps stopping", and that is why clipboard used to stop after a day.
 */
class ClipForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val inFront = try {
            val text = if (ClipSync.isPaired(this)) {
                "Copies on this phone paste on your Mac with ⌘V"
            } else {
                "This phone is visible to your Mac"
            }
            val notification = notification(this, "SWIFT", text)
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(ID, notification)
            }
            true
        } catch (_: Exception) {
            // Android said no. The clipboard service keeps the app alive instead.
            false
        }
        startWork(this)
        if (!inFront) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    /** A future Android limit stops the service instead of the whole app. */
    override fun onTimeout(startId: Int) {
        stopSelf()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        start(applicationContext)
        super.onTaskRemoved(rootIntent)
    }

    companion object {
        private const val ID = 1
        private const val CHANNEL = "clipboard"

        /** Safe from anywhere: a refusal from Android never crashes the app. */
        fun start(context: Context): Boolean = try {
            context.startForegroundService(Intent(context, ClipForegroundService::class.java))
            true
        } catch (_: Exception) {
            startWork(context)
            false
        }

        fun update(context: Context, text: String) {
            try {
                context.getSystemService(NotificationManager::class.java)
                    ?.notify(ID, notification(context, "SWIFT clipboard", text))
            } catch (_: Exception) {
            }
        }

        /** Each part guards itself, so one failure cannot take the others down. */
        private fun startWork(context: Context) {
            val app = context.applicationContext
            try { Presence.start(app) } catch (_: Exception) {}
            try { PhotoWeb.start(app) } catch (_: Exception) {}
            try { ClipSync.startWatch(app) } catch (_: Exception) {}
        }

        private fun notification(context: Context, title: String, text: String): Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(
                NotificationChannel(CHANNEL, "Clipboard", NotificationManager.IMPORTANCE_LOW)
            )
            val open = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            return Notification.Builder(context, CHANNEL)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentIntent(open)
                .build()
        }
    }
}
