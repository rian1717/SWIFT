package app.swift.clip

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * What the person sees when something is sent to this phone.
 *
 * It follows the AirDrop pattern: a pop-up appears the moment a file starts
 * arriving, the same notification turns into "Received" when it is done, a photo
 * shows a preview, tapping it opens the file, and two buttons act on the file:
 * Open and Share.
 */
object TransferAlerts {
    private const val CHANNEL = "transfers"
    private val ids = AtomicInteger(100)
    /** One notification per file name, so "Receiving" is replaced by "Received". */
    private val byName = ConcurrentHashMap<String, Int>()

    /**
     * Asks before anything is saved, with the PIN to compare against the sender's
     * screen. Returns how to take the question away if the sender gives up first.
     */
    fun ask(context: Context, offer: IncomingOffer, answer: (Boolean) -> Unit): () -> Unit {
        val manager = context.getSystemService(NotificationManager::class.java)
        // With no way to ask, the answer is no.
        if (manager == null || !manager.areNotificationsEnabled()) {
            answer(false)
            return {}
        }
        val id = ids.incrementAndGet()
        val token = TransferConsent.open { accepted ->
            manager.cancel(id)
            answer(accepted)
        }
        if (token == null) {
            answer(false)
            return {}
        }
        val size = android.text.format.Formatter.formatShortFileSize(context, offer.totalBytes)
        val builder = base(context, id)
            .setContentTitle("PIN ${offer.pin} · ${offer.sender}")
            .setContentText("Wants to send ${offer.summary} ($size)")
            .setStyle(
                Notification.BigTextStyle().bigText(
                    "Wants to send ${offer.summary} ($size).\nAccept only if ${offer.pin} is on the sender's screen."
                )
            )
            .setOngoing(true)
            .setAutoCancel(false)
            .setTimeoutAfter(TransferConsent.TIMEOUT_MS)
            .addAction(action(context, "Decline", decision(context, id * 4 + 1, token, false)))
            .addAction(action(context, "Accept", decision(context, id * 4 + 2, token, true)))
        post(context, id, builder)
        return {
            TransferConsent.close(token)
            manager.cancel(id)
        }
    }

    private fun decision(context: Context, code: Int, token: String, accepted: Boolean): PendingIntent {
        val intent = Intent(context, ConsentReceiver::class.java).apply {
            putExtra(ConsentReceiver.TOKEN, token)
            putExtra(ConsentReceiver.ACCEPTED, accepted)
        }
        return PendingIntent.getBroadcast(context, code, intent, FLAGS)
    }

    /** A file has started arriving. Pops up at once, with a busy bar. */
    fun receiving(context: Context, name: String) {
        val builder = base(context, id(name))
            .setContentTitle("Receiving $name")
            .setContentText("Sent to this phone")
            .setProgress(0, 0, true)
            .setOngoing(true)
        post(context, id(name), builder)
    }

    fun received(context: Context, name: String, uri: Uri?) {
        val id = id(name)
        val mime = uri?.let { context.contentResolver.getType(it) }
        val builder = base(context, id)
            .setContentTitle("Received $name")
            .setContentText("Tap to open")
            .setOngoing(false)
            .setProgress(0, 0, false)
        // Open: the file itself.
        val open = openIntent(context, uri, mime)
        val openFile = PendingIntent.getActivity(context, id * 4 + 1, open, FLAGS)
        // Tapping the pop-up does the same as its Open button.
        builder.setContentIntent(openFile)
        builder.addAction(action(context, "Open", openFile))
        // Share: only when there is a file URI that another app may read.
        if (uri != null) {
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mime ?: "*/*"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(send, "Share $name").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            builder.addAction(action(context, "Share", PendingIntent.getActivity(context, id * 4 + 2, chooser, FLAGS)))
        }
        if (uri != null && mime?.startsWith("image/") == true) {
            preview(context, uri)?.let { bitmap ->
                builder.setLargeIcon(bitmap)
                builder.setStyle(Notification.BigPictureStyle().bigPicture(bitmap).bigLargeIcon(null as Bitmap?))
            }
        }
        post(context, id, builder)
    }

    fun failed(context: Context, name: String) {
        val id = id(name)
        val builder = base(context, id)
            .setContentTitle("Transfer did not finish")
            .setContentText(name)
            .setOngoing(false)
            .setProgress(0, 0, false)
        post(context, id, builder)
    }

    private const val FLAGS = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

    private fun id(name: String): Int = byName.getOrPut(name) { ids.incrementAndGet() }

    private fun openIntent(context: Context, uri: Uri?, mime: String?): Intent =
        if (uri != null) {
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime ?: "*/*")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        } else {
            Intent(android.app.DownloadManager.ACTION_VIEW_DOWNLOADS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }

    private fun action(context: Context, label: String, intent: PendingIntent): Notification.Action =
        Notification.Action.Builder(null as android.graphics.drawable.Icon?, label, intent).build()

    private fun base(context: Context, id: Int): Notification.Builder {
        ensureChannel(context)
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(context, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
                .setPriority(Notification.PRIORITY_HIGH)
                .setDefaults(Notification.DEFAULT_ALL)
        }
        // Tapping the pop-up goes to SWIFT.
        val app = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_swift)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setShowWhen(true)
            .setContentIntent(PendingIntent.getActivity(context, id * 4, app, FLAGS))
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(CHANNEL, "Transfers", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "When a file is sent to this phone"
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            enableVibration(true)
        }
        manager.createNotificationChannel(channel)
    }

    private fun post(context: Context, id: Int, builder: Notification.Builder) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        try {
            manager.notify(id, builder.build())
        } catch (_: SecurityException) {
            // Notifications switched off for SWIFT. The file is still saved.
        }
    }

    /** A small copy for the notification. Never the full photo. */
    private fun preview(context: Context, uri: Uri): Bitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (bounds.outWidth / sample > 1024 && bounds.outWidth > 0) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
    } catch (_: Exception) {
        null
    }
}
