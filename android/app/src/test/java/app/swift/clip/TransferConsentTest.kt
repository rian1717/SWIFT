package app.swift.clip

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

class TransferConsentTest {
    @Test
    fun onlyTheFirstAnswerCounts() {
        val answers = ArrayBlockingQueue<Boolean>(2)
        val token = TransferConsent.open(60_000) { answers.put(it) }!!
        assertTrue(TransferConsent.decide(token, true))
        assertFalse(TransferConsent.decide(token, false))
        assertEquals(true, answers.poll(2, TimeUnit.SECONDS))
        assertNull(answers.poll(100, TimeUnit.MILLISECONDS))
    }

    @Test
    fun noAnswerMeansNo() {
        val answers = ArrayBlockingQueue<Boolean>(1)
        TransferConsent.open(20) { answers.put(it) }
        assertEquals(false, answers.poll(2, TimeUnit.SECONDS))
    }

    @Test
    fun aSecondSenderIsRefusedWhileOneIsOpen() {
        val token = TransferConsent.open(60_000) {}
        assertNotNull(token)
        assertNull(TransferConsent.open(60_000) {})
        TransferConsent.close(token!!)
        val next = TransferConsent.open(60_000) {}
        assertNotNull(next)
        TransferConsent.close(next!!)
    }

    @Test
    fun theLabelCannotCarryControlCharacters() {
        assertEquals("Rai", IncomingOffer.cleanLabel("Ra‮i\n"))
    }
}
