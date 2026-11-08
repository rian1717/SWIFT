package app.swift.clip

import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors

/** Paired Mac plus the send path for one clipboard snapshot. */
object ClipSync {
    private const val PREFS = "swift-clip"
    private const val MAX_BYTES = 32 * 1024 * 1024
    private val work = Executors.newSingleThreadExecutor()
    private val main by lazy { Handler(Looper.getMainLooper()) }
    private var lastHash = ""

    data class Mac(val name: String, val host: String, val port: Int)

    fun isPaired(context: Context): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val keyed = !prefs.getString("id", null).isNullOrEmpty() && !prefs.getString("key", null).isNullOrEmpty()
        return (keyed || prefs.getString("token", "").orEmpty().length >= 32) &&
            prefs.getString("host", "").orEmpty().isNotEmpty()
    }

    fun pairedName(context: Context): String {
        val name = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("name", null)
        return name ?: "your Mac"
    }

    fun status(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val name = prefs.getString("name", null)
        return if (isPaired(context)) "Paired with ${name ?: "your Mac"}" else "Not paired"
    }

    /** The open screen, so a remove on the Mac updates it without a restart. */
    var onRemoved: (() -> Unit)? = null
    private var appContext: Context? = null
    private var checking = false
    private val watch = object : Runnable {
        override fun run() {
            val context = appContext ?: return
            if (!isPaired(context)) return
            if (!checking) {
                checking = true
                work.execute {
                    val removed = macRemovedThisPhone(context)
                    checking = false
                    if (removed) {
                        forget(context)
                        main.post {
                            ClipForegroundService.update(context, "Removed on the Mac")
                            onRemoved?.invoke()
                        }
                    }
                }
            }
            main.postDelayed(this, 2_000)
        }
    }

    /** Asks the Mac, every couple of seconds, whether this phone is still paired. */
    fun startWatch(context: Context) {
        appContext = context.applicationContext
        main.removeCallbacks(watch)
        if (isPaired(appContext!!)) main.post(watch)
    }

    /**
     * Tells the Mac to drop this phone, then forgets the Mac locally.
     * The local forget still happens if the Mac does not answer.
     */
    fun leave(context: Context, done: () -> Unit) {
        val app = context.applicationContext
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        work.execute {
            if (isPaired(app)) {
                val body = JSONObject().put("device", deviceLabel(app)).toString().toByteArray()
                try {
                    authed(app, "/clip/unpair", body)
                } catch (_: Exception) {
                }
            }
            forget(app)
            main.post(done)
        }
    }

    /** Forgets the paired Mac. Copies stop until the phone pairs again. */
    fun forget(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .remove("host")
            .remove("port")
            .remove("token")
            .remove("id")
            .remove("key")
            .remove("counter")
            .remove("name")
            .apply()
        lastHash = ""
    }

    /** A pairing with this phone's own key. The shared token is dropped. */
    private fun saveKeyed(context: Context, host: String, port: Int, id: String, key: ByteArray, name: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("host", host)
            .putInt("port", port)
            .putString("id", id)
            .putString("key", Base64.encodeToString(key, Base64.NO_WRAP))
            .putLong("counter", 0)
            .putString("name", name)
            .remove("token")
            .commit()
    }

    /** What a pairing link points at, so the person can check it first. */
    data class LinkTarget(val name: String, val host: String)

    fun describeLink(raw: String): LinkTarget? {
        val uri = try { Uri.parse(raw.trim()) } catch (_: Exception) { return null }
        val host = uri.getQueryParameter("host").orEmpty()
        val code = uri.getQueryParameter("code").orEmpty().filter { it.isDigit() }
        if (uri.scheme != "swift" || uri.host != "clip" || host.isEmpty() || code.length != 8) return null
        val name = IncomingOffer.cleanLabel(uri.getQueryParameter("name") ?: "Mac").ifEmpty { "Mac" }
        return LinkTarget(name, IncomingOffer.cleanLabel(host))
    }

    fun save(context: Context, host: String, port: Int, token: String, name: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("host", host)
            .putInt("port", port)
            .putString("token", token)
            .putString("name", name)
            .apply()
    }

    private fun plainPairError(raw: String): String = when {
        raw.contains("bad_code") ->
            "That code does not match the Mac. Read the 8 digits under the QR code in SWIFT settings and try again."
        raw.contains("slow_down") ->
            "Too many tries. Wait a minute, then pair again."
        raw.contains("denied") ->
            "The Mac did not allow this phone. Tap Allow on the Mac, then try again."
        else ->
            "The Mac did not answer. Leave Paste phone copies here turned on, stay on the same Wi-Fi, and try again."
    }

    fun pairWithLink(context: Context, raw: String, done: (String) -> Unit) {
        val uri = Uri.parse(raw.trim())
        val host = uri.getQueryParameter("host").orEmpty()
        val port = uri.getQueryParameter("port")?.toIntOrNull() ?: 47822
        val code = uri.getQueryParameter("code").orEmpty().filter { it.isDigit() }
        val name = uri.getQueryParameter("name") ?: "Mac"
        if (uri.scheme != "swift" || uri.host != "clip" || host.isEmpty() || code.length != 8) {
            done("That link is not a SWIFT pairing code")
            return
        }
        // The Mac's key from its own screen. A stranger cannot answer in its place.
        val key = try {
            uri.getQueryParameter("key")?.let { java.util.Base64.getUrlDecoder().decode(it) }
        } catch (_: IllegalArgumentException) {
            null
        }?.takeIf { ClipCrypto.isPublicKey(it) }
        pairWithCode(context, Mac(name, host, port), code, key, done)
    }

    fun discover(context: Context, found: (Mac) -> Unit, finished: () -> Unit) {
        val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
        val multicast = wifi?.createMulticastLock("swift-clip")
        multicast?.setReferenceCounted(false)
        multicast?.acquire()
        val nsd = context.getSystemService(NsdManager::class.java)
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                nsd.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onServiceResolved(resolved: NsdServiceInfo) {
                        val host = ipv4(resolved) ?: return
                        main.post {
                            found(Mac(resolved.serviceName, host, resolved.port.takeIf { it > 0 } ?: 47822))
                        }
                    }
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
                })
            }
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) { main.post(finished) }
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { main.post(finished) }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {}
        }
        nsd.discoverServices("_swift._tcp.", NsdManager.PROTOCOL_DNS_SD, listener)
        main.postDelayed({
            try { nsd.stopServiceDiscovery(listener) } catch (_: Exception) { finished() }
            if (multicast?.isHeld == true) multicast.release()
        }, 4_000)
    }

    private fun ipv4(resolved: NsdServiceInfo): String? {
        val legacy = resolved.host?.hostAddress
        if (!legacy.isNullOrEmpty() && !legacy.contains(":")) return legacy
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            return resolved.hostAddresses.firstOrNull { it is java.net.Inet4Address }?.hostAddress
        }
        return null
    }

    /** Pair with a Mac this phone already found on the same Wi-Fi. */
    fun pairOnWifi(context: Context, mac: Mac, done: (String) -> Unit) {
        work.execute {
            val message = try {
                pairWithKey(context, mac, "approve", "", null, readTimeoutMs = 60_000)?.let { paired ->
                    main.post { done(paired) }
                    return@execute
                }
                val body = JSONObject()
                    .put("device", deviceLabel(context))
                    .toString()
                    .toByteArray()
                val response = post(mac.host, mac.port, "/clip/pair", body, "application/json", null, readTimeoutMs = 60_000)
                val json = JSONObject(response)
                val token = json.getString("token")
                val name = json.optString("name", mac.name)
                save(context, mac.host, mac.port, token, name)
                "Paired with $name. Copy on this phone, then press ⌘V on the Mac."
            } catch (error: Exception) {
                plainPairError(error.message.orEmpty())
            }
            main.post { done(message) }
        }
    }

    fun pairWithCode(context: Context, mac: Mac, code: String, done: (String) -> Unit) =
        pairWithCode(context, mac, code, null, done)

    fun pairWithCode(context: Context, mac: Mac, code: String, macKey: ByteArray?, done: (String) -> Unit) {
        val digits = code.filter { it.isDigit() }
        if (digits.length != 8) {
            done("Type the 8-digit code from the Mac first. It is under the QR code in SWIFT settings.")
            return
        }
        work.execute {
            val message = try {
                pairWithKey(context, mac, "code", digits, macKey)?.let { paired ->
                    main.post { done(paired) }
                    return@execute
                }
                // An older Mac with no keys: the code is sent as before.
                val body = JSONObject()
                    .put("code", digits)
                    .put("device", deviceLabel(context))
                    .toString()
                    .toByteArray()
                val response = post(mac.host, mac.port, "/clip/pair", body, "application/json", null)
                val json = JSONObject(response)
                val token = json.getString("token")
                val name = json.optString("name", mac.name)
                save(context, mac.host, mac.port, token, name)
                "Paired with $name. Copy on this phone, then press ⌘V on the Mac."
            } catch (error: Exception) {
                plainPairError(error.message.orEmpty())
            }
            main.post { done(message) }
        }
    }

    /**
     * Background copies on a Redmi do not show up in the clipboard until this
     * app is opened. The accessibility service passes the text that was just
     * selected, and that is what we send when the clipboard is still the old one.
     */
    /** @return true when a new copy was actually sent. */
    fun deliver(context: Context, clip: ClipData?, selection: String?): Boolean {
        if (!isPaired(context)) return false
        val fromClip = clip?.let { copiedText(context, it) }
        val selected = usableText(selection)
        val clipIsNew = fromClip != null && !isSameAsLast(context, fromClip)
        val selectionIsNew = selected != null && !isSameAsLast(context, selected)
        val text = when {
            clipIsNew && selectionIsNew && selected!!.length > fromClip!!.length &&
                selected.startsWith(fromClip.take(24.coerceAtMost(fromClip.length))) -> selected
            clipIsNew -> fromClip
            selectionIsNew -> selected
            else -> null
        } ?: return false
        sendPlainText(context, text)
        return true
    }

    fun sendPlainText(context: Context, text: String) {
        if (!isPaired(context)) return
        val clean = usableText(text) ?: return
        val body = JSONObject()
            .put("source", deviceLabel(context))
            .put("kind", "text")
            .put("text", clean)
            .toString()
            .toByteArray(Charsets.UTF_8)
        if (body.size > MAX_BYTES) return
        val hash = sha256(body)
        if (hash == lastHash) return
        lastHash = hash
        val payload = Snapshot(body, hash)
        val appContext = context.applicationContext
        work.execute {
            val message = try {
                send(appContext, payload)
                "Sent to the Mac. Press ⌘V."
            } catch (error: Exception) {
                if (lastHash == hash) lastHash = ""
                if (error.message.orEmpty().contains("removed")) {
                    forget(appContext)
                    main.post { onRemoved?.invoke() }
                    "Removed on the Mac"
                } else {
                    "The Mac did not receive the copy. Keep Paste phone copies here on, and stay on the same Wi-Fi."
                }
            }
            main.post { ClipForegroundService.update(appContext, message) }
        }
    }

    /**
     * A name typed in SWIFT wins. Otherwise the phone's own name wins.
     * Quick Share shows that name ("Rai's Pixel 8"). The Bluetooth name is
     * often only the model ("Pixel 8"), and that must not replace it.
     */
    fun chooseLabel(custom: String?, bluetooth: String?, system: String?, model: String?): String {
        fun clean(value: String?) = value?.trim()?.takeIf { it.isNotEmpty() }
        clean(custom)?.let { return it }
        val heard = clean(bluetooth)
        val own = clean(system)
        if (heard != null && own != null) {
            if (isShorterPiece(heard, own)) return own
            if (isShorterPiece(own, heard)) return heard
        }
        return heard ?: own ?: clean(model) ?: "Android"
    }

    /** True when `candidate` is the model at the end of a longer device name. */
    fun isShorterPiece(candidate: String, longer: String): Boolean {
        val short = candidate.trim().lowercase()
        val long = longer.trim().lowercase()
        if (short.length < 3 || short.length >= long.length || !long.endsWith(short)) return false
        return long[long.length - short.length - 1] == ' '
    }

    fun deviceLabel(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        // Android refuses this read to newer target SDKs. The label then falls
        // back to the system device name instead of crashing the app.
        val bluetooth = try {
            android.provider.Settings.Secure.getString(context.contentResolver, "bluetooth_name")
        } catch (_: SecurityException) {
            null
        }
        val system = try {
            android.provider.Settings.Global.getString(
                context.contentResolver, android.provider.Settings.Global.DEVICE_NAME
            )
        } catch (_: SecurityException) {
            null
        }
        return chooseLabel(prefs.getString("deviceName", null), bluetooth, system, android.os.Build.MODEL)
    }

    /** Real names of phones that scanned this phone's Add phone code. */
    fun rememberAddedPhone(context: Context, name: String) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val names = prefs.getStringSet("addedPhones", emptySet()).orEmpty() + name
        prefs.edit().putStringSet("addedPhones", names).apply()
    }

    fun saveDeviceName(context: Context, name: String) {
        val trimmed = name.trim().take(63)
        val edit = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        if (trimmed.isEmpty()) edit.remove("deviceName") else edit.putString("deviceName", trimmed)
        edit.apply()
    }

    private fun isSameAsLast(context: Context, text: String): Boolean {
        val body = JSONObject()
            .put("source", deviceLabel(context))
            .put("kind", "text")
            .put("text", text)
            .toString()
            .toByteArray(Charsets.UTF_8)
        return sha256(body) == lastHash
    }

    private fun sha256(body: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(body).joinToString("") { "%02x".format(it) }

    /** Read whatever is on the clipboard now and send it if it is new. */
    fun sendCurrent(context: Context, done: (String) -> Unit) {
        val clip = try {
            context.getSystemService(ClipboardManager::class.java)?.primaryClip
        } catch (_: SecurityException) {
            null
        } ?: return
        onClip(context, clip, done)
    }

    fun onClip(context: Context, clip: ClipData, done: ((String) -> Unit)? = null) {
        if (!isPaired(context)) {
            main.post { done?.invoke("Not paired with the Mac") }
            return
        }
        val payload = try {
            snapshot(context, clip)
        } catch (_: Exception) {
            main.post { done?.invoke("Couldn’t read that copy") }
            return
        } ?: return
        if (payload.hash == lastHash) return
        lastHash = payload.hash
        val appContext = context.applicationContext
        work.execute {
            val message = try {
                send(appContext, payload)
                "Sent to the Mac. Press ⌘V."
            } catch (_: Exception) {
                if (lastHash == payload.hash) lastHash = ""
                "The Mac did not receive the copy. Keep Paste phone copies here on, and stay on the same Wi-Fi."
            }
            main.post {
                done?.invoke(message)
                ClipForegroundService.update(appContext, message)
            }
        }
    }

    private data class Snapshot(val body: ByteArray, val hash: String)

    private fun snapshot(context: Context, clip: ClipData): Snapshot? {
        val resolver = context.contentResolver
        var text = copiedText(context, clip).orEmpty()
        val files = JSONArray()
        var total = 0
        for (index in 0 until clip.itemCount) {
            val item = clip.getItemAt(index)
            val uri = item.uri ?: continue
            val mime = resolver.getType(uri) ?: ""
            if (mime.startsWith("text/")) continue
            if (text.isNotEmpty()) continue
            try {
                val bytes = resolver.openInputStream(uri)?.use { it.readBytes() } ?: continue
                if (bytes.isEmpty() || bytes.size > MAX_BYTES || total + bytes.size > MAX_BYTES) continue
                total += bytes.size
                files.put(JSONObject()
                    .put("name", displayName(resolver, uri))
                    .put("mime", mime.ifEmpty { "application/octet-stream" })
                    .put("data", Base64.encodeToString(bytes, Base64.NO_WRAP)))
            } catch (_: SecurityException) {
            }
        }
        if (text.startsWith("swift://clip")) return null
        val json = JSONObject().put("source", deviceLabel(context))
        when {
            text.isNotEmpty() -> json.put("kind", "text").put("text", text)
            files.length() == 1 -> {
                val file = files.getJSONObject(0)
                val mime = file.getString("mime")
                json.put("kind", if (mime.startsWith("image/")) "image" else "file")
                json.put("name", file.getString("name"))
                json.put("mime", mime)
                json.put("data", file.getString("data"))
            }
            files.length() > 1 -> json.put("kind", "files").put("files", files)
            else -> return null
        }
        val body = json.toString().toByteArray(Charsets.UTF_8)
        if (body.size > MAX_BYTES) return null
        return Snapshot(body, sha256(body))
    }

    private fun copiedText(context: Context, clip: ClipData): String? {
        var plain = ""
        for (index in 0 until clip.itemCount) {
            val item = clip.getItemAt(index)
            // The plain words the user copied. A web page also attaches HTML,
            // and that HTML is longer than the selection, so it must not win.
            usableText(item.text?.toString())?.let { if (it.length > plain.length) plain = it }
        }
        if (plain.isNotEmpty()) return plain
        var text = ""
        val resolver = context.contentResolver
        for (index in 0 until clip.itemCount) {
            val item = clip.getItemAt(index)
            try {
                usableText(item.coerceToText(context)?.toString())?.let { if (it.length > text.length) text = it }
            } catch (_: Exception) {
            }
            val uri = item.uri ?: continue
            val mime = resolver.getType(uri) ?: ""
            if (!mime.startsWith("text/")) continue
            try {
                resolver.openInputStream(uri)?.use { input ->
                    val bytes = input.readBytes()
                    if (bytes.size in 1..1_000_000) {
                        usableText(String(bytes, Charsets.UTF_8))?.let { if (it.length > text.length) text = it }
                    }
                }
            } catch (_: Exception) {
            }
        }
        return text.ifEmpty { null }
    }

    private fun usableText(raw: String?): String? {
        val text = raw?.trim() ?: return null
        if (text.isEmpty() || text.startsWith("content://") || text.startsWith("swift://")) return null
        return text
    }

    private fun displayName(resolver: ContentResolver, uri: Uri): String {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) cursor.getString(index)?.let { return it }
            }
        }
        return uri.lastPathSegment ?: "clipboard"
    }

    private fun send(context: Context, snapshot: Snapshot) {
        authed(context, "/clip", snapshot.body)
    }

    /**
     * Pairs with this phone's own key. The code, or the old token, is never
     * sent: each side proves it knows it. Returns null for an older Mac that has
     * no key, so the caller can pair the old way.
     */
    private fun pairWithKey(
        context: Context,
        mac: Mac,
        auth: String,
        secret: String,
        knownKey: ByteArray?,
        readTimeoutMs: Int = 30_000,
    ): String? {
        val macKey = knownKey ?: hello(mac.host, mac.port) ?: return null
        val mine = ClipCrypto.newPair()
        val key = ClipCrypto.pairingKey(mine.private, mine.public, macKey, secret)
        val body = JSONObject()
            .put("device", deviceLabel(context))
            .put("auth", auth)
            .put("pub", Base64.encodeToString(mine.public, Base64.NO_WRAP))
            .put("proof", Base64.encodeToString(ClipCrypto.proof(key, ClipCrypto.PHONE_LABEL), Base64.NO_WRAP))
            .toString()
            .toByteArray()
        val json = JSONObject(post(mac.host, mac.port, "/clip/pair", body, "application/json", null, readTimeoutMs))
        val proof = Base64.decode(json.getString("proof"), Base64.NO_WRAP)
        // Only the real Mac, which knows the code, can answer with this.
        if (!ClipCrypto.matches(proof, key, ClipCrypto.MAC_LABEL)) error("bad_mac")
        val name = json.optString("name", mac.name)
        saveKeyed(context, mac.host, mac.port, json.getString("id"), key, name)
        return "Paired with $name. Copy on this phone, then press ⌘V on the Mac."
    }

    /** The Mac's public key, or null when the Mac is too old to have one. */
    private fun hello(host: String, port: Int): ByteArray? {
        val connection = (URL("http://$host:$port/clip/hello").openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 5_000
            readTimeout = 5_000
        }
        try {
            val code = connection.responseCode
            if (code == 404) return null
            if (code !in 200..299) error("HTTP $code")
            val json = JSONObject(connection.inputStream.use { it.readBytes().toString(Charsets.UTF_8) })
            return Base64.decode(json.getString("key"), Base64.NO_WRAP).takeIf { ClipCrypto.isPublicKey(it) }
                ?: error("key")
        } finally {
            connection.disconnect()
        }
    }

    private var lastUpgrade = 0L

    /** A phone paired before keys existed moves to its own key, without pairing again. */
    private fun upgradeIfNeeded(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val token = prefs.getString("token", null) ?: return
        if (!prefs.getString("key", null).isNullOrEmpty()) return
        val now = System.currentTimeMillis()
        if (now - lastUpgrade < 10 * 60_000) return
        lastUpgrade = now
        val host = prefs.getString("host", null) ?: return
        val mac = Mac(prefs.getString("name", null) ?: "Mac", host, prefs.getInt("port", 47822))
        try {
            pairWithKey(context, mac, "token", token, null)
        } catch (_: Exception) {
            // Stays on the old pairing and tries again later.
        }
    }

    /** Sends one request as this phone: sealed with its key, or the old way. */
    private fun authed(context: Context, path: String, body: ByteArray): String {
        upgradeIfNeeded(context)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val host = prefs.getString("host", null) ?: error("not paired")
        val port = prefs.getInt("port", 47822)
        val id = prefs.getString("id", null)
        val key = prefs.getString("key", null)?.let { Base64.decode(it, Base64.NO_WRAP) }
        if (!id.isNullOrEmpty() && key != null) {
            val sealed = ClipCrypto.seal(body, nextCounter(context), key, path, id)
            return post(host, port, path, sealed, "application/octet-stream", "SWIFT $id")
        }
        val token = prefs.getString("token", null) ?: error("not paired")
        return post(host, port, path, body, "application/json", "Bearer $token")
    }

    /** Always higher than the last one, so the Mac can refuse a replayed copy. */
    @Synchronized
    private fun nextCounter(context: Context): Long {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val next = maxOf(prefs.getLong("counter", 0) + 1, System.currentTimeMillis())
        prefs.edit().putLong("counter", next).commit()
        return next
    }

    /** True only when the Mac says this phone was removed. A network miss stays paired. */
    private fun macRemovedThisPhone(context: Context): Boolean {
        if (!isPaired(context)) return false
        val body = JSONObject().put("device", deviceLabel(context)).toString().toByteArray()
        return try {
            authed(context, "/clip/status", body)
            false
        } catch (error: Exception) {
            error.message.orEmpty().contains("removed")
        }
    }

    private fun health(host: String, port: Int, token: String) {
        val url = URL("http://$host:$port/clip/health")
        val connection = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 4_000
            readTimeout = 4_000
            setRequestProperty("Authorization", "Bearer $token")
        }
        try {
            if (connection.responseCode !in 200..299) error("HTTP ${connection.responseCode}")
        } finally {
            connection.disconnect()
        }
    }

    private fun post(
        host: String,
        port: Int,
        path: String,
        body: ByteArray,
        type: String,
        authorization: String?,
        readTimeoutMs: Int = 30_000,
    ): String {
        val connection = (URL("http://$host:$port$path").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 5_000
            readTimeout = readTimeoutMs
            doOutput = true
            setFixedLengthStreamingMode(body.size)
            setRequestProperty("Content-Type", type)
            if (authorization != null) setRequestProperty("Authorization", authorization)
        }
        connection.outputStream.use { it.write(body) }
        val code = connection.responseCode
        val stream = if (code in 200..299) connection.inputStream else connection.errorStream
        val response = stream?.use { it.readBytes().toString(Charsets.UTF_8) }.orEmpty()
        connection.disconnect()
        if (code !in 200..299) error(response.ifEmpty { "HTTP $code" })
        return response
    }
}
