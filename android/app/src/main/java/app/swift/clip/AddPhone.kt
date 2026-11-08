package app.swift.clip

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** The secrets behind one "Add phone" QR code. Same derivation as the Mac. */
internal class AddPhoneCode(val blob: ByteArray) {
    val token = derive("advertisingContext")
    private val nameKey = derive("encryptionKey")
    val url: String =
        "https://quickshare.google/qrcode#key=" + Base64.getUrlEncoder().withoutPadding().encodeToString(blob)

    private fun derive(info: String): ByteArray =
        // HKDF defines an absent salt as zeros. An empty key is refused here.
        QuickShareCrypto.hkdf(blob, ByteArray(32), info.toByteArray(), 16)

    /** The real name inside a Quick Share `n` record, if this phone scanned this code. */
    fun nameFrom(encodedRecord: String): String? {
        val record = try {
            Base64.getUrlDecoder().decode(encodedRecord)
        } catch (_: IllegalArgumentException) {
            return null
        }
        if (record.size < 17) return null
        val hidden = record[0].toInt() and 0x10 != 0
        var offset = 17
        var plainName: String? = null
        if (!hidden) {
            if (record.size < 18) return null
            val length = record[17].toInt() and 0xFF
            if (record.size < 18 + length) return null
            plainName = String(record, 18, length, Charsets.UTF_8)
            offset = 18 + length
        }
        while (record.size - offset > 2) {
            val type = record[offset].toInt() and 0xFF
            val length = record[offset + 1].toInt() and 0xFF
            offset += 2
            if (record.size - offset < length) return null
            if (type == 1) {
                val data = record.copyOfRange(offset, offset + length)
                return if (data.contentEquals(token)) plainName else decrypt(data)
            }
            offset += length
        }
        return null
    }

    private fun decrypt(data: ByteArray): String? {
        if (data.size <= 28) return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(nameKey, "AES"), GCMParameterSpec(128, data, 0, 12))
            cipher.updateAAD(token)
            String(cipher.doFinal(data, 12, data.size - 12), Charsets.UTF_8)
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        fun create(): AddPhoneCode {
            val generator = KeyPairGenerator.getInstance("EC")
            generator.initialize(ECGenParameterSpec("secp256r1"))
            val x = (generator.generateKeyPair().public as ECPublicKey).w.affineX
            return AddPhoneCode(byteArrayOf(0, 0, 2) + fixed32(x))
        }

        private fun fixed32(value: BigInteger): ByteArray {
            val raw = value.toByteArray().takeLast(32).toByteArray()
            return ByteArray(32 - raw.size) + raw
        }
    }
}

/** A small QR. Whoever scans it gives this phone their real device name. */
class AddPhone(private val context: Context, private val onName: (String) -> Unit) {
    private val code = AddPhoneCode.create()
    private val main = Handler(Looper.getMainLooper())
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var listener: NsdManager.DiscoveryListener? = null
    private var multicast: WifiManager.MulticastLock? = null
    private var running = false

    fun qr(size: Int = 480): Bitmap? {
        val matrix = try {
            QRCodeWriter().encode(code.url, BarcodeFormat.QR_CODE, size, size, mapOf(EncodeHintType.MARGIN to 1))
        } catch (_: Exception) {
            return null
        }
        val pixels = IntArray(size * size) { if (matrix.get(it % size, it / size)) Color.BLACK else Color.WHITE }
        return Bitmap.createBitmap(pixels, size, size, Bitmap.Config.RGB_565)
    }

    fun start() {
        if (running) return
        running = true
        multicast = context.applicationContext.getSystemService(WifiManager::class.java)
            ?.createMulticastLock("swift-add-phone")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        scan()
    }

    fun stop() {
        running = false
        main.removeCallbacksAndMessages(null)
        endScan()
        try { multicast?.release() } catch (_: Exception) {}
        multicast = null
    }

    /** A phone changes its record after scanning, so the search is restarted to see it. */
    private fun scan() {
        if (!running) return
        endScan()
        val next = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                main.post {
                    pending.addLast(info)
                    resolveNext()
                }
            }
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {}
        }
        listener = next
        try {
            nsd?.discoverServices(QuickShareSession.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, next)
        } catch (_: Exception) {
            listener = null
        }
        main.postDelayed({ scan() }, 6_000)
    }

    private fun endScan() {
        val current = listener ?: return
        listener = null
        try { nsd?.stopServiceDiscovery(current) } catch (_: Exception) {}
    }

    private fun resolveNext() {
        if (resolving || !running) return
        val info = pending.removeFirstOrNull() ?: return
        resolving = true
        @Suppress("DEPRECATION")
        nsd?.resolveService(info, object : NsdManager.ResolveListener {
            override fun onServiceResolved(resolved: NsdServiceInfo) {
                val record = resolved.attributes["n"]?.toString(Charsets.UTF_8)
                main.post {
                    resolving = false
                    val name = record?.let { code.nameFrom(it) }?.trim()
                    if (running && !name.isNullOrEmpty()) {
                        stop()
                        onName(name)
                    } else {
                        resolveNext()
                    }
                }
            }
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                main.post {
                    resolving = false
                    resolveNext()
                }
            }
        })
    }
}
