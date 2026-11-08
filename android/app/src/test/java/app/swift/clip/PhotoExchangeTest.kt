package app.swift.clip

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket

class PhotoExchangeTest {
    @Test
    fun wrongCodeIsRejected() {
        val port = scripted { request ->
            PhotoExchange.decide(request, "12345678", "Rai's iPhone", "") {
                "abcdefabcdefabcdefabcdefabcdefab"
            }
        }
        val error = runCatching {
            PhotoExchange.post(
                "127.0.0.1",
                port,
                "/pair",
                mapOf("Content-Type" to "application/json"),
                """{"code":"00000000","name":"Redmi Note 14"}""".toByteArray(),
            )
        }.exceptionOrNull()
        assertTrue(error != null)
    }

    @Test
    fun pairedPhotoArrivesUnchanged() {
        val token = "abcdefabcdefabcdefabcdefabcdefab"
        val photo = "original-bytes".toByteArray()
        var seen = false
        val port = scripted(times = 2) { request ->
            val decision = PhotoExchange.decide(request, "12345678", "Rai's iPhone", token) { token }
            if (decision.photo != null) {
                assertEquals("holiday.HEIC", decision.photoName)
                assertEquals("image/heic", decision.photoType)
                assertArrayEquals(photo, decision.photo)
                seen = true
            }
            decision
        }
        val paired = PhotoExchange.post(
            "127.0.0.1",
            port,
            "/pair",
            mapOf("Content-Type" to "application/json"),
            """{"code":"12345678","name":"Redmi Note 14"}""".toByteArray(),
        )
        assertTrue(paired.contains("\"token\":\"$token\""))
        assertTrue(paired.contains("Rai's iPhone"))
        val saved = PhotoExchange.post(
            "127.0.0.1",
            port,
            "/photo",
            mapOf(
                "Authorization" to "Bearer $token",
                "Content-Type" to "image/heic",
                "X-SWIFT-Name" to "holiday.HEIC",
            ),
            photo,
        )
        assertTrue(saved.contains("ok"))
        assertTrue(seen)
    }

    private fun scripted(
        times: Int = 1,
        handler: (PhotoExchange.Incoming) -> PhotoExchange.Decision,
    ): Int {
        val server = ServerSocket(0)
        Thread {
            repeat(times) {
                val client = server.accept()
                client.use { socket ->
                    val request = PhotoExchange.read(socket.getInputStream()) ?: return@use
                    val decision = handler(request)
                    PhotoExchange.write(socket.getOutputStream(), decision.status, decision.json)
                }
            }
            server.close()
        }.start()
        return server.localPort
    }
}
