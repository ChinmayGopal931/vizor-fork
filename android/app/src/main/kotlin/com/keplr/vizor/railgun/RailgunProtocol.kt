package com.keplr.vizor.railgun

import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/** A call a hidden page answers: its wire name, and how long it may take. */
internal interface PageMethod {
    val wire: String
    val timeout: Duration
}

/** Every call the Railgun page answers, its wire name, and how long it may take; the page's side is `index.js`. */
internal enum class RailgunMethod(
    override val wire: String,
    override val timeout: Duration,
) : PageMethod {
    START("start", 2.minutes),
    OPEN_WALLET("openWallet", 1.minutes),

    // A wallet's first sync reads all of Railgun's history, half an hour or more on Ethereum, and keeps none of it
    // until it's done; a timeout closes the page, which starts it over.
    REFRESH("refresh", 2.hours),

    // Local only: it opens the page's database without a provider, on a page loaded for it alone.
    DELETE_WALLET("deleteWallet", 1.minutes),
    TRANSFER("transfer", 10.minutes),
    UNSHIELD("unshield", 10.minutes),
    BROADCASTER_FEE("broadcasterFee", 2.minutes),
    REVERSE_COST("reverseCost", 30.seconds),
    PREPARE_REVERSE("prepareReverse", 10.minutes),
    ;

    companion object {
        fun fromWire(wire: String): RailgunMethod? = entries.firstOrNull { it.wire == wire }
    }
}

/**
 * Every call the anon-rpc page answers (`android/anon-rpc-web/src/index.js`): the page runs the anon-rpc browser
 * harness, and every Ethereum JSON-RPC request Rust relays goes through its `fetch`.
 */
internal enum class AnonRpcMethod(
    override val wire: String,
    override val timeout: Duration,
) : PageMethod {
    // One unanonymized read of the worker's specifier, then the bundle (up to 64 MiB) from a resolver.
    START("start", 2.minutes),

    // A Tor client bootstrapping through a gateway, or a mixnet client joining its network.
    AWAIT_READY("awaitReady", 5.minutes),

    // Each request carries its own timeout in its params; this is the backstop behind it.
    FETCH("fetch", 3.minutes),
    STATUS("status", 10.seconds),
    STOP("stop", 30.seconds),
    ;

    companion object {
        fun fromWire(wire: String): AnonRpcMethod? = entries.firstOrNull { it.wire == wire }
    }
}

/** The page's wire format. Params, results and events stay raw JSON text; Dart owns the typed models. */
internal object RailgunProtocol {
    /** The Railgun page's hello on the port it was handed; it must equal `INIT` in `index.js`. */
    const val INIT = "vizor-railgun-init"

    /** The anon-rpc page's hello; it must equal `INIT` in `anon-rpc-web/src/index.js`. */
    const val ANON_INIT = "vizor-anon-rpc-init"

    /** Engine and console lines; forwarded only from a page loaded with `debug`. */
    const val LOG = "log"

    // The Railgun page's events, and the anon-rpc page's `status`.
    private val EVENTS = setOf(LOG, "scan", "proof", "screening", "refresh", "status")

    sealed interface Message {
        data object Ready : Message

        /** A whole event message, `{"event": name, "data": …}`, as the page sent it. */
        data class Event(
            val name: String,
            val raw: String,
        ) : Message

        data class Reply(
            val id: Long,
            val resultJson: String,
        ) : Message

        data class Failure(
            val id: Long,
            val error: RailgunException,
        ) : Message
    }

    /** `paramsJson` must be exactly one JSON object, so it can't add keys to the envelope around it. */
    fun request(
        id: Long,
        method: PageMethod,
        paramsJson: String,
    ): String {
        val single =
            try {
                val tokener = JSONTokener(paramsJson)
                tokener.nextValue() is JSONObject && tokener.nextClean() == 0.toChar()
            } catch (e: JSONException) {
                false
            }
        if (!single) throw RailgunException.Protocol("${method.wire} params must be one JSON object")
        // Spliced, not re-serialized: org.json would turn large numbers into doubles.
        return "{\"id\":$id,\"method\":${JSONObject.quote(method.wire)},\"params\":$paramsJson}"
    }

    /** Null for what this build can't read, except a reply: that one still fails its call. */
    fun decode(data: String?): Message? {
        if (data == null) return null
        val message =
            try {
                JSONTokener(data).nextValue() as? JSONObject
            } catch (e: JSONException) {
                null
            } ?: return null
        if (message.has("event")) {
            val event = message.opt("event") as? String ?: return null
            return when (event) {
                "ready" -> Message.Ready
                in EVENTS -> Message.Event(event, data)
                else -> null
            }
        }
        val id = (message.opt("id") as? Number)?.toLong() ?: return null
        val error = message.opt("error")
        if (error != null && error != JSONObject.NULL) {
            val wire = error as? JSONObject ?: return Message.Failure(id, unreadable())
            return Message.Failure(id, wire.toException())
        }
        return Message.Reply(id, rawJson(message.opt("result")))
    }

    // `get("result").toString()` would drop a string's quotes and print null oddly.
    private fun rawJson(value: Any?): String =
        when (value) {
            is String -> JSONObject.quote(value)
            JSONObject.NULL, null -> "null"
            else -> value.toString()
        }

    private fun JSONObject.toException(): RailgunException {
        val message = optString("message").ifEmpty { "the page failed" }
        return when (optString("code")) {
            "BAD_REQUEST" -> RailgunException.Protocol(message)
            "RPC_FAILED" -> RailgunException.RpcFailed(message)
            else -> RailgunException.Failed(message)
        }
    }

    private fun unreadable() = RailgunException.Protocol("the page's reply is unreadable")
}
