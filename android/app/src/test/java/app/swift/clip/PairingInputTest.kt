package app.swift.clip

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PairingInputTest {
    private val link = "swift://clip?host=192.168.1.9&port=47822&code=12345678&name=Rai%E2%80%99s%20Mac&key=abc_DEF-123"

    @Test
    fun aLinkPastedOnItsOwnIsFound() {
        assertEquals(link, ClipSync.extractLink(link))
        assertEquals(link, ClipSync.extractLink("  $link\n"))
    }

    @Test
    fun aLinkInsideAChatMessageIsFound() {
        assertEquals(link, ClipSync.extractLink("Pair here: $link. Thanks!"))
        assertEquals(link, ClipSync.extractLink("($link)"))
    }

    @Test
    fun somethingElseIsNotALink() {
        assertNull(ClipSync.extractLink("https://example.com/clip?code=12345678"))
        assertNull(ClipSync.extractLink("hello"))
    }

    @Test
    fun eightDigitsAreAcceptedHoweverTheyWereTyped() {
        assertEquals("12345678", ClipSync.extractCode("12345678"))
        assertEquals("12345678", ClipSync.extractCode(" 1234 5678 "))
        assertEquals("12345678", ClipSync.extractCode("1234-5678"))
    }

    @Test
    fun otherNumbersAreNotACode() {
        assertNull(ClipSync.extractCode("1234567"))
        assertNull(ClipSync.extractCode("123456789"))
        assertNull(ClipSync.extractCode("1234abcd"))
        assertNull(ClipSync.extractCode(link))
    }
}
