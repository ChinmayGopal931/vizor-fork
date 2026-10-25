package com.keplr.vizor.privateusd

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.security.GeneralSecurityException
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.ProviderException
import java.security.Signature
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import kotlin.io.encoding.Base64

/**
 * This install's attestation key for a Privacy Pass token issuer, in the Android Keystore and attested by the phone's
 * secure hardware up to Google's root, which the issuer counts each day's tokens against (plan M4, reference §5.9).
 * One key per issuer (`vizor_privateusd_attest_<issuerName>`): one app serves both networks, and a key attested for
 * the testnet issuer counts for nothing at the mainnet one. A key is made once, and again only once a certificate in
 * its chain has expired: one made because the issuer refused the last, or had none left for it, would be a fresh
 * allowance (X4). Nothing here is ever deleted.
 *
 * `sign {issuerName, message}` answers `{chain, signature}`: the chain leaf first, each DER, and `SHA256withECDSA`
 * over the message, every one base64url without padding. Keystore work runs on [io] under a mutex. `unavailable`
 * when the phone makes no attested key; `failed` when the keystore fails otherwise. Never log a message or a chain.
 */
class PrivateUsdAttestationHandler internal constructor(
    private val keys: AttestationKeys,
    private val nowMillis: () -> Long,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher,
) {
    constructor() : this(
        AndroidAttestationKeys(),
        System::currentTimeMillis,
        CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
        Dispatchers.IO,
    )

    private val lock = Mutex()

    fun handle(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "sign" -> {
                val issuer = call.argument<String>("issuerName")
                val message = call.argument<ByteArray>("message")
                if (issuer.isNullOrEmpty() || message == null) {
                    return result.error(BAD_ARGS, "issuerName or message", null)
                }
                reply(result) { sign(issuer, message) }
            }
            else -> result.notImplemented()
        }
    }

    /** The key's chain and its signature over [message], the key made first if there is none or its chain expired. */
    suspend fun sign(
        issuer: String,
        message: ByteArray,
    ): Map<String, Any> =
        lock.withLock {
            withContext(io) {
                val alias = ALIAS_PREFIX + issuer
                val chain = chain(alias, issuer)
                val signature = keys.sign(alias, message)
                mapOf(
                    "chain" to chain.map { base64Url.encode(it.encoded) },
                    "signature" to base64Url.encode(signature),
                )
            }
        }

    private fun chain(
        alias: String,
        issuer: String,
    ): List<X509Certificate> {
        val kept = keys.chain(alias)
        if (kept != null && kept.none { nowMillis() > it.notAfter.time }) return kept
        keys.generate(alias, keyChallenge(issuer))
        return checkNotNull(keys.chain(alias)) { "the keystore has no key just made" }
    }

    // Exactly one answer per call, on the scope's thread. A generation the hardware refuses is `unavailable`; any
    // other keystore failure `failed`. Neither message names the issuer's challenge or the key.
    private fun reply(
        result: MethodChannel.Result,
        block: suspend () -> Any?,
    ) {
        scope.launch {
            val outcome =
                try {
                    Result.success(block())
                } catch (e: CancellationException) {
                    result.error(FAILED, "cancelled", null)
                    throw e
                } catch (e: Exception) {
                    Result.failure(e)
                }
            outcome.fold(
                onSuccess = { result.success(it) },
                onFailure = { e ->
                    when (e) {
                        is AttestationUnavailable -> result.error(UNAVAILABLE, "this phone makes no attested key", null)
                        is GeneralSecurityException, is ProviderException ->
                            result.error(FAILED, "the keystore failed", null)
                        else -> result.error(FAILED, "the attestation failed", null)
                    }
                },
            )
        }
    }

    companion object {
        const val CHANNEL = "com.zcash.wallet/private_usd_attestation"
        const val ALIAS_PREFIX = "vizor_privateusd_attest_"

        private const val BAD_ARGS = "bad_args"
        private const val UNAVAILABLE = "unavailable"
        private const val FAILED = "failed"

        /** The key's attestation challenge: `SHA-256("zecswap-issuer-v1" ‖ issuerName)`. */
        fun keyChallenge(issuer: String): ByteArray =
            MessageDigest.getInstance("SHA-256").digest("zecswap-issuer-v1".toByteArray() + issuer.toByteArray())

        val base64Url: Base64 = Base64.UrlSafe.withPadding(Base64.PaddingOption.ABSENT_OPTIONAL)
    }
}

/** The phone has no secure hardware that attests a key, in StrongBox or the TEE. */
internal class AttestationUnavailable(
    cause: Throwable,
) : Exception("no attested key can be made", cause)

/** The secure hardware's side of the install's key: the Android Keystore, or a stand-in in tests. */
internal interface AttestationKeys {
    /** The chain of the key under [alias], leaf first, or none if there's no key. */
    fun chain(alias: String): List<X509Certificate>?

    /** Makes a key under [alias], in place of any there, attested for [challenge]. */
    fun generate(
        alias: String,
        challenge: ByteArray,
    )

    /** The key's `SHA256withECDSA` signature of [message], DER. */
    fun sign(
        alias: String,
        message: ByteArray,
    ): ByteArray
}

/**
 * EC P-256 signing keys in the Android Keystore: StrongBox where the phone has one, the TEE otherwise, used without
 * the user unlocking anything (fetches run while the user does something else). [generator] makes a key from its spec,
 * the Keystore's `KeyPairGenerator` unless a test stands in.
 */
internal class AndroidAttestationKeys(
    private val generator: (KeyGenParameterSpec) -> Unit = ::generateInKeystore,
) : AttestationKeys {
    override fun chain(alias: String) = keyStore().getCertificateChain(alias)?.map { it as X509Certificate }

    override fun generate(
        alias: String,
        challenge: ByteArray,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && generatedInStrongBox(alias, challenge)) return
        try {
            generator(spec(alias, challenge).build())
        } catch (e: ProviderException) {
            // StrongBoxUnavailableException among them for StrongBox; here the TEE refused too.
            throw AttestationUnavailable(e)
        }
    }

    override fun sign(
        alias: String,
        message: ByteArray,
    ): ByteArray =
        Signature.getInstance("SHA256withECDSA").run {
            initSign(keyStore().getKey(alias, null) as PrivateKey)
            update(message)
            sign()
        }

    private fun generatedInStrongBox(
        alias: String,
        challenge: ByteArray,
    ) = try {
        generator(spec(alias, challenge).setIsStrongBoxBacked(true).build())
        true
    } catch (_: ProviderException) {
        // Any StrongBox failure leaves the key to the TEE.
        false
    }

    private fun spec(
        alias: String,
        challenge: ByteArray,
    ) = KeyGenParameterSpec
        .Builder(alias, KeyProperties.PURPOSE_SIGN)
        .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
        .setDigests(KeyProperties.DIGEST_SHA256)
        .setAttestationChallenge(challenge)

    private fun keyStore() = KeyStore.getInstance(PROVIDER).apply { load(null) }

    private companion object {
        const val PROVIDER = "AndroidKeyStore"

        fun generateInKeystore(spec: KeyGenParameterSpec) {
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, PROVIDER).run {
                initialize(spec)
                generateKeyPair()
            }
        }
    }
}
