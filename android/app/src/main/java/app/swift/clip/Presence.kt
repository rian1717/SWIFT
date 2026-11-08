package app.swift.clip

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import java.io.File
import java.io.OutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors

/**
 * Announces this phone as a Quick Share receiver while the screen is on, and
 * accepts the Mac's transfer in this process. SWIFT stays in front.
 */
object Presence {
    private val accept = Executors.newSingleThreadExecutor()
    private var socket: ServerSocket? = null
    private var nsd: NsdManager? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var advertising = false
    private var screen: BroadcastReceiver? = null
    private var multicast: WifiManager.MulticastLock? = null
    private var radio: WifiManager.WifiLock? = null
    private var reannounce = false

    /** Publish again after the person changes this phone's name. */
    fun readvertise(context: Context) {
        val app = context.applicationContext
        if (registration == null) {
            refresh(app)
            return
        }
        reannounce = true
        conceal()
    }

    fun start(context: Context) {
        val app = context.applicationContext
        ensureServer(app)
        ensureScreen(app)
        refresh(app)
    }

    private fun ensureScreen(context: Context) {
        if (screen != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                refresh(ctx.applicationContext)
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        context.registerReceiver(receiver, filter)
        screen = receiver
    }

    private fun refresh(context: Context) {
        val interactive = context.getSystemService(PowerManager::class.java)?.isInteractive == true
        if (interactive) advertise(context) else conceal()
    }

    private fun ensureServer(context: Context) {
        if (socket?.isClosed == false) return
        val server = ServerSocket(0)
        socket = server
        accept.execute {
            while (!server.isClosed) {
                try {
                    val client = server.accept()
                    Thread { serve(context, client) }.start()
                } catch (_: Exception) {
                    break
                }
            }
        }
    }

    private fun advertise(context: Context) {
        if (advertising || registration != null) return
        val server = socket ?: return
        holdMulticast(context)
        val manager = context.getSystemService(NsdManager::class.java) ?: return
        val info = NsdServiceInfo().apply {
            serviceName = QuickShareSession.serviceInstanceName()
            serviceType = QuickShareSession.SERVICE_TYPE
            port = server.localPort
            setAttribute("n", QuickShareSession.txtName(QuickShareSession.endpointInfo(ClipSync.deviceLabel(context))))
            lanAddress()?.let { setAttribute("IPv4", it) }
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                advertising = true
                ClipForegroundService.update(context, "Visible to your Mac")
            }
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                advertising = false
                registration = null
                ClipForegroundService.update(context, "Not visible to your Mac ($errorCode)")
            }
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {
                advertising = false
                if (reannounce) {
                    reannounce = false
                    advertise(context)
                }
            }
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
        }
        nsd = manager
        registration = listener
        try {
            manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (_: Exception) {
            advertising = false
            registration = null
        }
    }

    /** This phone's Wi-Fi address, so the Mac can dial it directly. */
    private fun lanAddress(): String? {
        val interfaces = NetworkInterface.getNetworkInterfaces() ?: return null
        val found = ArrayList<Pair<String, String>>()
        for (nif in interfaces) {
            if (!nif.isUp || nif.isLoopback) continue
            val addresses = nif.inetAddresses ?: continue
            for (addr in addresses) {
                if (addr !is Inet4Address || addr.isLoopbackAddress) continue
                val host = addr.hostAddress ?: continue
                if (isPrivate(host)) found.add(nif.name to host)
            }
        }
        return found.firstOrNull { it.first.startsWith("wlan") }?.second ?: found.firstOrNull()?.second
    }

    private fun isPrivate(host: String): Boolean {
        val parts = host.split('.').mapNotNull { it.toIntOrNull() }
        if (parts.size != 4) return false
        return parts[0] == 10 ||
            (parts[0] == 192 && parts[1] == 168) ||
            (parts[0] == 172 && parts[1] in 16..31)
    }

    private fun holdMulticast(context: Context) {
        if (multicast?.isHeld == true) return
        val wifi = context.applicationContext.getSystemService(WifiManager::class.java) ?: return
        try {
            multicast = wifi.createMulticastLock("swift").apply {
                setReferenceCounted(false)
                acquire()
            }
            if (radio?.isHeld != true) {
                @Suppress("DEPRECATION")
                radio = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "swift-radio").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } catch (_: Exception) {
        }
    }

    private fun conceal() {
        val manager = nsd
        val listener = registration
        advertising = false
        registration = null
        if (manager != null && listener != null) {
            try { manager.unregisterService(listener) } catch (_: Exception) {}
        }
        try { multicast?.release() } catch (_: Exception) {}
        try { radio?.release() } catch (_: Exception) {}
        multicast = null
        radio = null
    }

    private fun serve(context: Context, client: Socket) {
        try {
            QuickShareSession(
                client,
                begin = { name, _ -> download(context, name) },
                ask = { offer, answer -> TransferAlerts.ask(context, offer, answer) },
            ).run()
        } catch (_: Exception) {
        }
    }

    private fun download(context: Context, name: String): FileTarget {
        val safe = File(name).name.replace(Regex("""[\\/:*?"<>|]"""), "_").ifBlank { "file" }
        // The pop-up appears as soon as the Mac starts sending.
        TransferAlerts.receiving(context, safe)
        if (Build.VERSION.SDK_INT >= 29) {
            val values = android.content.ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, safe)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("downloads")
            val stream = context.contentResolver.openOutputStream(uri) ?: throw IllegalStateException("downloads")
            return object : FileTarget {
                override val out: OutputStream = stream
                override fun commit() {
                    try { stream.close() } catch (_: Exception) {}
                    val done = android.content.ContentValues().apply {
                        put(MediaStore.Downloads.IS_PENDING, 0)
                    }
                    context.contentResolver.update(uri, done, null, null)
                    ClipForegroundService.update(context, "Saved $safe")
                    TransferAlerts.received(context, safe, uri)
                }
                override fun abandon() {
                    try { stream.close() } catch (_: Exception) {}
                    context.contentResolver.delete(uri, null, null)
                    TransferAlerts.failed(context, safe)
                }
            }
        }
        val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        dir.mkdirs()
        val file = File(dir, safe)
        val stream = file.outputStream()
        return object : FileTarget {
            override val out: OutputStream = stream
            override fun commit() {
                stream.close()
                ClipForegroundService.update(context, "Saved $safe")
                TransferAlerts.received(context, safe, null)
            }
            override fun abandon() {
                try { stream.close() } catch (_: Exception) {}
                file.delete()
                TransferAlerts.failed(context, safe)
            }
        }
    }
}
