package app.swift.clip

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * Original-photo transfer between SWIFT on Android and SWIFT on iPhone.
 * The bytes are stored as sent. Nothing recompresses them.
 */
object PhotoExchange {
    const val SERVICE_TYPE = "_swiftphoto._tcp."
    const val PORT = 47824
    const val MAX_BYTES = 100 * 1024 * 1024

    data class Incoming(
        val method: String,
        val path: String,
        val headers: Map<String, String>,
        val body: ByteArray,
    )

    data class Decision(
        val status: Int,
        val json: String,
        val pairedName: String? = null,
        val issuedToken: String? = null,
        val photoName: String? = null,
        val photoType: String? = null,
        val photo: ByteArray? = null,
    )

    fun read(input: InputStream): Incoming? {
        val header = readUntil(input, byteArrayOf(13, 10, 13, 10), 64 * 1024) ?: return null
        val text = String(header, Charsets.ISO_8859_1)
        val first = text.lineSequence().firstOrNull()?.trim() ?: return null
        val parts = first.split(" ")
        if (parts.size < 2) return null
        val headers = mutableMapOf<String, String>()
        for (line in text.lineSequence().drop(1)) {
            val name = line.substringBefore(":", "").trim().lowercase()
            if (name.isEmpty()) continue
            headers[name] = line.substringAfter(":", "").trim()
        }
        val length = headers["content-length"]?.toIntOrNull() ?: 0
        if (length < 0 || length > MAX_BYTES) return null
        val body = if (length == 0) ByteArray(0) else readExactly(input, length)
        return Incoming(parts[0], parts[1].substringBefore("?"), headers, body)
    }

    fun decide(request: Incoming, expectedCode: String, hostName: String, token: String, issueToken: () -> String): Decision {
        return when {
            request.method == "POST" && request.path == "/pair" -> pair(request, expectedCode, hostName, issueToken)
            request.method == "POST" && request.path == "/photo" -> photo(request, token)
            else -> Decision(404, """{"error":"no"}""")
        }
    }

    fun write(output: OutputStream, status: Int, json: String) {
        val body = json.toByteArray(Charsets.UTF_8)
        val reason = if (status == 200) "OK" else "No"
        val text = "HTTP/1.1 $status $reason\r\nContent-Type: application/json\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
        output.write(text.toByteArray(Charsets.ISO_8859_1))
        output.write(body)
        output.flush()
    }

    fun post(host: String, port: Int, path: String, headers: Map<String, String>, body: ByteArray): String {
        val connection = (URL("http://$host:$port$path").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 8_000
            readTimeout = 120_000
            doOutput = true
            setFixedLengthStreamingMode(body.size)
            setRequestProperty("Content-Length", body.size.toString())
            headers.forEach { (key, value) -> setRequestProperty(key, value) }
        }
        connection.outputStream.use { it.write(body) }
        val stream = if (connection.responseCode in 200..299) connection.inputStream else connection.errorStream
        val text = stream?.use { String(it.readBytes(), Charsets.UTF_8) }.orEmpty()
        if (connection.responseCode !in 200..299) throw IllegalStateException(text.ifBlank { "HTTP ${connection.responseCode}" })
        return text
    }

    private fun pair(request: Incoming, expectedCode: String, hostName: String, issueToken: () -> String): Decision {
        val text = String(request.body, Charsets.UTF_8)
        val code = jsonString(text, "code")?.trim().orEmpty()
        val name = jsonString(text, "name")?.trim()?.take(80).orEmpty()
        if (code.length != 8 || code != expectedCode || name.isEmpty()) {
            return Decision(401, """{"error":"code"}""")
        }
        val token = issueToken()
        val response = """{"token":"$token","name":"${hostName.replace("\\", "\\\\").replace("\"", "\\\"")}"}"""
        return Decision(200, response, pairedName = name, issuedToken = token)
    }

    private fun photo(request: Incoming, token: String): Decision {
        val auth = request.headers["authorization"].orEmpty()
        if (token.length < 32 || auth != "Bearer $token") return Decision(401, """{"error":"pair"}""")
        val raw = request.headers["x-swift-name"].orEmpty()
        val name = java.net.URLDecoder.decode(raw, "UTF-8").substringAfterLast('/').substringAfterLast('\\').ifBlank { "photo" }
        val type = request.headers["content-type"]?.substringBefore(";")?.trim().orEmpty().ifBlank { "application/octet-stream" }
        if (request.body.isEmpty()) return Decision(400, """{"error":"empty"}""")
        return Decision(200, """{"ok":true}""", photoName = name, photoType = type, photo = request.body)
    }

    private fun jsonString(text: String, key: String): String? {
        val needle = "\"$key\""
        val start = text.indexOf(needle)
        if (start < 0) return null
        val colon = text.indexOf(':', start + needle.length)
        if (colon < 0) return null
        val open = text.indexOf('"', colon + 1)
        val close = text.indexOf('"', open + 1)
        if (open < 0 || close < 0) return null
        return text.substring(open + 1, close)
    }

    private fun readUntil(input: InputStream, marker: ByteArray, limit: Int): ByteArray? {
        val out = ByteArrayOutputStream()
        var matched = 0
        while (out.size() < limit) {
            val next = input.read()
            if (next < 0) return null
            out.write(next)
            matched = if (next.toByte() == marker[matched]) matched + 1 else if (next.toByte() == marker[0]) 1 else 0
            if (matched == marker.size) return out.toByteArray()
        }
        return null
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
}
