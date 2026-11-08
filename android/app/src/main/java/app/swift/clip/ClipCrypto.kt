package app.swift.clip

import java.math.BigInteger
import java.nio.ByteBuffer
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Clipboard keys. Must match `ClipboardSecurity.swift` on the Mac byte for byte.
 *
 * Pairing works out a key on each side that never crosses the network. Every
 * copy is then sealed with AES-GCM and carries a rising number, so someone on
 * the same Wi-Fi can neither read it nor send it again.
 */
internal object ClipCrypto {
    val PHONE_LABEL = "swift-clip-v2 phone".toByteArray()
    val MAC_LABEL = "swift-clip-v2 mac".toByteArray()
    private val random = SecureRandom()

    class Pair(val private: PrivateKey, val public: ByteArray)

    fun newPair(): Pair {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"), random)
        val pair = generator.generateKeyPair()
        val public = pair.public as ECPublicKey
        return Pair(pair.private, byteArrayOf(4) + fixed(public.w.affineX) + fixed(public.w.affineY))
    }

    fun privateKey(scalar: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, scalar), curve()))

    /** An uncompressed P-256 point, 65 bytes starting with 4. */
    fun isPublicKey(raw: ByteArray?): Boolean = raw != null && raw.size == 65 && raw[0] == 4.toByte()

    private fun publicKey(raw: ByteArray): PublicKey {
        require(isPublicKey(raw)) { "key" }
        val point = ECPoint(BigInteger(1, raw.copyOfRange(1, 33)), BigInteger(1, raw.copyOfRange(33, 65)))
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, curve()))
    }

    fun pairingKey(mine: PrivateKey, phonePublic: ByteArray, macPublic: ByteArray, secret: String): ByteArray {
        val agree = KeyAgreement.getInstance("ECDH")
        agree.init(mine)
        agree.doPhase(publicKey(macPublic), true)
        val shared = pad32(agree.generateSecret())
        return QuickShareCrypto.hkdf(shared, "swift-clip-v2|$secret".toByteArray(), phonePublic + macPublic, 32)
    }

    fun proof(key: ByteArray, label: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(label)
    }

    /** Constant time. */
    fun matches(given: ByteArray, key: ByteArray, label: ByteArray): Boolean =
        MessageDigest.isEqual(given, proof(key, label))

    /** `nonce ‖ ciphertext ‖ tag`, with the path and phone id authenticated. */
    fun seal(
        payload: ByteArray,
        counter: Long,
        key: ByteArray,
        path: String,
        id: String,
        nonce: ByteArray = ByteArray(12).also { random.nextBytes(it) },
    ): ByteArray {
        val plain = ByteBuffer.allocate(8 + payload.size).putLong(counter).put(payload).array()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD("$path $id".toByteArray())
        return nonce + cipher.doFinal(plain)
    }

    fun open(body: ByteArray, key: ByteArray, path: String, id: String): kotlin.Pair<Long, ByteArray> {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, body.copyOfRange(0, 12)))
        cipher.updateAAD("$path $id".toByteArray())
        val plain = cipher.doFinal(body, 12, body.size - 12)
        return ByteBuffer.wrap(plain).long to plain.copyOfRange(8, plain.size)
    }

    private fun fixed(value: BigInteger): ByteArray = pad32(value.toByteArray())

    private fun pad32(raw: ByteArray): ByteArray = when {
        raw.size == 32 -> raw
        raw.size > 32 -> raw.copyOfRange(raw.size - 32, raw.size)
        else -> ByteArray(32 - raw.size) + raw
    }

    private fun curve(): ECParameterSpec {
        val parameters = java.security.AlgorithmParameters.getInstance("EC")
        parameters.init(ECGenParameterSpec("secp256r1"))
        return parameters.getParameterSpec(ECParameterSpec::class.java)
    }
}
