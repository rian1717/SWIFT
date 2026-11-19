package app.swift.clip

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec

class PhotoPageTest {
    @Test
    fun theCertificateNamesThePhoneAndPassesSafarisRules() {
        val pair = KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec("secp256r1"))
        }.generateKeyPair()
        val der = SelfSignedCert.create(pair, listOf("192.168.1.42", "127.0.0.1"), "SWIFT")
        val cert = CertificateFactory.getInstance("X.509").generateCertificate(der.inputStream()) as X509Certificate

        cert.verify(pair.public)
        cert.checkValidity()
        assertEquals(3, cert.version)
        val ips = cert.subjectAlternativeNames.filter { it[0] == 7 }.map { it[1].toString() }.toSet()
        assertEquals(setOf("192.168.1.42", "127.0.0.1"), ips)
        assertTrue(cert.extendedKeyUsage.contains("1.3.6.1.5.5.7.3.1"))
        assertEquals(-1, cert.basicConstraints)
        assertTrue(cert.keyUsage[0])
        val days = (cert.notAfter.time - cert.notBefore.time) / (24L * 3600 * 1000)
        assertTrue("Safari refuses a certificate that lives 825 days or more", days < 825)
        assertTrue(cert.serialNumber.signum() > 0)
    }

    @Test
    fun onlyPhotosAndVideosAreAccepted() {
        assertTrue(PhotoRules.isMedia("image/jpeg"))
        assertTrue(PhotoRules.isMedia("image/heic"))
        assertTrue(PhotoRules.isMedia("video/mp4"))
        assertFalse(PhotoRules.isMedia("image/svg+xml"))
        assertFalse(PhotoRules.isMedia("text/html"))
        assertFalse(PhotoRules.isMedia(""))
    }

    @Test
    fun aPreviewIsDecodedSmallButNotTooSmall() {
        assertEquals(8, PhotoRules.thumbSample(4000, 3000, 480))
        assertEquals(1, PhotoRules.thumbSample(400, 300, 480))
        assertEquals(1, PhotoRules.thumbSample(800, 600, 480))
        assertEquals(16, PhotoRules.thumbSample(9000, 12000, 480))
    }

    @Test
    fun aVideoCanBeReadInParts() {
        assertEquals(0L to 1L, PhotoRules.parseRange("bytes=0-1", 100))
        assertEquals(50L to 99L, PhotoRules.parseRange("bytes=50-", 100))
        assertEquals(90L to 99L, PhotoRules.parseRange("bytes=-10", 100))
        assertEquals(10L to 99L, PhotoRules.parseRange("bytes=10-500", 100))
        assertNull(PhotoRules.parseRange(null, 100))
        assertNull(PhotoRules.parseRange("bytes=200-", 100))
        assertNull(PhotoRules.parseRange("bytes=0-1,5-6", 100))
        assertNull(PhotoRules.parseRange("items=0-1", 100))
    }

    @Test
    fun theMessageSaysHowManyAreReady() {
        assertEquals("20 items are ready. Scan the code with the iPhone camera.", PhotoRules.addedMessage(20, 0, 20))
        assertEquals("1 item is ready. Scan the code with the iPhone camera. 2 could not be added.", PhotoRules.addedMessage(1, 2, 1))
        assertEquals("Those could not be added. Only photos and videos work.", PhotoRules.addedMessage(0, 3, 0))
        assertEquals(
            "56 items are ready. Scan the code with the iPhone camera. This phone's storage is full, so 16 could not be added.",
            PhotoRules.addedMessage(56, 16, 56, full = true),
        )
        assertEquals("This phone's storage is full. Free some space, then send them again.", PhotoRules.addedMessage(0, 4, 0, full = true))
    }
}
