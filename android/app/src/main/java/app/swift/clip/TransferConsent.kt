package app.swift.clip

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** What the phone is being asked to accept. */
data class IncomingOffer(
    val sender: String,
    val pin: String,
    val fileNames: List<String>,
    val totalBytes: Long,
) {
    val summary: String
        get() {
            val first = cleanLabel(java.io.File(fileNames.first()).name).ifEmpty { "a file" }
            return if (fileNames.size == 1) first else "$first and ${fileNames.size - 1} more"
        }

    companion object {
        const val UNKNOWN_SENDER = "A nearby device"
        private const val MAX_LABEL = 48

        /** These strings come from the sender. Keep control characters out of the prompt. */
        fun cleanLabel(raw: String): String =
            raw.replace(Regex("""\p{C}"""), "").trim().take(MAX_LABEL)
    }
}

/**
 * The one question open at a time. Whoever answers first wins, and no answer
 * within the time limit is a no. A second sender is refused rather than
 * stacking prompts on top of the first.
 */
object TransferConsent {
    const val TIMEOUT_MS = 60_000L

    private class Pending(val token: String, val answer: (Boolean) -> Unit)

    private val lock = Any()
    private var pending: Pending? = null
    private val timer = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "transfer-consent").apply { isDaemon = true }
    }

    /** Null when another question is already open. */
    fun open(timeoutMs: Long = TIMEOUT_MS, answer: (Boolean) -> Unit): String? {
        val token = UUID.randomUUID().toString()
        synchronized(lock) {
            if (pending != null) return null
            pending = Pending(token, answer)
        }
        timer.schedule({ decide(token, false) }, timeoutMs, TimeUnit.MILLISECONDS)
        return token
    }

    /** Off the caller's thread: answering writes to the network. */
    fun decide(token: String, accepted: Boolean): Boolean {
        val taken = take(token) ?: return false
        Thread { taken.answer(accepted) }.start()
        return true
    }

    fun close(token: String) {
        take(token)
    }

    private fun take(token: String): Pending? = synchronized(lock) {
        val current = pending
        if (current?.token != token) return null
        pending = null
        current
    }
}

/** Not exported: only this app's own notification buttons can reach it. */
class ConsentReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val token = intent.getStringExtra(TOKEN) ?: return
        TransferConsent.decide(token, intent.getBooleanExtra(ACCEPTED, false))
    }

    companion object {
        const val TOKEN = "token"
        const val ACCEPTED = "accepted"
    }
}
