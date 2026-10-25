package com.keplr.vizor.privateusd

import android.security.keystore.KeyGenParameterSpec
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.ArgumentMatchers.anyString
import org.mockito.ArgumentMatchers.eq
import org.mockito.ArgumentMatchers.isNull
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import org.mockito.Mockito.verifyNoMoreInteractions
import org.mockito.Mockito.`when`
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.ProviderException
import java.security.Signature
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import kotlin.io.encoding.Base64

// zapp's `AtomicSwapAttestationTest`, as the plan asks: real P-256 keys, every signature verified, strict unpadded
// base64url, the key kept across requests and made again only once its chain expired, both key-challenge vectors,
// and StrongBox before the TEE.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class PrivateUsdAttestationHandlerTest {
    private val now = 1_792_000_000_000L
    private val year = 365L * 24 * 60 * 60 * 1000
    private val strict = Base64.UrlSafe.withPadding(Base64.PaddingOption.ABSENT)

    @Test
    fun eachRequestIsSignedByTheInstallsOneKeyWhoseChainIsSent() =
        runTest {
            val keys = Keys()
            val handler = handler(keys)
            val first = handler.sign(TESTNET, byteArrayOf(1, 2, 3))
            val second = handler.sign(TESTNET, byteArrayOf(4, 5, 6))

            assertEquals(1, keys.made)
            assertEquals(KEY_CHALLENGE_TESTNET, keys.challenges.single().toHex())
            assertEquals(setOf("chain", "signature"), first.keys)
            @Suppress("UNCHECKED_CAST")
            val chain = first["chain"] as List<String>
            assertEquals(keys.encodedChain(), chain)
            chain.forEach { strict.decode(it) }
            first.assertSignedBy(keys.key, byteArrayOf(1, 2, 3))
            second.assertSignedBy(keys.key, byteArrayOf(4, 5, 6))
            assertNotEquals(first["signature"], second["signature"])
        }

    @Test
    fun oneKeyPerIssuerWithItsOwnChallenge() =
        runTest {
            val keys = Keys()
            val handler = handler(keys)
            handler.sign(TESTNET, byteArrayOf(1))
            handler.sign(MAINNET, byteArrayOf(1))

            assertEquals(2, keys.made)
            assertEquals(
                listOf(KEY_CHALLENGE_TESTNET, KEY_CHALLENGE_MAINNET),
                keys.challenges.map { it.toHex() },
            )
            assertEquals(
                setOf("${PrivateUsdAttestationHandler.ALIAS_PREFIX}$TESTNET", "${PrivateUsdAttestationHandler.ALIAS_PREFIX}$MAINNET"),
                keys.aliases(),
            )
        }

    @Test
    fun aKeyWhoseChainHasExpiredIsMadeAgainAndItsNewChainSent() =
        runTest {
            val keys = Keys()
            val handler = handler(keys)
            val before = handler.sign(TESTNET, byteArrayOf(1))["chain"]
            keys.expire()
            val after = handler.sign(TESTNET, byteArrayOf(1))["chain"]

            assertEquals(2, keys.made)
            assertNotEquals(before, after)
            assertEquals(keys.encodedChain(), after)
        }

    @Test
    fun aKeystoreThatFailsAnswersFailedAndOneThatMakesNoKeyUnavailable() {
        val failing = Keys().apply { failure = ProviderException("keystore busy") }
        val result = mock(MethodChannel.Result::class.java)
        handler(failing).handle(MethodCall("sign", mapOf("issuerName" to TESTNET, "message" to byteArrayOf(1))), result)
        verify(result).error(eq("failed"), anyString(), isNull())
        verifyNoMoreInteractions(result)

        val none = Keys().apply { failure = AttestationUnavailable(ProviderException("no attestation")) }
        val unavailable = mock(MethodChannel.Result::class.java)
        handler(none).handle(MethodCall("sign", mapOf("issuerName" to TESTNET, "message" to byteArrayOf(1))), unavailable)
        verify(unavailable).error(eq("unavailable"), anyString(), isNull())

        val badArgs = mock(MethodChannel.Result::class.java)
        handler(Keys()).handle(MethodCall("sign", mapOf("issuerName" to "")), badArgs)
        verify(badArgs).error(eq("bad_args"), anyString(), isNull())
    }

    @Test
    fun theChannelAnswersTheChainAndSignatureOnce() {
        val keys = Keys()
        val result = mock(MethodChannel.Result::class.java)
        handler(keys).handle(MethodCall("sign", mapOf("issuerName" to TESTNET, "message" to byteArrayOf(9))), result)
        verify(result).success(
            org.mockito.ArgumentMatchers.argThat<Map<String, Any>> { answer ->
                @Suppress("UNCHECKED_CAST")
                val chain = answer["chain"] as List<String>
                chain == keys.encodedChain() && answer.assertSignedBy(keys.key, byteArrayOf(9))
            },
        )
        verifyNoMoreInteractions(result)
    }

    @Test
    fun strongBoxIsTriedFirstAndAnyFailureLeavesTheKeyToTheTee() {
        val specs = mutableListOf<KeyGenParameterSpec>()
        val fallingBack =
            AndroidAttestationKeys { spec ->
                specs += spec
                if (spec.isStrongBoxBacked) throw ProviderException("no StrongBox")
            }
        fallingBack.generate("alias", byteArrayOf(1))
        assertEquals(listOf(true, false), specs.map { it.isStrongBoxBacked })
        assertTrue(specs.all { it.attestationChallenge.contentEquals(byteArrayOf(1)) })

        val strongBox = mutableListOf<KeyGenParameterSpec>()
        AndroidAttestationKeys { strongBox += it }.generate("alias", byteArrayOf(2))
        assertEquals(listOf(true), strongBox.map { it.isStrongBoxBacked })

        val neither = AndroidAttestationKeys { throw ProviderException("no hardware") }
        try {
            neither.generate("alias", byteArrayOf(3))
            error("made a key")
        } catch (e: AttestationUnavailable) {
            assertTrue(e.cause is ProviderException)
        }
    }

    private fun handler(keys: Keys) =
        PrivateUsdAttestationHandler(
            keys,
            { now },
            TestScope(UnconfinedTestDispatcher()),
            Dispatchers.Unconfined,
        )

    private fun Map<String, Any>.assertSignedBy(
        key: KeyPair,
        message: ByteArray,
    ): Boolean {
        val verifier = Signature.getInstance("SHA256withECDSA").apply { initVerify(key.public) }
        verifier.update(message)
        val signed = verifier.verify(strict.decode(this["signature"] as String))
        assertTrue("signed by the install's key over the message", signed)
        return signed
    }

    /** A P-256 key for each [generate], whose chain's batch certificate runs out when [expire] says. */
    private inner class Keys : AttestationKeys {
        var made = 0
        var failure: Exception? = null
        val challenges = mutableListOf<ByteArray>()
        private val entries = mutableMapOf<String, Pair<KeyPair, List<X509Certificate>>>()

        val key: KeyPair get() = entries.values.last().first

        fun aliases() = entries.keys.toSet()

        fun encodedChain() = entries.values.last().second.map { PrivateUsdAttestationHandler.base64Url.encode(it.encoded) }

        fun expire() {
            val (alias, entry) = entries.entries.single()
            val (key, chain) = entry
            entries[alias] = key to listOf(chain[0], certificate("batch $made", now - 1))
        }

        override fun chain(alias: String) = entries[alias]?.second

        override fun generate(
            alias: String,
            challenge: ByteArray,
        ) {
            failure?.let { throw it }
            made++
            challenges += challenge
            val generator = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }
            val chain = listOf("leaf $made", "batch $made", "root").map { certificate(it, now + year) }
            entries[alias] = generator.generateKeyPair() to chain
        }

        override fun sign(
            alias: String,
            message: ByteArray,
        ): ByteArray =
            Signature.getInstance("SHA256withECDSA").run {
                initSign(entries.getValue(alias).first.private)
                update(message)
                sign()
            }

        private fun certificate(
            der: String,
            notAfter: Long,
        ): X509Certificate {
            val certificate = mock(X509Certificate::class.java)
            `when`(certificate.encoded).thenReturn(der.encodeToByteArray())
            `when`(certificate.notAfter).thenReturn(Date(notAfter))
            return certificate
        }
    }

    private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }

    private companion object {
        const val TESTNET = "zecswap-testnet-issuer"
        const val MAINNET = "zecswap-mainnet-issuer"
        const val KEY_CHALLENGE_TESTNET = "f5cbc5e3281d0519f8ae7efb241c7c10b7d2d52f3bde46703d1ecd0fd5613488"
        const val KEY_CHALLENGE_MAINNET = "468b7cbef07c884fec0ad6245b371dd8fc340b6d09d91fffd5b56b1ec5d942e6"
    }
}
