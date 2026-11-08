package app.swift.clip

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Speaks Quick Share's receive side. The Mac already browses
 * `_FC9F5ED42C8A._tcp` and sends through this handshake, so the phone can
 * stay inside SWIFT and still show up as a receiver.
 */
class QuickShareSession(
    private val socket: Socket,
    private val begin: (name: String, size: Long) -> FileTarget,
    /** Shows the offer and returns how to take it away again. Nothing is saved until `answer(true)`. */
    private val ask: (offer: IncomingOffer, answer: (Boolean) -> Unit) -> () -> Unit,
) {
    private var sender = IncomingOffer.UNKNOWN_SENDER
    private var pin = ""

    @Volatile private var declined = false
    private var finished = false

    fun run() {
        socket.tcpNoDelay = true
        socket.soTimeout = 120_000
        val input = socket.getInputStream()
        val output = socket.getOutputStream()
        try {
            val clientInit = handshake(input, output)
            exchange(input, output, clientInit)
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
    }

    private fun handshake(input: InputStream, output: OutputStream): Codec {
        // The transcript starts at the next frame. The name is only a label: the PIN is the check.
        QuickShareOffer.senderName(readFrame(input))?.let { sender = it }
        val clientInitBytes = readFrame(input)
        val ours = QuickShareCrypto.generate()
        val random = ByteArray(32).also { random.nextBytes(it) }
        val serverInitBytes = QuickShareProto.serverInit(ours.wireX, ours.wireY, random)
        writeFrame(output, serverInitBytes)

        val clientFinished = readFrame(input)
        val peer = QuickShareProto.peerPoint(clientFinished)
        val keys = QuickShareCrypto.derive(
            ours.privateRaw, peer.first, peer.second, clientInitBytes, serverInitBytes, server = true
        )
        pin = QuickShareCrypto.pin(keys.auth)
        readFrame(input) // peer connection response
        writeFrame(output, QuickShareProto.connectionAccept())
        return Codec(keys)
    }

    private fun exchange(input: InputStream, output: OutputStream, codec: Codec) {
        val link = Link(input, output, codec)
        link.sendSetup(QuickShareProto.pairedKeyEncryption())
        val open = ConcurrentHashMap<Long, OpenFile>()
        var offered = false
        var dismiss: (() -> Unit)? = null
        try {
            while (!declined) {
                when (val event = link.next()) {
                    Event.Encryption -> link.sendSetup(QuickShareProto.pairedKeyResult())
                    Event.Result -> Unit
                    is Event.Introduction -> {
                        if (offered) return
                        if (event.files.isEmpty() || event.files.size > 64) {
                            link.sendSetup(QuickShareProto.sharingResponse(4))
                            return
                        }
                        if (event.files.any { it.size < 0 || it.size > MAX_FILE }) {
                            link.sendSetup(QuickShareProto.sharingResponse(3))
                            return
                        }
                        offered = true
                        val offer = IncomingOffer(sender, pin, event.files.map { it.name }, event.files.sumOf { it.size })
                        // Keep reading while the person decides, so a cancel from the sender is seen.
                        dismiss = ask(offer) { accepted -> respond(link, event.files, open, accepted) }
                    }
                    is Event.Chunk -> {
                        // Nothing is open until the person accepts, so early bytes end the session.
                        val current = open[event.id] ?: return
                        if (event.offset != current.written) {
                            open.remove(event.id)?.target?.abandon()
                            return
                        }
                        if (event.body.isNotEmpty()) {
                            if (current.written + event.body.size > current.size) {
                                open.remove(event.id)?.target?.abandon()
                                return
                            }
                            current.target.out.write(event.body)
                            current.written += event.body.size
                        }
                        if (event.last) {
                            if (current.written != current.size) {
                                open.remove(event.id)?.target?.abandon()
                                return
                            }
                            current.target.out.flush()
                            current.target.commit()
                            open.remove(event.id)
                            if (open.isEmpty()) return
                        }
                    }
                    Event.KeepAlive -> link.sendKeepAlive()
                    is Event.Response -> Unit
                    Event.Cancel, Event.Disconnect, Event.Done -> return
                }
            }
        } finally {
            dismiss?.invoke()
            synchronized(open) {
                finished = true
                abandonAll(open)
            }
        }
    }

    /** Runs on the thread that delivered the decision, never the one reading the socket. */
    private fun respond(
        link: Link,
        files: List<OfferedFile>,
        open: MutableMap<Long, OpenFile>,
        accepted: Boolean,
    ) {
        try {
            synchronized(open) {
                if (finished) return
                if (!accepted) {
                    declined = true
                    link.sendSetup(QuickShareProto.sharingResponse(2))
                    return
                }
                try {
                    for (file in files) open[file.id] = OpenFile(file.size, begin(file.name, file.size))
                } catch (_: Exception) {
                    abandonAll(open)
                    declined = true
                    link.sendSetup(QuickShareProto.sharingResponse(3))
                    return
                }
                link.sendSetup(QuickShareProto.sharingResponse(1))
            }
        } catch (_: Exception) {
            try { socket.close() } catch (_: Exception) {}
        }
    }

    private fun abandonAll(open: MutableMap<Long, OpenFile>) {
        for (file in open.values) {
            try { file.target.abandon() } catch (_: Exception) {}
        }
        open.clear()
    }

    private class OpenFile(val size: Long, val target: FileTarget) {
        var written = 0L
    }

    companion object {
        private const val MAX_FILE = 2L * 1024 * 1024 * 1024
        private val random = SecureRandom()

        const val SERVICE_TYPE = "_FC9F5ED42C8A._tcp."

        fun endpointInfo(name: String): ByteArray {
            val raw = name.toByteArray(Charsets.UTF_8)
            val nameBytes = if (raw.size > 255) raw.copyOf(255) else raw
            val out = ByteArrayOutputStream()
            out.write(2) // phone
            out.write(ByteArray(16).also { random.nextBytes(it) })
            out.write(nameBytes.size)
            out.write(nameBytes)
            return out.toByteArray()
        }

        fun serviceInstanceName(): String {
            val id = ByteArray(4).also { random.nextBytes(it) }
            val blob = byteArrayOf(0x23) + id + byteArrayOf(0xFC.toByte(), 0x9F.toByte(), 0x5E, 0, 0)
            return "bd" + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(blob)
        }

        fun txtName(info: ByteArray): String {
            return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(info)
        }
    }
}

interface FileTarget {
    val out: OutputStream
    fun commit()
    fun abandon()
}

private class Link(
    private val input: InputStream,
    private val output: OutputStream,
    private val codec: Codec,
) {
    private var sendSeq = 0
    private var recvSeq = 0
    private val bytes = HashMap<Long, ByteArrayOutputStream>()
    private val expected = HashMap<Long, Long>()

    @Synchronized
    fun sendSetup(body: ByteArray) {
        val id = randomId()
        sendOffline(QuickShareProto.payload(id, 1, body.size.toLong(), 0, 0, body))
        sendOffline(QuickShareProto.payload(id, 1, body.size.toLong(), body.size.toLong(), 1, ByteArray(0)))
    }

    @Synchronized
    fun sendKeepAlive() {
        sendOffline(QuickShareProto.keepAlive())
    }

    @Synchronized
    fun sendFile(id: Long, body: ByteArray) {
        sendOffline(QuickShareProto.payload(id, 2, body.size.toLong(), 0, 0, body))
        sendOffline(QuickShareProto.payload(id, 2, body.size.toLong(), body.size.toLong(), 1, ByteArray(0)))
    }

    fun next(): Event {
        while (true) {
            val plain = codec.open(readFrame(input))
            val message = QuickShareProto.deviceMessage(plain)
            recvSeq += 1
            if (message.second != recvSeq) throw IllegalStateException("sequence")
            when (val frame = QuickShareProto.offline(message.first)) {
                is Offline.KeepAlive -> return Event.KeepAlive
                is Offline.Disconnect -> return Event.Disconnect
                is Offline.Payload -> {
                    val event = take(frame) ?: continue
                    return event
                }
                Offline.Other -> continue
            }
        }
    }

    private fun take(frame: Offline.Payload): Event? {
        if (frame.payloadType == 1) {
            val buf = bytes.getOrPut(frame.id) { ByteArrayOutputStream() }
            expected[frame.id] = frame.total
            if (frame.offset != buf.size().toLong()) throw IllegalStateException("offset")
            if (frame.body.isNotEmpty()) buf.write(frame.body)
            if (!frame.last) return null
            bytes.remove(frame.id)
            val body = buf.toByteArray()
            return QuickShareProto.sharing(body)
        }
        if (frame.payloadType == 2) {
            return Event.Chunk(frame.id, frame.offset, frame.body, frame.last)
        }
        return null
    }

    private fun sendOffline(frame: ByteArray) {
        sendSeq += 1
        val d2d = ProtoWriter().apply {
            bytes(1, frame)
            int32(2, sendSeq)
        }.toByteArray()
        writeFrame(output, codec.seal(d2d))
    }

    private fun randomId(): Long {
        val bytes = ByteArray(8).also { SecureRandom().nextBytes(it) }
        return java.nio.ByteBuffer.wrap(bytes).long
    }
}

private sealed class Event {
    data object Encryption : Event()
    data object Result : Event()
    data class Introduction(val files: List<OfferedFile>) : Event()
    data class Chunk(val id: Long, val offset: Long, val body: ByteArray, val last: Boolean) : Event()
    data class Response(val status: Int) : Event()
    data object KeepAlive : Event()
    data object Disconnect : Event()
    data object Cancel : Event()
    data object Done : Event()
}

private data class OfferedFile(val id: Long, val name: String, val size: Long)

private sealed class Offline {
    data object KeepAlive : Offline()
    data object Disconnect : Offline()
    data object Other : Offline()
    data class Payload(
        val id: Long,
        val payloadType: Int,
        val total: Long,
        val offset: Long,
        val body: ByteArray,
        val last: Boolean,
    ) : Offline()
}

private class Codec(keys: SessionKeys) {
    private val encryptKey = keys.encrypt
    private val decryptKey = keys.decrypt
    private val sendMac = keys.sendMac
    private val recvMac = keys.recvMac

    fun seal(plain: ByteArray): ByteArray {
        val iv = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(encryptKey, "AES"), IvParameterSpec(iv))
        val ciphertext = cipher.doFinal(plain)
        val metadata = ProtoWriter().apply {
            int32(1, 13)
            int32(2, 1)
        }.toByteArray()
        val header = ProtoWriter().apply {
            int32(1, 1) // HMAC-SHA256
            int32(2, 2) // AES-256-CBC
            bytes(5, iv)
            bytes(6, metadata)
        }.toByteArray()
        val headerAndBody = ProtoWriter().apply {
            bytes(1, header)
            bytes(2, ciphertext)
        }.toByteArray()
        return ProtoWriter().apply {
            bytes(1, headerAndBody)
            bytes(2, hmac(sendMac, headerAndBody))
        }.toByteArray()
    }

    fun open(message: ByteArray): ByteArray {
        var headerAndBody: ByteArray? = null
        var signature: ByteArray? = null
        val reader = ProtoReader(message)
        while (true) {
            val tag = reader.next() ?: break
            when {
                tag.field == 1 && tag.wire == 2 -> headerAndBody = reader.bytes()
                tag.field == 2 && tag.wire == 2 -> signature = reader.bytes()
                else -> reader.skip(tag.wire)
            }
        }
        val bodyBytes = headerAndBody ?: throw IllegalStateException("secure")
        val sig = signature ?: throw IllegalStateException("secure")
        val expected = hmac(recvMac, bodyBytes)
        if (!expected.contentEquals(sig)) throw IllegalStateException("mac")
        var header: ByteArray? = null
        var ciphertext: ByteArray? = null
        val inner = ProtoReader(bodyBytes)
        while (true) {
            val tag = inner.next() ?: break
            when {
                tag.field == 1 && tag.wire == 2 -> header = inner.bytes()
                tag.field == 2 && tag.wire == 2 -> ciphertext = inner.bytes()
                else -> inner.skip(tag.wire)
            }
        }
        var iv: ByteArray? = null
        val headerReader = ProtoReader(header ?: throw IllegalStateException("header"))
        while (true) {
            val tag = headerReader.next() ?: break
            if (tag.field == 5 && tag.wire == 2) iv = headerReader.bytes() else headerReader.skip(tag.wire)
        }
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(decryptKey, "AES"), IvParameterSpec(iv))
        return cipher.doFinal(ciphertext)
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }
}

internal data class SessionKeys(
    val encrypt: ByteArray,
    val decrypt: ByteArray,
    val sendMac: ByteArray,
    val recvMac: ByteArray,
    val auth: ByteArray,
)

internal object QuickShareCrypto {
    private val d2dSalt = byteArrayOf(
        0x82.toByte(), 0xAA.toByte(), 0x55, 0xA0.toByte(), 0xD3.toByte(), 0x97.toByte(), 0xF8.toByte(),
        0x83.toByte(), 0x46, 0xCA.toByte(), 0x1C, 0xEE.toByte(), 0x8D.toByte(), 0x39, 0x09, 0xB9.toByte(),
        0x5F, 0x13, 0xFA.toByte(), 0x7D, 0xEB.toByte(), 0x1D, 0x4A, 0xB3.toByte(), 0x83.toByte(), 0x76,
        0xB8.toByte(), 0x25, 0x6D, 0xA8.toByte(), 0x55, 0x10,
    )

    data class Key(val privateRaw: ByteArray, val wireX: ByteArray, val wireY: ByteArray)

    /** The 4-digit code. Signed bytes and a signed remainder, the same as the Mac. */
    fun pin(auth: ByteArray): String {
        var hash = 0
        var multiplier = 1
        for (byte in auth) {
            hash = (hash + byte * multiplier) % 9973
            multiplier = (multiplier * 31) % 9973
        }
        return "%04d".format(java.util.Locale.ROOT, kotlin.math.abs(hash))
    }

    fun generate(): Key {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        val pair = generator.generateKeyPair()
        val pub = pair.public as java.security.interfaces.ECPublicKey
        val priv = pair.private as java.security.interfaces.ECPrivateKey
        val raw = unsigned(priv.s.toByteArray(), 32)
        return Key(raw, signed(unsigned(pub.w.affineX.toByteArray(), 32)), signed(unsigned(pub.w.affineY.toByteArray(), 32)))
    }

    fun derive(
        privateRaw: ByteArray,
        peerX: ByteArray,
        peerY: ByteArray,
        clientInit: ByteArray,
        serverInit: ByteArray,
        server: Boolean,
    ): SessionKeys {
        val secret = shared(privateRaw, peerX, peerY)
        val derived = sha256(magnitude(secret))
        val transcript = clientInit + serverInit
        val auth = hkdf(derived, "UKEY2 v1 auth".toByteArray(), transcript, 32)
        val next = hkdf(derived, "UKEY2 v1 next".toByteArray(), transcript, 32)
        val client = hkdf(next, d2dSalt, "client".toByteArray(), 32)
        val serverKey = hkdf(next, d2dSalt, "server".toByteArray(), 32)
        val salt = sha256("SecureMessage".toByteArray())
        val clientEnc = hkdf(client, salt, "ENC:2".toByteArray(), 32)
        val clientSig = hkdf(client, salt, "SIG:1".toByteArray(), 32)
        val serverEnc = hkdf(serverKey, salt, "ENC:2".toByteArray(), 32)
        val serverSig = hkdf(serverKey, salt, "SIG:1".toByteArray(), 32)
        return if (server) {
            SessionKeys(serverEnc, clientEnc, serverSig, clientSig, auth)
        } else {
            SessionKeys(clientEnc, serverEnc, clientSig, serverSig, auth)
        }
    }

    fun shared(privateRaw: ByteArray, peerX: ByteArray, peerY: ByteArray): ByteArray {
        val params = curve()
        val factory = KeyFactory.getInstance("EC")
        val priv = factory.generatePrivate(ECPrivateKeySpec(java.math.BigInteger(1, privateRaw), params))
        val x = unsigned(peerX, 32)
        val y = unsigned(peerY, 32)
        val pub = factory.generatePublic(
            ECPublicKeySpec(ECPoint(java.math.BigInteger(1, x), java.math.BigInteger(1, y)), params)
        )
        val agree = KeyAgreement.getInstance("ECDH")
        agree.init(priv)
        agree.doPhase(pub, true)
        return agree.generateSecret()
    }

    private fun curve(): java.security.spec.ECParameterSpec {
        val parameters = java.security.AlgorithmParameters.getInstance("EC")
        parameters.init(ECGenParameterSpec("secp256r1"))
        return parameters.getParameterSpec(java.security.spec.ECParameterSpec::class.java)
    }

    fun magnitude(secret: ByteArray): ByteArray {
        val normalized = when {
            secret.size == 33 && secret[0] == 0.toByte() -> secret.copyOfRange(1, secret.size)
            secret.size < 32 -> ByteArray(32 - secret.size) + secret
            else -> secret
        }
        var i = 0
        while (i < normalized.size && normalized[i] == 0.toByte()) i++
        return normalized.copyOfRange(i, normalized.size)
    }

    private fun sha256(data: ByteArray): ByteArray {
        return MessageDigest.getInstance("SHA-256").digest(data)
    }

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val extract = Mac.getInstance("HmacSHA256")
        extract.init(SecretKeySpec(salt, "HmacSHA256"))
        val prk = extract.doFinal(ikm)
        val okm = ByteArray(length)
        var previous = ByteArray(0)
        var offset = 0
        var counter = 1
        while (offset < length) {
            val expand = Mac.getInstance("HmacSHA256")
            expand.init(SecretKeySpec(prk, "HmacSHA256"))
            expand.update(previous)
            expand.update(info)
            expand.update(counter.toByte())
            previous = expand.doFinal()
            val take = minOf(previous.size, length - offset)
            previous.copyInto(okm, offset, 0, take)
            offset += take
            counter++
        }
        return okm
    }

    private fun unsigned(bytes: ByteArray, width: Int): ByteArray {
        var i = 0
        while (i < bytes.size - 1 && bytes[i] == 0.toByte()) i++
        val mag = bytes.copyOfRange(i, bytes.size)
        if (mag.size > width) throw IllegalArgumentException("coordinate")
        return ByteArray(width - mag.size) + mag
    }

    private fun signed(unsigned: ByteArray): ByteArray {
        var i = 0
        while (i < unsigned.size - 1 && unsigned[i] == 0.toByte()) i++
        val mag = unsigned.copyOfRange(i, unsigned.size)
        if (mag.isEmpty()) return byteArrayOf(0)
        return if (mag[0].toInt() and 0x80 != 0) byteArrayOf(0) + mag else mag
    }
}

internal object QuickShareOffer {
    /** The sender's name from its connection request, or null when it did not give one. */
    fun senderName(frame: ByteArray): String? = try {
        val v1 = field(frame, 2)
        val request = v1?.let { field(it, 2) }
        val info = request?.let { field(it, 6) }
        // One flag byte and 16 metadata bytes come before the length-prefixed name.
        if (info == null || info.size < 18) {
            null
        } else {
            val length = info[17].toInt() and 0xFF
            if (length == 0 || 18 + length > info.size) {
                null
            } else {
                IncomingOffer.cleanLabel(String(info, 18, length, Charsets.UTF_8)).ifEmpty { null }
            }
        }
    } catch (_: Exception) {
        null
    }

    private fun field(message: ByteArray, number: Int): ByteArray? {
        val reader = ProtoReader(message)
        while (true) {
            val tag = reader.next() ?: return null
            if (tag.field == number && tag.wire == 2) return reader.bytes()
            reader.skip(tag.wire)
        }
    }
}

private object QuickShareProto {
    fun serverInit(x: ByteArray, y: ByteArray, random: ByteArray): ByteArray {
        val point = ProtoWriter().apply {
            bytes(1, x)
            bytes(2, y)
        }.toByteArray()
        val generic = ProtoWriter().apply {
            int32(1, 1)
            bytes(2, point)
        }.toByteArray()
        val init = ProtoWriter().apply {
            int32(1, 1)
            bytes(2, random)
            int32(3, 100)
            bytes(4, generic)
        }.toByteArray()
        return ProtoWriter().apply {
            int32(1, 3)
            bytes(2, init)
        }.toByteArray()
    }

    fun serverPoint(serverInitFrame: ByteArray): Pair<ByteArray, ByteArray> {
        val key = nested(nested(serverInitFrame, 2), 4)
        val point = nested(key, 2)
        return unsigned32(fieldBytes(point, 1)) to unsigned32(fieldBytes(point, 2))
    }

    fun introduction(name: String, size: Long, id: Long): ByteArray {
        val meta = ProtoWriter().apply {
            bytes(1, name.toByteArray(Charsets.UTF_8))
            int32(2, 5)
            int64(3, id)
            int64(4, size)
            bytes(5, "application/octet-stream".toByteArray())
        }.toByteArray()
        val intro = ProtoWriter().apply { bytes(1, meta) }.toByteArray()
        return sharing(1, 2, intro)
    }

    fun peerPoint(clientFinishedFrame: ByteArray): Pair<ByteArray, ByteArray> {
        val key = nested(clientFinishedFrame, 2).let { nested(it, 1) }
        val point = nested(key, 2)
        return unsigned32(fieldBytes(point, 1)) to unsigned32(fieldBytes(point, 2))
    }

    fun connectionAccept(): ByteArray {
        val os = ProtoWriter().apply { int32(1, 1) }.toByteArray()
        val response = ProtoWriter().apply {
            int32(1, 0)
            int32(3, 1)
            bytes(4, os)
        }.toByteArray()
        val v1 = ProtoWriter().apply {
            int32(1, 2)
            bytes(3, response)
        }.toByteArray()
        return ProtoWriter().apply {
            int32(1, 1)
            bytes(2, v1)
        }.toByteArray()
    }

    fun pairedKeyEncryption(): ByteArray {
        val inner = ProtoWriter().apply {
            bytes(1, ByteArray(72).also { SecureRandom().nextBytes(it) })
            bytes(2, ByteArray(6).also { SecureRandom().nextBytes(it) })
        }.toByteArray()
        return sharing(3, 4, inner)
    }

    fun pairedKeyResult(): ByteArray {
        val inner = ProtoWriter().apply { int32(1, 3) }.toByteArray()
        return sharing(4, 5, inner)
    }

    fun sharingResponse(status: Int): ByteArray {
        val inner = ProtoWriter().apply { int32(1, status) }.toByteArray()
        return sharing(2, 3, inner)
    }

    fun payload(id: Long, type: Int, total: Long, offset: Long, flags: Int, body: ByteArray): ByteArray {
        val header = ProtoWriter().apply {
            int64(1, id)
            int32(2, type)
            int64(3, total)
            int32(4, 0)
        }.toByteArray()
        val chunk = ProtoWriter().apply {
            int32(1, flags)
            int64(2, offset)
            if (body.isNotEmpty()) bytes(3, body)
        }.toByteArray()
        val transfer = ProtoWriter().apply {
            int32(1, 1)
            bytes(2, header)
            bytes(3, chunk)
        }.toByteArray()
        val v1 = ProtoWriter().apply {
            int32(1, 3)
            bytes(4, transfer)
        }.toByteArray()
        return ProtoWriter().apply {
            int32(1, 1)
            bytes(2, v1)
        }.toByteArray()
    }

    fun keepAlive(): ByteArray {
        val alive = ProtoWriter().apply { int32(1, 1) }.toByteArray()
        val v1 = ProtoWriter().apply {
            int32(1, 5)
            bytes(6, alive)
        }.toByteArray()
        return ProtoWriter().apply {
            int32(1, 1)
            bytes(2, v1)
        }.toByteArray()
    }

    fun deviceMessage(plain: ByteArray): Pair<ByteArray, Int> {
        var message: ByteArray? = null
        var sequence = 0
        val reader = ProtoReader(plain)
        while (true) {
            val tag = reader.next() ?: break
            when {
                tag.field == 1 && tag.wire == 2 -> message = reader.bytes()
                tag.field == 2 && tag.wire == 0 -> sequence = reader.varint().toInt()
                else -> reader.skip(tag.wire)
            }
        }
        return (message ?: throw IllegalStateException("d2d")) to sequence
    }

    fun offline(frame: ByteArray): Offline {
        val v1 = nested(frame, 2)
        val type = fieldVarint(v1, 1).toInt()
        return when (type) {
            5 -> Offline.KeepAlive
            6 -> Offline.Disconnect
            3 -> {
                val transfer = nested(v1, 4)
                val header = nested(transfer, 2)
                val chunk = nested(transfer, 3)
                val flags = fieldVarint(chunk, 1).toInt()
                Offline.Payload(
                    id = fieldVarint(header, 1),
                    payloadType = fieldVarint(header, 2).toInt(),
                    total = fieldVarint(header, 3),
                    offset = fieldVarint(chunk, 2),
                    body = optionalBytes(chunk, 3),
                    last = flags and 1 == 1,
                )
            }
            else -> Offline.Other
        }
    }

    fun sharing(body: ByteArray): Event {
        val v1 = try { nested(body, 2) } catch (_: Exception) { return Event.Done }
        return when (fieldVarint(v1, 1).toInt()) {
            1 -> Event.Introduction(files(nested(v1, 2)))
            2 -> Event.Response(fieldVarint(nested(v1, 3), 1).toInt())
            3 -> Event.Encryption
            4 -> Event.Result
            6 -> Event.Cancel
            else -> Event.Done
        }
    }

    private fun files(introduction: ByteArray): List<OfferedFile> {
        val out = mutableListOf<OfferedFile>()
        val reader = ProtoReader(introduction)
        while (true) {
            val tag = reader.next() ?: break
            if (tag.field == 1 && tag.wire == 2) {
                val meta = reader.bytes()
                val name = optionalString(meta, 1).ifBlank { "file" }.substringAfterLast('/').substringAfterLast('\\')
                out += OfferedFile(fieldVarint(meta, 3), name, fieldVarint(meta, 4))
            } else {
                reader.skip(tag.wire)
            }
        }
        return out
    }

    private fun sharing(type: Int, field: Int, inner: ByteArray): ByteArray {
        val v1 = ProtoWriter().apply {
            int32(1, type)
            bytes(field, inner)
        }.toByteArray()
        return ProtoWriter().apply {
            int32(1, 1)
            bytes(2, v1)
        }.toByteArray()
    }

    private fun nested(message: ByteArray, field: Int): ByteArray = fieldBytes(message, field)

    private fun fieldBytes(message: ByteArray, field: Int): ByteArray {
        val reader = ProtoReader(message)
        while (true) {
            val tag = reader.next() ?: throw IllegalStateException("field $field")
            if (tag.field == field && tag.wire == 2) return reader.bytes()
            reader.skip(tag.wire)
        }
    }

    private fun optionalBytes(message: ByteArray, field: Int): ByteArray {
        val reader = ProtoReader(message)
        while (true) {
            val tag = reader.next() ?: return ByteArray(0)
            if (tag.field == field && tag.wire == 2) return reader.bytes()
            reader.skip(tag.wire)
        }
    }

    private fun optionalString(message: ByteArray, field: Int): String {
        return String(optionalBytes(message, field), Charsets.UTF_8)
    }

    private fun fieldVarint(message: ByteArray, field: Int): Long {
        val reader = ProtoReader(message)
        while (true) {
            val tag = reader.next() ?: return 0
            if (tag.field == field && tag.wire == 0) return reader.varint()
            reader.skip(tag.wire)
        }
    }

    private fun unsigned32(bytes: ByteArray): ByteArray {
        var i = 0
        while (i < bytes.size - 1 && bytes[i] == 0.toByte()) i++
        val mag = bytes.copyOfRange(i, bytes.size)
        if (mag.size > 32) throw IllegalArgumentException("coordinate")
        return ByteArray(32 - mag.size) + mag
    }
}

private class ProtoWriter {
    private val out = ByteArrayOutputStream()

    fun int32(field: Int, value: Int) {
        tag(field, 0)
        varint(value.toLong())
    }

    fun int64(field: Int, value: Long) {
        tag(field, 0)
        varint(value)
    }

    fun bytes(field: Int, value: ByteArray) {
        tag(field, 2)
        varint(value.size.toLong())
        out.write(value)
    }

    fun toByteArray(): ByteArray = out.toByteArray()

    private fun tag(field: Int, wire: Int) {
        varint((field.toLong() shl 3) or wire.toLong())
    }

    private fun varint(value: Long) {
        var v = value
        while (true) {
            val b = (v and 0x7F).toInt()
            v = v ushr 7
            if (v == 0L) {
                out.write(b)
                return
            }
            out.write(b or 0x80)
        }
    }
}

private class ProtoReader(private val data: ByteArray) {
    private var index = 0

    data class Tag(val field: Int, val wire: Int)

    fun next(): Tag? {
        if (index >= data.size) return null
        val tag = varint()
        return Tag((tag ushr 3).toInt(), (tag and 7).toInt())
    }

    fun varint(): Long {
        var result = 0L
        var shift = 0
        while (shift < 64) {
            if (index >= data.size) throw IllegalStateException("varint")
            val b = data[index++].toInt() and 0xFF
            result = result or ((b.toLong() and 0x7F) shl shift)
            if (b and 0x80 == 0) return result
            shift += 7
        }
        throw IllegalStateException("varint")
    }

    fun bytes(): ByteArray {
        val length = varint().toInt()
        if (length < 0 || index + length > data.size) throw IllegalStateException("bytes")
        val slice = data.copyOfRange(index, index + length)
        index += length
        return slice
    }

    fun skip(wire: Int) {
        when (wire) {
            0 -> varint()
            1 -> index += 8
            2 -> {
                val length = varint().toInt()
                index += length
            }
            5 -> index += 4
            else -> throw IllegalStateException("wire $wire")
        }
    }
}

private fun readFrame(input: InputStream): ByteArray {
    val header = readExactly(input, 4)
    val length = ((header[0].toInt() and 0xFF) shl 24) or
        ((header[1].toInt() and 0xFF) shl 16) or
        ((header[2].toInt() and 0xFF) shl 8) or
        (header[3].toInt() and 0xFF)
    if (length <= 0 || length > 5 * 1024 * 1024) throw IllegalStateException("frame $length")
    return readExactly(input, length)
}

private fun writeFrame(output: OutputStream, frame: ByteArray) {
    val length = frame.size
    output.write(
        byteArrayOf(
            (length ushr 24).toByte(),
            (length ushr 16).toByte(),
            (length ushr 8).toByte(),
            length.toByte(),
        )
    )
    output.write(frame)
    output.flush()
}

internal fun sendQuickShareTestFile(host: String, port: Int, name: String, body: ByteArray) {
    Socket(host, port).use { socket ->
        socket.tcpNoDelay = true
        socket.soTimeout = 5_000
        val input = socket.getInputStream()
        val output = socket.getOutputStream()
        val ours = QuickShareCrypto.generate()
        writeFrame(output, byteArrayOf(1))
        val clientInit = ProtoWriter().apply {
            int32(1, 2)
            bytes(2, ByteArray(32))
        }.toByteArray()
        writeFrame(output, clientInit)
        val serverInit = readFrame(input)
        val peer = QuickShareProto.serverPoint(serverInit)
        val point = ProtoWriter().apply {
            bytes(1, ours.wireX)
            bytes(2, ours.wireY)
        }.toByteArray()
        val generic = ProtoWriter().apply {
            int32(1, 1)
            bytes(2, point)
        }.toByteArray()
        val finished = ProtoWriter().apply { bytes(1, generic) }.toByteArray()
        val clientFinished = ProtoWriter().apply {
            int32(1, 4)
            bytes(2, finished)
        }.toByteArray()
        writeFrame(output, clientFinished)
        val keys = QuickShareCrypto.derive(
            ours.privateRaw, peer.first, peer.second, clientInit, serverInit, server = false
        )
        writeFrame(output, QuickShareProto.connectionAccept())
        readFrame(input)
        val link = Link(input, output, Codec(keys))
        link.sendSetup(QuickShareProto.pairedKeyEncryption())
        var sawEncryption = false
        var sawResult = false
        while (!sawEncryption || !sawResult) {
            when (link.next()) {
                Event.Encryption -> {
                    sawEncryption = true
                    link.sendSetup(QuickShareProto.pairedKeyResult())
                }
                Event.Result -> sawResult = true
                Event.KeepAlive -> link.sendKeepAlive()
                else -> throw IllegalStateException("unexpected handshake event")
            }
        }
        link.sendSetup(QuickShareProto.introduction(name, body.size.toLong(), 42))
        while (true) {
            when (val event = link.next()) {
                is Event.Response -> {
                    if (event.status != 1) throw IllegalStateException("rejected ${event.status}")
                    break
                }
                Event.KeepAlive -> link.sendKeepAlive()
                else -> throw IllegalStateException("waiting for accept")
            }
        }
        link.sendFile(42, body)
    }
}

private fun readExactly(input: InputStream, count: Int): ByteArray {
    val out = ByteArray(count)
    var offset = 0
    while (offset < count) {
        val read = input.read(out, offset, count - offset)
        if (read < 0) throw IllegalStateException("closed")
        offset += read
    }
    return out
}
