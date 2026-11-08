package app.swift.clip

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The same numbers are checked on the Mac in `ClipboardCryptoVectorTests`. */
class ClipCryptoTest {
    private val macPublic = hex("040217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4ed194a7debcb97712d2dda3ca85aa8765a56f45fc758599652f2897c65306e5794")
    private val phonePublic = hex("04d65a93977caa3d1b081852ff57a79e465f1660577304baead505dd3a48589cf350185e895372df6221ea3a137557e473fddb6755f05bd507c3c533fce9c91285")
    private val phonePrivate = ClipCrypto.privateKey(ByteArray(32) { 0x22 })
    private val key = ClipCrypto.pairingKey(phonePrivate, phonePublic, macPublic, "12345678")

    @Test
    fun pairingKeyAndProofsMatchTheMac() {
        assertEquals("dadd1743181f388a2dd6e12c5b28e52e68a8af13d70b99c25d07a799a28a2647", key.toHex())
        assertEquals("7dd0453d5bd97615e500fab3871c2a8321b5831f9bd6e9b609d2eb6080939986", ClipCrypto.proof(key, ClipCrypto.PHONE_LABEL).toHex())
        assertTrue(ClipCrypto.matches(hex("9d4c0da798f383bb81b9d222597555dae4e8fce056080a1a32e030b4e626ee61"), key, ClipCrypto.MAC_LABEL))
    }

    @Test
    fun sealedCopyMatchesTheMac() {
        val sealed = ClipCrypto.seal("hello".toByteArray(), 7, key, "/clip", "abc", ByteArray(12) { it.toByte() })
        assertEquals("000102030405060708090a0bc5bac521ef475881655ca36811e652d3c025468895e985c88ac92c24a3", sealed.toHex())
        val (counter, payload) = ClipCrypto.open(sealed, key, "/clip", "abc")
        assertEquals(7L, counter)
        assertArrayEquals("hello".toByteArray(), payload)
    }

    @Test
    fun aWrongCodeGivesAKeyTheMacRejects() {
        val wrong = ClipCrypto.pairingKey(phonePrivate, phonePublic, macPublic, "12345679")
        assertFalse(ClipCrypto.matches(ClipCrypto.proof(key, ClipCrypto.MAC_LABEL), wrong, ClipCrypto.MAC_LABEL))
    }

    @Test
    fun freshKeysAreUncompressedPoints() {
        assertTrue(ClipCrypto.isPublicKey(ClipCrypto.newPair().public))
        assertFalse(ClipCrypto.isPublicKey(ByteArray(64)))
    }

    private fun hex(value: String) = ByteArray(value.length / 2) { value.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }
}
