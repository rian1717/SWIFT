package app.swift.clip

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Matrix
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.TimeUnit
import javax.net.ServerSocketFactory

/**
 * A page the iPhone opens in Safari. There is no app to install on iOS.
 * Photos and videos go both ways as the original file.
 *
 * The QR code opens the plain page. Its Save all button moves to the secure copy
 * of the same page, because Safari saves many photos to Photos at once only there.
 */
object PhotoWeb {
    private const val PORT = 47825
    private const val SECURE_PORT = 47826
    private const val THUMB = 480
    private const val FOLDER = "iphone"
    private val main = Handler(Looper.getMainLooper())
    /** Copies photos in, one at a time, in the order they were picked. */
    private val work = Executors.newSingleThreadExecutor()
    private val tlsWork = Executors.newSingleThreadExecutor()
    /** Safari opens many connections for a grid. They wait here instead of being refused. */
    private val clients = ThreadPoolExecutor(64, 64, 30, TimeUnit.SECONDS, LinkedBlockingQueue(512)).apply {
        allowCoreThreadTimeOut(true)
    }
    /** Requests being answered. While there are any, Wi-Fi and the processor stay awake. */
    private val busy = AtomicInteger(0)
    private val awakeLock = Any()
    private var wifiLocks: List<WifiManager.WifiLock> = emptyList()
    private var cpuLock: PowerManager.WakeLock? = null
    private val rest = Runnable { releaseIfIdle() }
    private val random = SecureRandom()
    private val inbox = CopyOnWriteArrayList<Item>()
    @Volatile private var server: ServerSocket? = null
    @Volatile private var secureServer: ServerSocket? = null
    @Volatile private var secureHosts: List<String> = emptyList()
    @Volatile private var token = ""

    fun start(context: Context) {
        val app = context.applicationContext
        if (token.isEmpty()) token = newToken()
        if (server?.isClosed != false) {
            try {
                val socket = bind(ServerSocketFactory.getDefault(), PORT)
                server = socket
                acceptLoop(app, socket)
            } catch (_: Exception) {
            }
        }
        ensureSecure(app)
    }

    fun newLink() {
        token = newToken()
        val old = inbox.toList()
        inbox.clear()
        work.execute { old.forEach { it.delete() } }
    }

    fun count(): Int = inbox.count { it.file.isFile }

    /**
     * Where the copies live. Not the cache folder: Android empties that whenever the
     * phone runs low on space, which took photos away halfway through a transfer.
     * SWIFT empties this folder itself, on New link and when the app starts.
     */
    private fun folder(context: Context) = File(context.applicationContext.noBackupFilesDir, FOLDER)

    /** Photos copied for the iPhone are lost with the app, so a new start clears them. */
    fun clearOld(context: Context) {
        val cache = context.applicationContext.cacheDir
        val copies = folder(context)
        work.execute {
            try {
                copies.deleteRecursively()
                // Version 0.3.2 test builds kept them in the cache folder.
                File(cache, FOLDER).deleteRecursively()
                // Version 0.3.1 kept them loose in the cache folder.
                cache.listFiles()?.filter { it.isFile && it.name.matches(Regex("[0-9a-f]{16}")) }?.forEach { it.delete() }
            } catch (_: Exception) {
            }
        }
    }

    /** Empty when this phone is not on a Wi-Fi network that an iPhone could reach. */
    fun link(context: Context): String {
        val host = LocalNetwork.address(context)?.host ?: return ""
        val port = server?.localPort ?: PORT
        return "http://$host:$port/s/$token"
    }

    fun qr(context: Context): Bitmap? {
        val text = link(context)
        if (text.isEmpty()) return null
        val matrix = try {
            QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 640, 640)
        } catch (_: Exception) {
            return null
        }
        val bitmap = Bitmap.createBitmap(640, 640, Bitmap.Config.RGB_565)
        for (x in 0 until 640) {
            for (y in 0 until 640) {
                bitmap.setPixel(x, y, if (matrix.get(x, y)) Color.BLACK else Color.WHITE)
            }
        }
        return bitmap
    }

    /** Copies the picked or shared photos and videos in, with a small preview for each. */
    fun add(context: Context, uris: List<Uri>, done: (String) -> Unit) {
        val app = context.applicationContext
        start(app)
        work.execute {
            var added = 0
            var skipped = 0
            var full = false
            for (uri in uris) {
                when (copyIn(app, uri)) {
                    Copied.YES -> added += 1
                    Copied.NO -> skipped += 1
                    Copied.FULL -> {
                        full = true
                        skipped += 1
                    }
                }
            }
            val message = PhotoRules.addedMessage(added, skipped, count(), full)
            main.post { done(message) }
        }
    }

    private enum class Copied { YES, NO, FULL }

    private fun copyIn(context: Context, uri: Uri): Copied {
        val id = randomId()
        val dir = folder(context).apply { mkdirs() }
        val file = File(dir, id)
        val thumb = File(dir, "$id.jpg")
        return try {
            val name = displayName(context, uri)
            val type = mediaType(context.contentResolver.getType(uri), name) ?: return Copied.NO
            context.contentResolver.openInputStream(uri)?.use { input ->
                file.outputStream().use { input.copyTo(it, 64 * 1024) }
            } ?: return Copied.NO
            if (file.length() == 0L) {
                file.delete()
                return Copied.NO
            }
            val video = type.startsWith("video/")
            val hasThumb = makeThumb(file, video, thumb)
            inbox.add(Item(id, name, type, file, if (hasThumb) thumb else null, video))
            Copied.YES
        } catch (error: Throwable) {
            file.delete()
            thumb.delete()
            // ENOSPC: the phone's storage is full.
            if (error.message?.contains("ENOSPC") == true || error.message?.contains("No space", ignoreCase = true) == true) {
                Copied.FULL
            } else {
                Copied.NO
            }
        }
    }

    private fun bind(factory: ServerSocketFactory, port: Int): ServerSocket = try {
        factory.createServerSocket(port)
    } catch (_: Exception) {
        factory.createServerSocket(0)
    }

    /** Starts the secure page, again whenever the phone's Wi-Fi address changes. */
    private fun ensureSecure(context: Context) {
        try {
            tlsWork.execute {
                try {
                    val hosts = (listOfNotNull(LocalNetwork.address(context)?.host) + "127.0.0.1").distinct()
                    if (secureServer?.isClosed == false && hosts == secureHosts) return@execute
                    val ssl = PhotoTls.context(context, hosts)
                    try { secureServer?.close() } catch (_: Exception) {}
                    val socket = bind(ssl.serverSocketFactory, SECURE_PORT)
                    secureHosts = hosts
                    secureServer = socket
                    acceptLoop(context, socket)
                } catch (_: Throwable) {
                    // The plain page still works. Its photos save one at a time.
                }
            }
        } catch (_: RejectedExecutionException) {
        }
    }

    private fun acceptLoop(context: Context, socket: ServerSocket) {
        Thread {
            while (!socket.isClosed) {
                val client = try {
                    socket.accept()
                } catch (_: Exception) {
                    break
                }
                if (!isPrivate(client.inetAddress)) {
                    try { client.close() } catch (_: Exception) {}
                    continue
                }
                try {
                    clients.execute { serve(context, client) }
                } catch (_: RejectedExecutionException) {
                    try { client.close() } catch (_: Exception) {}
                }
            }
        }.apply { isDaemon = true }.start()
    }

    /**
     * One request. A tab that closes halfway is normal and must not stop the app.
     *
     * Safari opens spare connections and may never use them. Each one would hold a
     * thread, so a connection gets 10 seconds to ask for something.
     */
    private fun serve(context: Context, client: Socket) {
        try {
            client.use { socket ->
                socket.soTimeout = 10_000
                socket.tcpNoDelay = true
                val input = BufferedInputStream(socket.getInputStream())
                val head = PhotoExchange.readHead(input) ?: return
                socket.soTimeout = 60_000
                stayAwake(context)
                try {
                    val output = BufferedOutputStream(socket.getOutputStream(), 64 * 1024)
                    route(context, head, input, output)
                    output.flush()
                } finally {
                    doneAwake()
                }
            }
        } catch (_: Throwable) {
        }
    }

    /**
     * Phones save power by letting Wi-Fi doze between packets, which slows a transfer
     * to a crawl or stalls it. Held while photos move, and 20 seconds after.
     */
    private fun stayAwake(context: Context) {
        busy.incrementAndGet()
        main.removeCallbacks(rest)
        synchronized(awakeLock) {
            try {
                if (wifiLocks.isEmpty()) {
                    val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
                    val modes = buildList {
                        if (Build.VERSION.SDK_INT >= 29) add(WifiManager.WIFI_MODE_FULL_LOW_LATENCY)
                        @Suppress("DEPRECATION")
                        add(WifiManager.WIFI_MODE_FULL_HIGH_PERF)
                    }
                    wifiLocks = modes.mapNotNull { mode ->
                        wifi?.createWifiLock(mode, "swift-photos-$mode")?.apply { setReferenceCounted(false) }
                    }
                }
                if (cpuLock == null) {
                    cpuLock = context.applicationContext.getSystemService(PowerManager::class.java)
                        ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "swift:photos")
                        ?.apply { setReferenceCounted(false) }
                }
                wifiLocks.forEach { if (!it.isHeld) it.acquire() }
                cpuLock?.acquire(10 * 60_000L)
            } catch (_: Exception) {
            }
        }
    }

    private fun doneAwake() {
        if (busy.decrementAndGet() <= 0) {
            busy.set(0)
            main.postDelayed(rest, 20_000)
        }
    }

    private fun releaseIfIdle() {
        synchronized(awakeLock) {
            if (busy.get() > 0) return
            try {
                wifiLocks.forEach { if (it.isHeld) it.release() }
                cpuLock?.takeIf { it.isHeld }?.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun route(context: Context, head: PhotoExchange.Head, input: InputStream, output: OutputStream) {
        val rest = pathAfterToken(head.path.trimEnd('/'))
        if (rest == null) {
            text(output, 404, "Open the page from the code on the Android screen.")
            return
        }
        val get = head.method == "GET" || head.method == "HEAD"
        when {
            get && rest.isEmpty() -> body(output, 200, "text/html; charset=utf-8", page().toByteArray())
            get && rest == "/inbox" -> body(output, 200, "application/json", inboxJson().toByteArray())
            get && rest.startsWith("/download/") -> {
                // The same file, marked as a download: Chrome on Android saves it to
                // the Download album, which Google Photos and every gallery show.
                val item = find(rest.removePrefix("/download/"))
                if (item == null || !item.file.isFile) {
                    text(output, 404, "That photo is gone.")
                } else {
                    val fallback = item.name.replace(Regex("[^A-Za-z0-9._-]"), "_")
                    val encoded = java.net.URLEncoder.encode(item.name, "UTF-8").replace("+", "%20")
                    val disposition = "Content-Disposition: attachment; filename=\"$fallback\"; filename*=UTF-8''$encoded\r\n"
                    sendFile(output, item.file, item.type, head.headers["range"], head.method == "HEAD", disposition)
                }
            }
            get && rest.startsWith("/file/") -> {
                val item = find(rest.removePrefix("/file/"))
                if (item == null || !item.file.isFile) text(output, 404, "That photo is gone.")
                else sendFile(output, item.file, item.type, head.headers["range"], head.method == "HEAD")
            }
            get && rest.startsWith("/thumb/") -> {
                val thumb = find(rest.removePrefix("/thumb/"))?.thumb
                if (thumb == null || !thumb.isFile) text(output, 404, "No preview.")
                else sendFile(output, thumb, "image/jpeg", null, head.method == "HEAD")
            }
            head.method == "POST" && rest == "/upload" -> {
                val length = head.headers["content-length"]?.toLongOrNull() ?: -1
                val saved = length > 0 && saveUpload(context, head.headers, input, length)
                if (saved) body(output, 200, "application/json", """{"ok":true}""".toByteArray())
                else body(output, 400, "application/json", """{"error":"not saved"}""".toByteArray())
            }
            else -> text(output, 404, "Not found.")
        }
    }

    private fun find(id: String): Item? =
        if (id.matches(Regex("[a-f0-9]{16}"))) inbox.firstOrNull { it.id == id } else null

    private fun saveUpload(context: Context, headers: Map<String, String>, input: InputStream, length: Long): Boolean {
        val raw = headers["x-swift-name"].orEmpty()
        val name = try {
            java.net.URLDecoder.decode(raw, "UTF-8")
        } catch (_: Exception) {
            raw
        }
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .take(80)
            .ifBlank { "photo" }
        val type = mediaType(safeType(headers["content-type"].orEmpty()), name) ?: "application/octet-stream"
        return saveToGallery(context, name, type, input, length)
    }

    /** Streams the upload into Photos (or Movies for a video) without holding it in memory. */
    private fun saveToGallery(context: Context, name: String, type: String, input: InputStream, length: Long): Boolean {
        val safe = File(name).name.replace(Regex("""[\\/:*?"<>|]"""), "_").ifBlank { "photo" }
        if (Build.VERSION.SDK_INT < 29) {
            TransferAlerts.received(context, safe, null)
            return true
        }
        val video = type.startsWith("video/")
        val image = type.startsWith("image/")
        val collection = when {
            video -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            image -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            else -> MediaStore.Downloads.EXTERNAL_CONTENT_URI
        }
        val folder = when {
            video -> Environment.DIRECTORY_MOVIES + "/SWIFT"
            image -> Environment.DIRECTORY_PICTURES + "/SWIFT"
            else -> Environment.DIRECTORY_DOWNLOADS
        }
        val values = android.content.ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, safe)
            put(MediaStore.MediaColumns.MIME_TYPE, type)
            put(MediaStore.MediaColumns.RELATIVE_PATH, folder)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val uri = try {
            resolver.insert(collection, values)
        } catch (_: Exception) {
            null
        } ?: return false
        return try {
            val complete = resolver.openOutputStream(uri)?.use { out -> copyExactly(input, out, length) } == true
            if (!complete) {
                resolver.delete(uri, null, null)
                return false
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            TransferAlerts.received(context, safe, uri)
            true
        } catch (_: Exception) {
            try { resolver.delete(uri, null, null) } catch (_: Exception) {}
            false
        }
    }

    private fun copyExactly(input: InputStream, output: OutputStream, length: Long): Boolean {
        val buffer = ByteArray(64 * 1024)
        var left = length
        while (left > 0) {
            val read = input.read(buffer, 0, minOf(buffer.size.toLong(), left).toInt())
            if (read < 0) return false
            output.write(buffer, 0, read)
            left -= read
        }
        return true
    }

    private fun sendFile(
        output: OutputStream,
        file: File,
        type: String,
        range: String?,
        headOnly: Boolean,
        disposition: String = "",
    ) {
        val total = file.length()
        val span = PhotoRules.parseRange(range, total)
        val start = span?.first ?: 0L
        val end = span?.second ?: (total - 1)
        val length = if (total == 0L) 0L else end - start + 1
        val extra = buildString {
            append(disposition)
            append("Accept-Ranges: bytes\r\n")
            if (span != null) append("Content-Range: bytes $start-$end/$total\r\n")
        }
        writeHead(output, if (span != null) 206 else 200, type, length, extra, "private, max-age=3600")
        if (headOnly || length == 0L) return
        FileInputStream(file).use { stream ->
            var skip = start
            while (skip > 0) {
                val skipped = stream.skip(skip)
                if (skipped <= 0) return
                skip -= skipped
            }
            copyExactly(stream, output, length)
        }
    }

    private fun text(output: OutputStream, status: Int, message: String) =
        body(output, status, "text/plain; charset=utf-8", message.toByteArray())

    private fun body(output: OutputStream, status: Int, type: String, bytes: ByteArray) {
        writeHead(output, status, type, bytes.size.toLong(), "", "no-store")
        output.write(bytes)
    }

    private fun writeHead(output: OutputStream, status: Int, type: String, length: Long, extra: String, cache: String) {
        val reason = when (status) {
            200 -> "OK"
            206 -> "Partial Content"
            400 -> "Bad Request"
            404 -> "Not Found"
            else -> "Error"
        }
        val head = "HTTP/1.1 $status $reason\r\nContent-Type: $type\r\nContent-Length: $length\r\n" +
            "Connection: close\r\nCache-Control: $cache\r\nX-Content-Type-Options: nosniff\r\n$extra\r\n"
        output.write(head.toByteArray(Charsets.ISO_8859_1))
    }

    private fun makeThumb(file: File, video: Boolean, out: File): Boolean = try {
        val bitmap = if (video) videoFrame(file) else photoPreview(file)
        if (bitmap == null) {
            false
        } else {
            out.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 80, it) }
            bitmap.recycle()
            true
        }
    } catch (_: Throwable) {
        false
    }

    private fun photoPreview(file: File): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply {
            inSampleSize = PhotoRules.thumbSample(bounds.outWidth, bounds.outHeight, THUMB)
        }
        val decoded = BitmapFactory.decodeFile(file.path, options) ?: return null
        val degrees = try {
            when (ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } catch (_: Exception) {
            0f
        }
        return fit(decoded, degrees)
    }

    private fun videoFrame(file: File): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.path)
            val frame = retriever.getFrameAtTime(1_000_000) ?: retriever.frameAtTime ?: return null
            fit(frame, 0f)
        } finally {
            try { retriever.release() } catch (_: Exception) {}
        }
    }

    /** Scales to about THUMB pixels on the long side and turns it upright. */
    private fun fit(source: Bitmap, degrees: Float): Bitmap {
        val scale = minOf(1f, THUMB.toFloat() / maxOf(source.width, source.height))
        if (scale >= 1f && degrees == 0f) return source
        val matrix = Matrix().apply {
            postScale(scale, scale)
            postRotate(degrees)
        }
        val result = Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true)
        if (result !== source) source.recycle()
        return result
    }

    private fun page(): String {
        val securePort = secureServer?.takeIf { !it.isClosed }?.localPort ?: 0
        return PAGE.trimIndent().replace("__SECURE_PORT__", securePort.toString())
    }

    private fun inboxJson(): String {
        return inbox.filter { it.file.isFile }.joinToString(prefix = "[", postfix = "]") { item ->
            """{"id":"${jsonString(item.id)}","name":"${jsonString(item.name)}","type":"${jsonString(item.type)}",""" +
                """"video":${item.video},"thumb":${item.thumb != null},"size":${item.file.length()}}"""
        }
    }

    private fun jsonString(value: String): String {
        val out = StringBuilder()
        for (ch in value) {
            when (ch) {
                '\\' -> out.append("\\\\")
                '"' -> out.append("\\\"")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '<' -> out.append("\\u003c")
                else -> if (ch.code < 0x20) out.append(' ') else out.append(ch)
            }
        }
        return out.toString()
    }

    private fun displayName(context: Context, uri: Uri): String {
        try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val name = cursor.getString(0)
                    if (!name.isNullOrBlank()) return name
                }
            }
        } catch (_: Exception) {
        }
        return uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.contains('.') } ?: "photo"
    }

    /** 128-bit token. An 8-digit code can be guessed on a local network. */
    private fun newToken(): String {
        val bytes = ByteArray(16)
        random.nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }

    /**
     * Returns the path after `/s/{token}`, or null when the token does not match.
     * A request for `/s/{token}extra` is not treated as a match.
     */
    private fun pathAfterToken(path: String): String? {
        val marker = "/s/"
        val current = token
        if (current.isEmpty() || !path.startsWith(marker)) return null
        val after = path.removePrefix(marker)
        val slash = after.indexOf('/')
        val given = if (slash < 0) after else after.substring(0, slash)
        if (!sameToken(given, current)) return null
        return if (slash < 0) "" else after.substring(slash)
    }

    private fun sameToken(given: String, expected: String): Boolean {
        if (given.length != expected.length) return false
        var diff = 0
        for (i in given.indices) diff = diff or (given[i].code xor expected[i].code)
        return diff == 0
    }

    private fun safeType(raw: String): String {
        val type = raw.substringBefore(";").trim().lowercase()
        val image = type.startsWith("image/") && type != "image/svg+xml"
        val video = type.startsWith("video/")
        return if (image || video || type == "application/octet-stream") type else "application/octet-stream"
    }

    /** A photo or video type, from what the app said or else from the file name. */
    private fun mediaType(given: String?, name: String): String? {
        val clean = given?.substringBefore(";")?.trim()?.lowercase().orEmpty()
        if (PhotoRules.isMedia(clean)) return clean
        val ext = name.substringAfterLast('.', "").lowercase()
        val guessed = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: when (ext) {
                "heic" -> "image/heic"
                "heif" -> "image/heif"
                "mov" -> "video/quicktime"
                else -> null
            }
        return guessed?.takeIf { PhotoRules.isMedia(it) }
    }

    private fun isPrivate(address: InetAddress): Boolean {
        if (address.isLoopbackAddress) return true
        val bytes = address.address
        if (address is Inet4Address && bytes.size == 4) {
            val a = bytes[0].toInt() and 0xff
            val b = bytes[1].toInt() and 0xff
            return a == 10 || (a == 192 && b == 168) || (a == 172 && b in 16..31) || (a == 169 && b == 254)
        }
        if (bytes.size == 16) {
            val a = bytes[0].toInt() and 0xff
            val b = bytes[1].toInt() and 0xff
            if (a == 0xfe && (b and 0xc0) == 0x80) return true
            if ((a and 0xfe) == 0xfc) return true
        }
        return false
    }

    private fun randomId(): String {
        val bytes = ByteArray(8)
        random.nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private data class Item(
        val id: String,
        val name: String,
        val type: String,
        val file: File,
        val thumb: File?,
        val video: Boolean,
    ) {
        fun delete() {
            file.delete()
            thumb?.delete()
        }
    }

    private val PAGE = """
        <!doctype html>
        <html lang="en">
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="theme-color" content="#1D2B40">
        <title>SWIFT</title>
        <style>
          :root { color-scheme: light; }
          * { box-sizing: border-box; }
          [hidden] { display: none !important; }
          html, body { height: 100%; }
          body {
            margin: 0; display: flex; flex-direction: column; height: 100vh; height: 100dvh;
            overflow: hidden; color: #1D2B40; background: #F6F1EA;
            font: 17px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          }
          header {
            flex: none; display: flex; align-items: center; gap: 12px;
            background: #1D2B40; color: #F6F1EA;
            padding: calc(14px + env(safe-area-inset-top)) 20px 14px;
          }
          .mark { flex: none; width: 34px; height: 34px; border-radius: 17px; background: #E8772E; }
          h1 { font-size: 20px; letter-spacing: -0.02em; margin: 0; font-weight: 700; }
          header p { color: #C9C0B4; margin: 0; font-size: 14px; }
          main { flex: 1; min-height: 0; overflow-y: auto; -webkit-overflow-scrolling: touch; padding: 6px; }
          .empty { margin: 0; padding: 56px 28px; text-align: center; color: #5E6A7A; }
          .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 4px; }
          .tile {
            position: relative; display: block; aspect-ratio: 1; overflow: hidden;
            border-radius: 10px; background: #EAE3DA; color: #5E6A7A;
            font-size: 12px; text-decoration: none;
          }
          .tile img { width: 100%; height: 100%; object-fit: cover; display: block; }
          .tile .name { position: absolute; inset: 8px; overflow: hidden; word-break: break-all; }
          .tile .badge {
            position: absolute; left: 6px; bottom: 6px; padding: 2px 7px; border-radius: 8px;
            background: rgba(0, 0, 0, 0.55); color: #fff; font-size: 12px;
          }
          .tile.saved::after {
            content: "✓"; position: absolute; top: 6px; right: 6px; width: 24px; height: 24px;
            border-radius: 12px; background: #E8772E; color: #fff; text-align: center;
            font: 600 14px/24px -apple-system, sans-serif;
          }
          footer {
            flex: none; background: #fff; border-radius: 24px 24px 0 0;
            padding: 14px 16px calc(14px + env(safe-area-inset-bottom));
            box-shadow: 0 -6px 24px rgba(29, 43, 64, 0.10);
          }
          .note { font-size: 14px; color: #5E6A7A; margin: 0 0 10px; }
          .note:empty { display: none; }
          label.send, button {
            display: flex; align-items: center; justify-content: center;
            width: 100%; min-height: 54px; margin: 0; border: 0; border-radius: 27px;
            font: 600 16px/1.2 -apple-system, BlinkMacSystemFont, sans-serif;
            background: #E8772E; color: #fff;
          }
          label.send { min-height: 48px; margin-top: 8px; background: #F3EEE8; color: #1D2B40; }
          button:disabled { opacity: 0.6; }
          #sent { font-size: 14px; font-weight: 600; text-align: center; margin: 8px 0 0; }
          #sent:empty { display: none; }
        </style>
        <header>
          <div class="mark"></div>
          <div>
            <h1>SWIFT</h1>
            <p id="count">Photos stay full size. Nothing to install.</p>
          </div>
        </header>
        <main>
          <p id="empty" class="empty">Nothing here yet. On Android, tap Send photos or videos.</p>
          <div id="grid" class="grid"></div>
        </main>
        <footer>
          <p id="note" class="note"></p>
          <button id="saveAll" hidden>Save all to Photos</button>
          <label class="send">Send to Android<input id="files" type="file" accept="image/*,video/*" multiple hidden></label>
          <p id="sent"></p>
        </footer>
        <script>
        const base = location.pathname.replace(/\/$/, '');
        const SECURE_PORT = __SECURE_PORT__;
        const secure = location.protocol === 'https:';
        // iPhone and iPad save to Photos only through Apple's share menu, on a secure page.
        // Everything else (Android, a computer) saves a download, which the gallery shows.
        const apple = /iPhone|iPad|iPod/i.test(navigator.userAgent) ||
          (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
        const direct = !apple;
        const android = /Android/i.test(navigator.userAgent);
        const MB = 1024 * 1024;
        const PARALLEL = 4;
        const STALL = 20000;
        const byId = (id) => document.getElementById(id);
        const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
        const store = {
          get(key) { try { return JSON.parse(sessionStorage.getItem(key)); } catch (error) { return null; } },
          set(key, value) { try { sessionStorage.setItem(key, JSON.stringify(value)); } catch (error) {} },
          drop(key) { try { sessionStorage.removeItem(key); } catch (error) {} }
        };

        // One tap opens one share menu, and it carries at most this much.
        let budget = store.get('swift-budget') || { count: 100, bytes: 300 * MB };
        // The tab came back while it was holding photos: Safari ran out of memory. Hold less.
        if (store.get('swift-busy')) budget = { count: Math.max(1, Math.floor(budget.count / 2)), bytes: Math.max(MB, Math.floor(budget.bytes / 2)) };
        store.drop('swift-busy');
        store.set('swift-budget', budget);
        addEventListener('pagehide', () => store.drop('swift-busy'));

        let items = [];
        let ready = null;
        let loading = false;
        let loadFailed = false;
        let downloading = false;
        let uploading = false;
        let progressText = '';
        let progressNote = '';
        let hint = '';
        const saved = new Set(store.get('swift-saved:' + base) || []);
        const gone = new Set();
        const loaded = new Map();
        const tiles = new Map();

        function plural(n, word) { return n + ' ' + word + (n === 1 ? '' : 's'); }
        function noun(list) {
          if (list.every((i) => !i.video)) return 'photo';
          if (list.every((i) => i.video)) return 'video';
          return 'item';
        }
        function megabytes(bytes) { return bytes >= 10 * MB ? String(Math.round(bytes / MB)) : (bytes / MB).toFixed(1); }
        function bytesOf(list) { return list.reduce((sum, i) => sum + (i.size || 0), 0); }
        function pending() { return items.filter((i) => !saved.has(i.id)); }
        function note(text) { byId('note').textContent = text; }

        /** The next photos for one share menu: in order, within the budget, and at least one. */
        function nextGroup(list) {
          const group = [];
          let bytes = 0;
          for (const item of list) {
            const size = item.size || 0;
            if (group.length && (group.length >= budget.count || bytes + size > budget.bytes)) break;
            group.push(item);
            bytes += size;
          }
          return group;
        }

        // A locked iPhone stops Safari's downloads, so the screen stays on while photos move.
        let wake = null;
        let asking = false;
        async function awake(on) {
          if (!('wakeLock' in navigator)) return;
          try {
            if (on && !wake && !asking && document.visibilityState === 'visible') {
              asking = true;
              const lock = await navigator.wakeLock.request('screen');
              asking = false;
              wake = lock;
              lock.addEventListener('release', () => { if (wake === lock) wake = null; });
            } else if (!on && wake) {
              const lock = wake;
              wake = null;
              await lock.release();
            }
          } catch (error) {
            asking = false;
          }
        }
        function wantAwake() {
          return uploading || (apple && secure && !loadFailed && pending().length > 0);
        }
        document.addEventListener('visibilitychange', () => {
          if (document.visibilityState === 'visible') awake(wantAwake());
        });

        function render() {
          awake(wantAwake());
          const button = byId('saveAll');
          byId('empty').hidden = items.length > 0;
          if (!items.length) {
            byId('count').textContent = 'Photos stay full size. Nothing to install.';
            button.hidden = true;
            note('');
            return;
          }
          const left = pending();
          const done = items.length - left.length;
          byId('count').textContent = plural(items.length, noun(items)) + (done ? ' · ' + done + ' saved' : '');
          button.hidden = false;
          if (!left.length) {
            button.textContent = direct ? 'All saved' : 'All saved to Photos';
            button.disabled = true;
            note(direct && android ? 'They are in your gallery and Google Photos, in the Download album.' : '');
            store.drop('swift-busy');
            return;
          }
          if (direct) {
            if (downloading) return;
            button.disabled = false;
            button.textContent = android ? 'Save all to Gallery' : 'Save all';
            note(android ? 'If Chrome asks to download several files, tap Allow.' : '');
            return;
          }
          if (!secure) {
            if (!SECURE_PORT) {
              button.hidden = true;
              note('Tap a photo, then touch and hold it and choose Save to Photos.');
              return;
            }
            button.disabled = false;
            button.textContent = 'Save all ' + left.length + ' to Photos';
            note('Safari warns once, because this page comes from the phone next to you. Tap Show Details, then visit this website.');
            return;
          }
          if (loadFailed) {
            button.disabled = false;
            button.textContent = 'Try again';
            note('The Android phone stopped answering. Keep SWIFT open on it and stay on the same Wi-Fi.');
            return;
          }
          if (loading || !ready) {
            button.disabled = true;
            button.textContent = progressText || 'Getting photos…';
            note(progressNote || 'Keep this page open.');
            return;
          }
          const n = ready.length;
          button.disabled = false;
          button.textContent = n < left.length
            ? 'Save ' + n + ' of ' + left.length + ' to Photos'
            : 'Save all ' + n + ' to Photos';
          note(hint || (n < left.length
            ? 'Then choose Save in the menu. Tap again for the rest.'
            : 'Then choose Save in the menu that opens.'));
        }

        /** Brings in the next group, four photos at a time, so one tap can save them all. */
        async function prepare() {
          if (!secure || direct || loading || loadFailed) return;
          const group = nextGroup(pending());
          ready = null;
          if (!group.length) { render(); return; }
          const missing = group.filter((i) => !loaded.has(i.id));
          if (!missing.length) { ready = group; render(); return; }
          loading = true;
          store.set('swift-busy', true);
          const total = bytesOf(group);
          const got = new Map();
          for (const item of group) if (loaded.has(item.id)) got.set(item.id, item.size || 0);
          let finished = group.length - missing.length;
          let queued = false;
          const show = () => {
            queued = false;
            if (!loading) return;
            let bytes = 0;
            for (const value of got.values()) bytes += value;
            progressText = 'Getting ' + finished + ' of ' + group.length + '…';
            progressNote = (total ? megabytes(Math.min(bytes, total)) + ' of ' + megabytes(total) + ' MB · ' : '') + 'Keep this page open.';
            render();
          };
          const tick = () => {
            if (queued) return;
            queued = true;
            setTimeout(show, 200);
          };
          show();
          const queue = missing.slice();
          let failed = false;
          const worker = async () => {
            while (queue.length && !failed) {
              const item = queue.shift();
              try {
                const file = await fetchWithRetry(item, (bytes) => { got.set(item.id, bytes); tick(); });
                if (file) {
                  loaded.set(item.id, file);
                } else {
                  gone.add(item.id);
                  items = items.filter((i) => i.id !== item.id);
                }
                finished += 1;
                tick();
              } catch (error) {
                failed = true;
              }
            }
          };
          await Promise.all(Array.from({ length: Math.min(PARALLEL, missing.length) }, worker));
          loading = false;
          progressText = '';
          progressNote = '';
          if (failed) { loadFailed = true; render(); return; }
          prepare();
        }

        /** A photo that stops coming is asked for again, from where it stopped. */
        async function fetchWithRetry(item, progress) {
          const state = { blobs: [], chunk: [], chunkBytes: 0, received: 0 };
          for (let attempt = 0; ; attempt++) {
            try {
              const found = await fetchFile(item, state, progress);
              if (!found) return null;
              return new File(state.blobs.concat(state.chunk), item.name, { type: item.type || 'application/octet-stream' });
            } catch (error) {
              if (attempt >= 3) throw error;
              await sleep(1000 * Math.pow(2, attempt));
            }
          }
        }

        async function fetchFile(item, state, progress) {
          const controller = new AbortController();
          let timer = setTimeout(() => controller.abort(), STALL);
          try {
            const headers = {};
            if (state.received) headers.Range = 'bytes=' + state.received + '-';
            const response = await fetch(base + '/file/' + item.id, { signal: controller.signal, headers: headers, cache: 'no-store' });
            if (response.status === 404) return false;
            if (!response.ok) throw new Error('HTTP ' + response.status);
            if (response.status !== 206) {
              state.blobs = [];
              state.chunk = [];
              state.chunkBytes = 0;
              state.received = 0;
            }
            const keep = (part, length) => {
              state.chunk.push(part);
              state.chunkBytes += length;
              state.received += length;
              // Thousands of small pieces become a few large ones as they arrive.
              if (state.chunkBytes >= 4 * MB) {
                state.blobs.push(new Blob(state.chunk));
                state.chunk = [];
                state.chunkBytes = 0;
              }
              progress(state.received);
            };
            if (!response.body) {
              const blob = await response.blob();
              keep(blob, blob.size);
            } else {
              const reader = response.body.getReader();
              for (;;) {
                const { done, value } = await reader.read();
                if (done) break;
                keep(value, value.length);
                clearTimeout(timer);
                timer = setTimeout(() => controller.abort(), STALL);
              }
            }
            if (item.size && state.received < item.size) throw new Error('short');
            return true;
          } finally {
            clearTimeout(timer);
          }
        }

        /** One tap: each file is downloaded in turn. Chrome puts them in the Download album. */
        async function downloadAll() {
          const list = pending();
          if (!list.length) return;
          downloading = true;
          const button = byId('saveAll');
          button.disabled = true;
          for (let k = 0; k < list.length; k++) {
            const item = list[k];
            button.textContent = 'Saving ' + (k + 1) + ' of ' + list.length + '…';
            const link = document.createElement('a');
            link.href = base + '/download/' + item.id;
            link.download = item.name;
            document.body.appendChild(link);
            link.click();
            link.remove();
            markSaved([item]);
            await sleep(700);
          }
          downloading = false;
          render();
        }

        function markSaved(list) {
          for (const item of list) {
            saved.add(item.id);
            loaded.delete(item.id);
            const tile = tiles.get(item.id);
            if (tile) tile.classList.add('saved');
          }
          store.set('swift-saved:' + base, Array.from(saved));
        }

        /** Safari would not take that many at once. Half as many, from photos already here. */
        function takeFewer(list) {
          if (list.length <= 1) {
            note('Safari cannot save this one. Tap it, then touch and hold it.');
            return;
          }
          budget = { count: Math.max(1, Math.floor(list.length / 2)), bytes: Math.max(MB, Math.floor(bytesOf(list) / 2)) };
          store.set('swift-budget', budget);
          hint = 'That was too many for Safari at once. Tap again for the first ' + nextGroup(pending()).length + '.';
          prepare();
        }

        byId('saveAll').onclick = async () => {
          if (direct) { downloadAll(); return; }
          if (!secure) {
            location.href = 'https://' + location.hostname + ':' + SECURE_PORT + base;
            return;
          }
          hint = '';
          if (loadFailed) { loadFailed = false; prepare(); return; }
          if (!ready) return;
          const list = ready.filter((i) => loaded.has(i.id) && !saved.has(i.id));
          if (!list.length) { prepare(); return; }
          const files = list.map((i) => loaded.get(i.id));
          if (navigator.canShare && !navigator.canShare({ files })) { takeFewer(list); return; }
          try {
            await navigator.share({ files });
          } catch (error) {
            if (error.name === 'AbortError') { render(); return; }
            if (error.name === 'NotAllowedError') { note('Tap the button again.'); return; }
            takeFewer(list);
            return;
          }
          markSaved(list);
          prepare();
        };

        function tile(item) {
          const link = document.createElement('a');
          link.className = 'tile';
          link.href = base + '/file/' + item.id;
          link.target = '_blank';
          if (item.thumb) {
            const img = document.createElement('img');
            img.loading = 'lazy';
            img.alt = item.name;
            img.src = base + '/thumb/' + item.id;
            link.appendChild(img);
          } else {
            const name = document.createElement('span');
            name.className = 'name';
            name.textContent = item.name;
            link.appendChild(name);
          }
          if (item.video) {
            const badge = document.createElement('span');
            badge.className = 'badge';
            badge.textContent = '▶ Video';
            link.appendChild(badge);
          }
          if (direct) {
            // On Android a tap saves that one photo to the gallery.
            link.href = base + '/download/' + item.id;
            link.download = item.name;
            link.removeAttribute('target');
            link.onclick = () => { markSaved([item]); setTimeout(render, 0); };
            return link;
          }
          link.onclick = (event) => {
            const file = loaded.get(item.id);
            if (!secure || !file) return;
            event.preventDefault();
            navigator.share({ files: [file] }).then(() => {
              markSaved([item]);
              prepare();
            }).catch(() => {});
          };
          return link;
        }

        async function refresh() {
          let list;
          try {
            const response = await fetch(base + '/inbox', { cache: 'no-store' });
            if (response.status === 404) {
              byId('count').textContent = 'This link was replaced. Scan the new code on the Android phone.';
              byId('saveAll').hidden = true;
              note('');
              return;
            }
            if (!response.ok) return;
            list = await response.json();
          } catch (error) {
            return;
          }
          list = list.filter((i) => !gone.has(i.id));
          const ids = new Set(list.map((i) => i.id));
          for (const [id, element] of tiles) {
            if (!ids.has(id)) { element.remove(); tiles.delete(id); loaded.delete(id); saved.delete(id); }
          }
          const grid = byId('grid');
          for (const item of list) {
            if (tiles.has(item.id)) continue;
            const element = tile(item);
            if (saved.has(item.id)) element.classList.add('saved');
            tiles.set(item.id, element);
            grid.appendChild(element);
          }
          const changed = list.length !== items.length || list.some((item, k) => items[k].id !== item.id);
          items = list;
          render();
          if (changed || !ready) prepare();
        }

        async function poll() {
          await refresh();
          // Fewer questions while photos are moving.
          setTimeout(poll, loading ? 5000 : 2000);
        }

        /** Sends one file, with a time limit, and tries twice more if it fails. */
        async function upload(file) {
          for (let attempt = 0; attempt < 3; attempt++) {
            const controller = new AbortController();
            const limit = Math.max(60000, Math.ceil(file.size / (256 * 1024)) * 1000);
            const timer = setTimeout(() => controller.abort(), limit);
            try {
              const response = await fetch(base + '/upload', {
                method: 'POST',
                headers: {
                  'Content-Type': file.type || 'application/octet-stream',
                  'X-SWIFT-Name': encodeURIComponent(file.name || 'photo')
                },
                body: file,
                signal: controller.signal
              });
              if (response.ok) return true;
              if (response.status === 404) return false;
            } catch (error) {
            } finally {
              clearTimeout(timer);
            }
            await sleep(1000 * (attempt + 1));
          }
          return false;
        }

        byId('files').onchange = async (event) => {
          const files = Array.from(event.target.files);
          if (!files.length) return;
          const status = byId('sent');
          const queue = files.slice();
          let sent = 0;
          let finished = 0;
          const show = () => {
            status.textContent = 'Sending ' + Math.min(finished + 1, files.length) + ' of ' + files.length + '…';
          };
          uploading = true;
          awake(true);
          show();
          const worker = async () => {
            while (queue.length) {
              const file = queue.shift();
              if (await upload(file)) sent += 1;
              finished += 1;
              show();
            }
          };
          await Promise.all([worker(), worker()]);
          uploading = false;
          awake(wantAwake());
          status.textContent = sent
            ? 'Sent ' + sent + ' of ' + files.length + ' to the Android gallery.'
            : 'The Android phone did not take them. Keep SWIFT open on it and stay on the same Wi-Fi.';
          event.target.value = '';
        };

        poll();
        </script>
    """
}

/** Kept apart from Android so they can be tested on the computer. */
internal object PhotoRules {

    internal fun isMedia(type: String): Boolean =
        (type.startsWith("image/") && type != "image/svg+xml") || type.startsWith("video/")

    /** The largest power of two that keeps the long side at `target` pixels or more. */
    internal fun thumbSample(width: Int, height: Int, target: Int): Int {
        var sample = 1
        val longest = maxOf(width, height)
        while (longest / (sample * 2) >= target) sample *= 2
        return sample
    }

    /** `Range: bytes=a-b` as an inclusive span, or null to send the whole file. */
    internal fun parseRange(header: String?, total: Long): Pair<Long, Long>? {
        if (header == null || total <= 0) return null
        val spec = header.trim().removePrefix("bytes=").takeIf { it != header.trim() } ?: return null
        if (spec.contains(',')) return null
        val from = spec.substringBefore('-').trim()
        val to = spec.substringAfter('-', "").trim()
        val span = when {
            from.isEmpty() -> {
                val suffix = to.toLongOrNull() ?: return null
                if (suffix <= 0) return null
                maxOf(0, total - suffix) to total - 1
            }
            else -> {
                val start = from.toLongOrNull() ?: return null
                val end = if (to.isEmpty()) total - 1 else (to.toLongOrNull() ?: return null)
                start to minOf(end, total - 1)
            }
        }
        return span.takeIf { it.first in 0..it.second }
    }

    internal fun addedMessage(added: Int, skipped: Int, total: Int, full: Boolean = false): String = when {
        full && added == 0 -> "This phone's storage is full. Free some space, then send them again."
        added == 0 && skipped > 0 -> "Those could not be added. Only photos and videos work."
        added == 0 -> "Nothing was added."
        else -> {
            val ready = "$total ${if (total == 1) "item is" else "items are"} ready. Scan the code with the iPhone camera."
            when {
                full -> "$ready This phone's storage is full, so $skipped could not be added."
                skipped > 0 -> "$ready $skipped could not be added."
                else -> ready
            }
        }
    }
}
