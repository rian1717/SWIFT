package app.swift.clip

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ClipboardManager
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.EditText

/**
 * HyperOS does not update the clipboard for a background app, which is why a
 * copy only arrived after SWIFT was opened. The words are sent when the
 * user taps Copy, from WhatsApp, Chrome, or anywhere else. Selecting text
 * does not send it.
 */
class ClipboardAccessibilityService : AccessibilityService() {
    private var clipboard: ClipboardManager? = null
    private val handler = Handler(Looper.getMainLooper())
    private var lastSelection: String? = null
    private var lastSelectionAt = 0L
    /** True when the stored words came from a real text selection, as in WhatsApp. */
    private var selectionExact = false
    private var readingFresh = false
    private val poll = object : Runnable {
        override fun run() {
            ClipSync.deliver(this@ClipboardAccessibilityService, readClip(), null)
            handler.postDelayed(this, 400)
        }
    }
    private val listener = ClipboardManager.OnPrimaryClipChangedListener {
        deliver(readClip(), recentSelection())
    }

    override fun onServiceConnected() {
        val info = serviceInfo ?: AccessibilityServiceInfo()
        info.eventTypes = info.eventTypes or
            AccessibilityEvent.TYPE_VIEW_CLICKED or
            AccessibilityEvent.TYPE_VIEW_LONG_CLICKED or
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED or
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED or
            AccessibilityEvent.TYPE_VIEW_TEXT_TRAVERSED_AT_MOVEMENT_GRANULARITY or
            AccessibilityEvent.TYPE_ANNOUNCEMENT or
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED or
            AccessibilityEvent.TYPE_WINDOWS_CHANGED or
            AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED or
            AccessibilityEvent.TYPE_VIEW_FOCUSED
        info.flags = info.flags or
            AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
            AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
            AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
        info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
        info.notificationTimeout = 50
        serviceInfo = info

        val canRead = info.canRetrieveWindowContent
        getSharedPreferences("swift-clip", MODE_PRIVATE).edit()
            .putBoolean("canReadScreen", canRead)
            .apply()
        if (!canRead) {
            ClipForegroundService.update(
                this,
                "Turn clipboard access off, then on, once. The phone is still using the old setting."
            )
        }

        clipboard = getSystemService(ClipboardManager::class.java)
        clipboard?.addPrimaryClipChangedListener(listener)
        if (ClipSync.isPaired(this)) ClipForegroundService.start(this)
        handler.removeCallbacks(poll)
        handler.post(poll)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        remember(event)
        // Selecting text is not a copy. The words go to the Mac only after
        // the Copy button is tapped, or after the phone says they were copied.
        if (!isCopy(event)) return
        val clip = readClip()
        val exact = selectionInWindows()
        if (exact != null) store(exact, exact = true)
        val selection = if (selectionExact) recentSelection() else null
        val sent = deliver(clip, selection)
        // WhatsApp exposes the selection, so it is already sent. A website
        // only puts the words on the clipboard, which HyperOS hides until
        // this app is focused. Focus for a moment and read them.
        if (!sent) readFreshClip(selection)
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        handler.removeCallbacks(poll)
        clipboard?.removePrimaryClipChangedListener(listener)
        val restart = android.content.Intent(applicationContext, ClipForegroundService::class.java)
        try {
            applicationContext.startForegroundService(restart)
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    private fun deliver(clip: android.content.ClipData?, selection: String?): Boolean {
        return ClipSync.deliver(this, clip, selection?.takeIf { !isStatus(it) })
    }

    /**
     * HyperOS allows a clipboard read only while this app is focused. A 1px
     * overlay takes that focus long enough to read a website copy, then goes away.
     */
    private fun readFreshClip(fallback: String?) {
        if (readingFresh) return
        readingFresh = true
        val wm = getSystemService(WindowManager::class.java)
        val view = EditText(this)
        view.showSoftInputOnFocus = false
        view.isFocusable = true
        view.isFocusableInTouchMode = true
        view.alpha = 0f
        view.setBackgroundColor(0)
        val params = WindowManager.LayoutParams(
            1,
            1,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            0,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            alpha = 0f
        }
        try {
            wm.addView(view, params)
            view.requestFocus()
        } catch (_: Exception) {
            readingFresh = false
            if (fallback != null) deliver(null, fallback)
            return
        }
        fun finish(attempt: Int) {
            val sent = deliver(readClip(), null)
            if (sent || attempt >= 3) {
                try {
                    wm.removeView(view)
                } catch (_: Exception) {
                }
                readingFresh = false
                if (!sent && fallback != null) deliver(null, fallback)
                return
            }
            handler.postDelayed({ finish(attempt + 1) }, 70)
        }
        handler.postDelayed({ finish(0) }, 40)
    }

    private fun remember(event: AccessibilityEvent) {
        val source = event.source
        try {
            rangedText(source?.text?.toString(), event.fromIndex, event.toIndex)?.let { store(it, exact = true) }
            rangedText(event.text?.joinToString(""), event.fromIndex, event.toIndex)?.let { store(it, exact = true) }
            if (source != null) selectionOn(source)?.let { store(it, exact = true) }
            if (event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_TRAVERSED_AT_MOVEMENT_GRANULARITY ||
                event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED
            ) {
                val loose = event.contentDescription?.toString()?.trim().orEmpty()
                    .ifEmpty { event.text?.joinToString("")?.trim().orEmpty() }
                if (loose.isNotEmpty() && loose.length < 8_000 && !isStatus(loose)) store(loose, exact = false)
            }
        } finally {
            source?.recycle()
        }
    }

    private fun isCopy(event: AccessibilityEvent): Boolean {
        if (isCopyNotice(labelOf(event))) return true
        // A selection menu shows a Copy button. Seeing that button is not a tap.
        if (event.eventType != AccessibilityEvent.TYPE_VIEW_CLICKED) return false
        if (isCopyLabel(labelOf(event))) return true
        val source = event.source ?: return false
        return try {
            clickedNodeIsCopy(source)
        } finally {
            source.recycle()
        }
    }

    private fun clickedNodeIsCopy(node: AccessibilityNodeInfo): Boolean {
        val blob = listOfNotNull(node.text?.toString(), node.contentDescription?.toString()).joinToString(" ")
        if (isCopyLabel(blob) || isCopyNotice(blob)) return true
        if (idMeansCopy(node.viewIdResourceName)) return true
        val parent = node.parent ?: return false
        val parentBlob = listOfNotNull(parent.text?.toString(), parent.contentDescription?.toString())
            .joinToString(" ")
        val parentIsCopy = isCopyLabel(parentBlob) || isCopyNotice(parentBlob) ||
            idMeansCopy(parent.viewIdResourceName)
        parent.recycle()
        return parentIsCopy
    }

    private fun idMeansCopy(id: String?): Boolean {
        val name = id?.substringAfterLast('/')?.lowercase() ?: return false
        if (name.contains("copyright")) return false
        return name == "copy" || name.endsWith("_copy") || name.endsWith(":copy") ||
            name.contains("copy_button") || name == "action_copy" || name.contains("menuitem_copy")
    }

    private fun selectionInWindows(): String? {
        val list = windows ?: return null
        var best: String? = null
        var seen = 0
        for (window in list) {
            val root = window.root ?: continue
            val found = findSelection(root, 0) { seen += 1; seen <= 400 }
            root.recycle()
            if (found != null && found.length > (best?.length ?: 0)) best = found
        }
        return best
    }

    private fun findSelection(node: AccessibilityNodeInfo, depth: Int, budget: () -> Boolean): String? {
        if (depth > 14 || !budget()) return null
        var best = selectionOn(node)
        for (index in 0 until node.childCount) {
            val child = node.getChild(index) ?: continue
            val found = findSelection(child, depth + 1, budget)
            child.recycle()
            if (found != null && found.length > (best?.length ?: 0)) best = found
        }
        return best
    }

    private fun selectionOn(node: AccessibilityNodeInfo): String? {
        return rangedText(node.text?.toString(), node.textSelectionStart, node.textSelectionEnd)
    }

    private fun rangedText(text: String?, start: Int, end: Int): String? {
        if (text.isNullOrEmpty() || start < 0 || end <= start || end > text.length) return null
        val slice = text.substring(start, end).trim()
        if (slice.isEmpty() || isStatus(slice)) return null
        return slice
    }

    private fun labelOf(event: AccessibilityEvent): String {
        return buildString {
            append(event.text?.joinToString(" ") ?: "")
            append(' ')
            append(event.contentDescription ?: "")
        }.trim()
    }

    private fun isCopyLabel(raw: String): Boolean {
        val label = raw.trim().lowercase()
        if (label.isEmpty() || label.length > 32) return false
        return label == "copy" || label == "copy text" || label == "复制" || label == "拷贝" ||
            label == "copy link" || label.startsWith("copy ")
    }

    private fun isCopyNotice(raw: String): Boolean {
        val label = raw.trim().lowercase()
        if (label.isEmpty() || label.length > 80) return false
        return label.contains("copy success") || label.contains("copied") ||
            label.contains("已复制") || label.contains("复制成功") || label.contains("copied to")
    }

    private fun isStatus(text: String): Boolean {
        val label = text.trim().lowercase()
        if (label.length > 40) return false
        return isCopyLabel(label) || label == "copy successfully" || label == "copied" ||
            label == "copied to clipboard" || label.contains("copy success") ||
            label.contains("已复制") || label.contains("复制成功")
    }

    private fun store(text: String, exact: Boolean) {
        if (!exact && selectionExact && System.currentTimeMillis() - lastSelectionAt < 15_000) return
        lastSelection = text
        lastSelectionAt = System.currentTimeMillis()
        selectionExact = exact
    }

    private fun recentSelection(): String? {
        return lastSelection?.takeIf { System.currentTimeMillis() - lastSelectionAt < 15_000 }
    }

    private fun readClip(): android.content.ClipData? = try {
        clipboard?.primaryClip
    } catch (_: SecurityException) {
        null
    }
}
