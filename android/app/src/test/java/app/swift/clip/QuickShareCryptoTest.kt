package app.swift.clip

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.net.ServerSocket

class QuickShareCryptoTest {
    @Test
    fun hkdfMatchesRfc5869() {
        val ikm = ByteArray(22) { 0x0b }
        val salt = byteArrayOf(0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c)
        val info = byteArrayOf(0xf0.toByte(), 0xf1.toByte(), 0xf2.toByte(), 0xf3.toByte(), 0xf4.toByte(), 0xf5.toByte(), 0xf6.toByte(), 0xf7.toByte(), 0xf8.toByte(), 0xf9.toByte())
        val okm = QuickShareCrypto.hkdf(ikm, salt, info, 42)
        val expected = hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
        assertArrayEquals(expected, okm)
    }

    @Test
    fun agreementMatchesTheMac() {
        val secret = QuickShareCrypto.shared(
            ByteArray(32) { 0x22 },
            hex("0217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4ed"),
            hex("194a7debcb97712d2dda3ca85aa8765a56f45fc758599652f2897c65306e5794"),
        )
        assertEquals(
            "ccfc261f58193c98ca4ad4a53bbac6f0ee29bc4d48438090446908622ca79af6",
            QuickShareCrypto.magnitude(secret).toHex(),
        )
        val keys = QuickShareCrypto.derive(
            ByteArray(32) { 0x22 },
            hex("0217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4ed"),
            hex("194a7debcb97712d2dda3ca85aa8765a56f45fc758599652f2897c65306e5794"),
            "client-init-transcript".toByteArray(),
            "server-init-transcript".toByteArray(),
            server = true,
        )
        assertEquals("4c9a5e5bd1d6bb324e75d0734da659ac4b4932dab1c5e2af9313c0f70ecc4ce7", keys.encrypt.toHex())
    }

    @Test
    fun pinFormulaKeepsTheSignLikeTheMac() {
        // By hand: 1 + (-1 * 31) = -30, shown without the sign.
        assertEquals("0030", QuickShareCrypto.pin(byteArrayOf(1, -1)))
        assertEquals("0000", QuickShareCrypto.pin(ByteArray(0)))
    }

    @Test
    fun receivesAFileOnlyAfterAccept() {
        val saved = ByteArrayOutputStream()
        var savedName = ""
        var shown: IncomingOffer? = null
        receive(
            target = { name ->
                savedName = name
                memoryTarget(saved)
            },
            ask = { offer, answer ->
                shown = offer
                assertEquals("", savedName)
                answer(true)
                nothing
            },
            send = { port -> sendQuickShareTestFile("127.0.0.1", port, "hello.txt", "hi".toByteArray()) },
        )
        assertEquals("hello.txt", savedName)
        assertEquals("hi", saved.toString(Charsets.UTF_8))
        assertEquals(listOf("hello.txt"), shown?.fileNames)
        assertEquals(4, shown?.pin?.length)
    }

    @Test
    fun declineSavesNothing() {
        var opened = false
        var refused = false
        receive(
            target = { _ ->
                opened = true
                memoryTarget(ByteArrayOutputStream())
            },
            ask = { _, answer ->
                answer(false)
                nothing
            },
            send = { port ->
                try {
                    sendQuickShareTestFile("127.0.0.1", port, "hello.txt", "hi".toByteArray())
                } catch (_: IllegalStateException) {
                    refused = true
                }
            },
        )
        assertFalse(opened)
        assertTrue(refused)
    }

    @Test
    fun readsTheSenderNameFromTheConnectionRequest() {
        val name = "Rai's Mac".toByteArray()
        val info = ByteArray(17) + byteArrayOf(name.size.toByte()) + name
        val request = message(6, info)
        val v1 = message(2, request)
        assertEquals("Rai's Mac", QuickShareOffer.senderName(message(2, v1)))
        assertNull(QuickShareOffer.senderName(byteArrayOf(1)))
    }

    private val nothing: () -> Unit = {}

    private fun message(field: Int, body: ByteArray): ByteArray =
        byteArrayOf(((field shl 3) or 2).toByte(), body.size.toByte()) + body

    private fun memoryTarget(out: ByteArrayOutputStream) = object : FileTarget {
        override val out = out
        override fun commit() {}
        override fun abandon() { out.reset() }
    }

    private fun receive(
        target: (String) -> FileTarget,
        ask: (IncomingOffer, (Boolean) -> Unit) -> () -> Unit,
        send: (Int) -> Unit,
    ) {
        val server = ServerSocket(0)
        val thread = Thread {
            try {
                QuickShareSession(server.accept(), { name, _ -> target(name) }, ask).run()
            } catch (_: Exception) {
            }
        }
        thread.start()
        send(server.localPort)
        thread.join(5_000)
        server.close()
    }

    private fun hex(value: String): ByteArray {
        return ByteArray(value.length / 2) { index ->
            value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
