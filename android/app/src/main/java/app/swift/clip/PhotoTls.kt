package app.swift.clip

import android.content.Context
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.InetAddress
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext

/**
 * The secure (https) copy of the iPhone page. Safari saves several photos to
 * Photos at once only on a secure page. No certificate authority signs an address
 * on a home Wi-Fi, so the phone signs its own and Safari warns once.
 */
internal object PhotoTls {
    private const val KEY_FILE = "iphone-tls.key"
    private const val CERT_FILE = "iphone-tls.cer"

    fun context(context: Context, hosts: List<String>): SSLContext {
        val (key, cert) = load(context, hosts) ?: create(context, hosts)
        val password = "swift".toCharArray()
        val store = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setKeyEntry("swift", key, password, arrayOf(cert))
        }
        val keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply {
            init(store, password)
        }
        return SSLContext.getInstance("TLS").apply { init(keys.keyManagers, null, SecureRandom()) }
    }

    /** The saved certificate, while it still names these addresses and has a month left. */
    private fun load(context: Context, hosts: List<String>): Pair<PrivateKey, X509Certificate>? = try {
        val keyFile = File(context.filesDir, KEY_FILE)
        val certFile = File(context.filesDir, CERT_FILE)
        val cert = CertificateFactory.getInstance("X.509")
            .generateCertificate(certFile.inputStream().buffered()) as X509Certificate
        val named = cert.subjectAlternativeNames.orEmpty()
            .filter { it.size >= 2 && it[0] == 7 }
            .map { it[1].toString() }
            .toSet()
        val monthAhead = Date(System.currentTimeMillis() + 30L * 24 * 3600 * 1000)
        if (named != hosts.toSet() || cert.notAfter.before(monthAhead)) {
            null
        } else {
            val key = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(keyFile.readBytes()))
            key to cert
        }
    } catch (_: Exception) {
        null
    }

    private fun create(context: Context, hosts: List<String>): Pair<PrivateKey, X509Certificate> {
        val pair = KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec("secp256r1"))
        }.generateKeyPair()
        val der = SelfSignedCert.create(pair, hosts, "SWIFT")
        val cert = CertificateFactory.getInstance("X.509").generateCertificate(der.inputStream()) as X509Certificate
        File(context.filesDir, KEY_FILE).writeBytes(pair.private.encoded)
        File(context.filesDir, CERT_FILE).writeBytes(der)
        return pair.private to cert
    }
}

/**
 * A minimal X.509 certificate, written by hand. Safari on iPhone needs the
 * address in it (subject alternative name), the server-auth purpose and a life
 * under 825 days, and Android's own certificate maker sets none of these.
 */
internal object SelfSignedCert {
    private const val DAY = 24L * 3600 * 1000
    private const val ECDSA_SHA256 = "1.2.840.10045.4.3.2"

    fun create(
        pair: KeyPair,
        ips: List<String>,
        name: String,
        now: Long = System.currentTimeMillis(),
        random: SecureRandom = SecureRandom(),
    ): ByteArray {
        val algorithm = seq(oid(ECDSA_SHA256))
        val serial = ByteArray(16).also { random.nextBytes(it) }
        serial[0] = ((serial[0].toInt() and 0x3f) or 0x40).toByte()
        val dn = seq(set(seq(oid("2.5.4.3"), tlv(0x0C, name.toByteArray(Charsets.UTF_8)))))
        val validity = seq(time(now - DAY), time(now + 397 * DAY))
        val addresses = ips.map { tlv(0x87, InetAddress.getByName(it).address) }
        val extensions = tlv(
            0xA3,
            seq(
                extension("2.5.29.19", critical = true, value = seq()),
                extension("2.5.29.15", critical = true, value = tlv(0x03, byteArrayOf(7, 0x80.toByte()))),
                extension("2.5.29.37", critical = false, value = seq(oid("1.3.6.1.5.5.7.3.1"))),
                extension("2.5.29.17", critical = false, value = seq(*addresses.toTypedArray())),
            ),
        )
        val tbs = seq(
            tlv(0xA0, tlv(0x02, byteArrayOf(2))),
            tlv(0x02, serial),
            algorithm,
            dn,
            validity,
            dn,
            pair.public.encoded,
            extensions,
        )
        val signature = Signature.getInstance("SHA256withECDSA").run {
            initSign(pair.private)
            update(tbs)
            sign()
        }
        return seq(tbs, algorithm, tlv(0x03, byteArrayOf(0) + signature))
    }

    private fun extension(id: String, critical: Boolean, value: ByteArray): ByteArray =
        if (critical) {
            seq(oid(id), tlv(0x01, byteArrayOf(0xFF.toByte())), tlv(0x04, value))
        } else {
            seq(oid(id), tlv(0x04, value))
        }

    private fun time(millis: Long): ByteArray {
        val format = SimpleDateFormat("yyMMddHHmmss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
        return tlv(0x17, format.format(Date(millis)).toByteArray(Charsets.US_ASCII))
    }

    private fun oid(dotted: String): ByteArray {
        val arcs = dotted.split('.').map { it.toLong() }
        val out = ByteArrayOutputStream()
        out.write((arcs[0] * 40 + arcs[1]).toInt())
        for (arc in arcs.drop(2)) {
            val chunks = ArrayList<Int>()
            var rest = arc
            do {
                chunks.add((rest and 0x7f).toInt())
                rest = rest shr 7
            } while (rest > 0)
            for (index in chunks.indices.reversed()) {
                out.write(if (index > 0) chunks[index] or 0x80 else chunks[index])
            }
        }
        return tlv(0x06, out.toByteArray())
    }

    private fun seq(vararg parts: ByteArray): ByteArray = tlv(0x30, parts.fold(ByteArray(0)) { a, b -> a + b })

    private fun set(vararg parts: ByteArray): ByteArray = tlv(0x31, parts.fold(ByteArray(0)) { a, b -> a + b })

    private fun tlv(tag: Int, content: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(tag)
        val length = content.size
        when {
            length < 0x80 -> out.write(length)
            length < 0x100 -> { out.write(0x81); out.write(length) }
            length < 0x10000 -> { out.write(0x82); out.write(length shr 8); out.write(length and 0xff) }
            else -> { out.write(0x83); out.write(length shr 16); out.write((length shr 8) and 0xff); out.write(length and 0xff) }
        }
        out.write(content)
        return out.toByteArray()
    }
}
