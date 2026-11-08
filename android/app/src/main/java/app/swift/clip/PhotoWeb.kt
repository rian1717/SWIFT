package app.swift.clip

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import java.io.File
import java.io.OutputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * A page the iPhone opens in Safari. There is no app to install on iOS.
 * Uploads and downloads are the photo file itself.
 */
object PhotoWeb {
    private const val PORT = 47825
    private val main = Handler(Looper.getMainLooper())
    private val work = Executors.newSingleThreadExecutor()
    private val random = SecureRandom()
    private val inbox = CopyOnWriteArrayList<Item>()
    private val openClients = AtomicInteger(0)
    private var server: ServerSocket? = null
    private var token = ""

    fun start(context: Context) {
        if (token.isEmpty()) token = newToken()
        if (server?.isClosed != false) listen(context.applicationContext)
    }

    fun newLink() {
        token = newToken()
        inbox.clear()
    }

    fun link(): String {
        val host = lanAddress() ?: return ""
        val port = server?.localPort ?: PORT
        return "http://$host:$port/s/$token"
    }

    fun qr(): Bitmap? {
        val text = link()
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

    fun add(context: Context, uris: List<Uri>, done: (String) -> Unit) {
        val app = context.applicationContext
        work.execute {
            var added = 0
            for (uri in uris) {
                val name = displayName(app, uri)
                val type = app.contentResolver.getType(uri) ?: "application/octet-stream"
                val id = randomId()
                val file = File(app.cacheDir, id)
                val bytes = app.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: continue
                if (bytes.isEmpty() || bytes.size > PhotoExchange.MAX_BYTES) continue
                file.writeBytes(bytes)
                inbox.add(Item(id, name, type, file))
                added += 1
            }
            val message = if (added == 0) {
                "No photo was added."
            } else {
                "The iPhone page can save $added photo${if (added == 1) "" else "s"}. Touch Save original photo."
            }
            main.post { done(message) }
        }
    }

    private fun listen(context: Context) {
        val socket = try {
            ServerSocket(PORT)
        } catch (_: Exception) {
            ServerSocket(0)
        }
        server = socket
        Thread {
            while (!socket.isClosed) {
                try {
                    val client = socket.accept()
                    if (!isPrivate(client.inetAddress)) {
                        client.close()
                        continue
                    }
                    if (openClients.incrementAndGet() > 8) {
                        openClients.decrementAndGet()
                        client.close()
                        continue
                    }
                    Thread {
                        try {
                            serve(context, client)
                        } finally {
                            openClients.decrementAndGet()
                        }
                    }.start()
                } catch (_: Exception) {
                    break
                }
            }
        }.start()
    }

    private fun serve(context: Context, client: Socket) {
        client.use { socket ->
            socket.soTimeout = 120_000
            val request = try {
                PhotoExchange.read(socket.getInputStream())
            } catch (_: Exception) {
                null
            } ?: return
            val output = socket.getOutputStream()
            val path = request.path.trimEnd('/')
            val rest = pathAfterToken(path)
            if (rest == null) {
                write(output, 404, "text/plain", "Open the page from the code on the Android screen.".toByteArray())
                return
            }
            when {
                request.method == "GET" && rest.isEmpty() ->
                    write(output, 200, "text/html; charset=utf-8", page().toByteArray())
                request.method == "GET" && rest == "/inbox" ->
                    write(output, 200, "application/json", inboxJson().toByteArray())
                request.method == "GET" && rest.startsWith("/file/") -> {
                    val id = rest.removePrefix("/file/")
                    val item = inbox.firstOrNull { it.id == id && id.matches(Regex("[a-z0-9]+")) }
                    if (item == null || !item.file.isFile) {
                        write(output, 404, "text/plain", "That photo is gone.".toByteArray())
                    } else {
                        write(output, 200, item.type, item.file.readBytes())
                    }
                }
                request.method == "POST" && rest == "/upload" -> {
                    val saved = saveUpload(context, request.headers, request.body)
                    if (saved) write(output, 200, "application/json", """{"ok":true}""".toByteArray())
                    else write(output, 400, "application/json", """{"error":"empty"}""".toByteArray())
                }
                else -> write(output, 404, "text/plain", "Not found.".toByteArray())
            }
        }
    }

    private fun saveUpload(context: Context, headers: Map<String, String>, body: ByteArray): Boolean {
        if (body.isEmpty()) return false
        val raw = headers["x-swift-name"].orEmpty()
        val name = java.net.URLDecoder.decode(raw, "UTF-8")
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .take(80)
            .ifBlank { "photo" }
        val type = safeType(headers["content-type"].orEmpty())
        return saveToGallery(context, name, type, body)
    }

    private fun saveToGallery(context: Context, name: String, type: String, bytes: ByteArray): Boolean {
        val safe = File(name).name.replace(Regex("""[\\/:*?"<>|]"""), "_").ifBlank { "photo" }
        return try {
            if (Build.VERSION.SDK_INT >= 29) {
                val values = android.content.ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, safe)
                    put(MediaStore.Images.Media.MIME_TYPE, type)
                    put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/SWIFT")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                val uri = context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                    ?: return false
                context.contentResolver.openOutputStream(uri)?.use { it.write(bytes) } ?: return false
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                context.contentResolver.update(uri, values, null, null)
                TransferAlerts.received(context, safe, uri)
                return true
            }
            TransferAlerts.received(context, safe, null)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun page(): String {
        return """
            <!doctype html>
            <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
            <meta name="theme-color" content="#1D2B40">
            <title>SWIFT</title>
            <style>
              :root { color-scheme: light; }
              * { box-sizing: border-box; }
              body {
                margin: 0; min-height: 100vh; color: #1D2B40; background: #F6F1EA;
                font: 17px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
              }
              header {
                background: #1D2B40; color: #F6F1EA;
                padding: calc(28px + env(safe-area-inset-top)) 24px 28px;
                border-radius: 0 0 32px 32px;
              }
              .mark {
                width: 44px; height: 44px; border-radius: 22px; background: #E8772E;
              }
              h1 { font-size: 34px; letter-spacing: -0.03em; margin: 14px 0 0; font-weight: 700; }
              header p { color: #C9C0B4; margin: 6px 0 0; }
              main { padding: 20px 20px 40px; }
              h2 { font-size: 20px; margin: 0; }
              p { color: #5E6A7A; margin: 4px 0 0; }
              .card {
                background: #fff; border-radius: 28px; padding: 20px; margin-top: 14px;
                box-shadow: 0 8px 24px rgba(29, 43, 64, 0.08);
              }
              label.send, button {
                display: flex; align-items: center; justify-content: center;
                width: 100%; min-height: 56px; margin-top: 16px; border: 0; border-radius: 28px;
                font: 600 16px/1.2 -apple-system, BlinkMacSystemFont, sans-serif;
              }
              label.send { background: #E8772E; color: #fff; }
              button { background: #F3EEE8; color: #1D2B40; margin-top: 10px; }
              img { width: 100%; border-radius: 18px; margin-top: 14px; background: #F3EEE8; }
              #sent:empty { display: none; }
              #sent { color: #1D2B40; font-weight: 600; }
            </style>
            <header>
              <div class="mark"></div>
              <h1>SWIFT</h1>
              <p>Nothing to install. The photo stays full size.</p>
            </header>
            <main>
            <section class="card">
              <h2>To Android</h2>
              <p>Pick the photos on this iPhone.</p>
              <label class="send">Send photos<input id="files" type="file" accept="image/*" multiple hidden></label>
              <p id="sent"></p>
            </section>
            <section class="card">
              <h2>From Android</h2>
              <p>Save the original file into Photos.</p>
              <div id="inbox"><p>Nothing here yet. On Android, tap Send photos.</p></div>
            </section>
            </main>
            <script>
            const base = location.pathname.replace(/\/$/, '');
            document.getElementById('files').onchange = async (event) => {
              const files = [...event.target.files];
              let saved = 0;
              for (const file of files) {
                const response = await fetch(base + '/upload', {
                  method: 'POST',
                  headers: {
                    'Content-Type': file.type || 'application/octet-stream',
                    'X-SWIFT-Name': encodeURIComponent(file.name || 'photo')
                  },
                  body: file
                });
                if (response.ok) saved++;
              }
              document.getElementById('sent').textContent = saved
                ? 'Sent ' + saved + ' photo' + (saved === 1 ? '' : 's') + ' to the Android gallery.'
                : 'The Android phone did not take the photo. Keep SWIFT open and stay on the same Wi-Fi.';
              event.target.value = '';
            };
            async function savePhoto(item) {
              const response = await fetch(base + '/file/' + item.id);
              const blob = await response.blob();
              const file = new File([blob], item.name, { type: item.type || blob.type || 'image/jpeg' });
              if (navigator.canShare && navigator.canShare({ files: [file] })) {
                try { await navigator.share({ files: [file] }); return; } catch (error) { if (error.name === 'AbortError') return; }
              }
              const link = document.createElement('a');
              link.href = URL.createObjectURL(blob);
              link.download = item.name;
              link.click();
            }
            async function refresh() {
              const response = await fetch(base + '/inbox');
              if (!response.ok) return;
              const items = await response.json();
              const box = document.getElementById('inbox');
              const ids = items.map(item => item.id).join();
              if (box.dataset.ids === ids) return;
              box.dataset.ids = ids;
              box.innerHTML = '';
              if (!items.length) {
                box.innerHTML = '<p>Nothing here yet. On Android, tap Send photos.</p>';
                return;
              }
              for (const item of items) {
                const img = document.createElement('img');
                img.alt = item.name;
                img.src = base + '/file/' + item.id;
                const button = document.createElement('button');
                button.textContent = 'Save original photo';
                button.onclick = () => savePhoto(item);
                box.appendChild(img);
                box.appendChild(button);
              }
            }
            refresh();
            setInterval(refresh, 2000);
            </script>
        """.trimIndent()
    }

    private fun inboxJson(): String {
        return inbox.joinToString(prefix = "[", postfix = "]") { item ->
            """{"id":"${jsonString(item.id)}","name":"${jsonString(item.name)}","type":"${jsonString(item.type)}"}"""
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
                else -> if (ch.code < 0x20) out.append(' ') else out.append(ch)
            }
        }
        return out.toString()
    }

    private fun write(output: OutputStream, status: Int, type: String, body: ByteArray) {
        val reason = if (status == 200) "OK" else "No"
        val head = "HTTP/1.1 $status $reason\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        output.write(head.toByteArray(Charsets.ISO_8859_1))
        output.write(body)
        output.flush()
    }

    private fun displayName(context: Context, uri: Uri): String {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val name = cursor.getString(0)
                if (!name.isNullOrBlank()) return name
            }
        }
        return "photo"
    }

    private fun lanAddress(): String? {
        val interfaces = NetworkInterface.getNetworkInterfaces() ?: return null
        for (iface in interfaces) {
            if (!iface.isUp || iface.isLoopback) continue
            for (address in iface.inetAddresses) {
                if (address is Inet4Address && !address.isLoopbackAddress) {
                    val host = address.hostAddress ?: continue
                    if (host.startsWith("192.168.") || host.startsWith("10.") || host.startsWith("172.")) return host
                }
            }
        }
        return null
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
        if (token.isEmpty() || !path.startsWith(marker)) return null
        val after = path.removePrefix(marker)
        val slash = after.indexOf('/')
        val given = if (slash < 0) after else after.substring(0, slash)
        if (!sameToken(given, token)) return null
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

    private data class Item(val id: String, val name: String, val type: String, val file: File)
}
