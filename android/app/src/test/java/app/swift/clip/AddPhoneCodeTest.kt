package app.swift.clip

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class AddPhoneCodeTest {
    private val blob = byteArrayOf(0, 0, 2) + ByteArray(32) { 0x11 }
    private val code = AddPhoneCode(blob)
    // Computed separately with RFC 5869 HKDF, the same derivation the Mac uses.
    private val nameKey = hex("58ad2671fe6e28cec1759cc56f562e9d")

    @Test
    fun derivesTheSameTokenAsTheMac() {
        assertEquals("a7ea46184f2d0209fae68f3fecc1fb97", code.token.joinToString("") { "%02x".format(it) })
    }

    @Test
    fun linkIsTheFormAndroidRoutesToQuickShare() {
        assertTrue(code.url.startsWith("https://quickshare.google/qrcode#key=AAAC"))
    }

    @Test
    fun readsANameFromAHiddenPhoneThatScanned() {
        assertEquals("Rai's A32", code.nameFrom(record(hiddenHeader(), sealed("Rai's A32", nameKey))))
    }

    @Test
    fun readsThePlainNameOfAVisiblePhoneThatScanned() {
        val name = "Pixel 8".toByteArray()
        val header = byteArrayOf(0x02) + ByteArray(16) + byteArrayOf(name.size.toByte()) + name
        assertEquals("Pixel 8", code.nameFrom(record(header, code.token)))
    }

    @Test
    fun ignoresAPhoneThatScannedADifferentCode() {
        assertNull(code.nameFrom(record(hiddenHeader(), sealed("Stranger", ByteArray(16) { 7 }))))
    }

    @Test
    fun ignoresAPhoneThatScannedNothing() {
        assertNull(code.nameFrom(Base64.getUrlEncoder().withoutPadding().encodeToString(hiddenHeader())))
    }

    @Test
    fun ignoresGarbage() {
        assertNull(code.nameFrom("%%%"))
        assertNull(code.nameFrom(""))
    }

    private fun hiddenHeader() = byteArrayOf(0x32) + ByteArray(16)

    private fun record(header: ByteArray, tlv: ByteArray): String =
        Base64.getUrlEncoder().withoutPadding()
            .encodeToString(header + byteArrayOf(1, tlv.size.toByte()) + tlv)

    private fun sealed(name: String, key: ByteArray): ByteArray {
        val nonce = ByteArray(12) { 3 }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(code.token)
        return nonce + cipher.doFinal(name.toByteArray())
    }

    private fun hex(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
