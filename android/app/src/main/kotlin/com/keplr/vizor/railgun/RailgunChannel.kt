package com.keplr.vizor.railgun

import com.keplr.vizor.railgun.RailgunProtocol.Message
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlin.time.Duration

/**
 * One page's end of the port: requests out, replies matched back to them. Everything fails once it closes.
 * Params, results and events are raw JSON text; Dart owns the typed models.
 */
internal class RailgunChannel(
    private val post: suspend (String) -> Unit,
    private val onEvent: (Message.Event) -> Unit,
) {
    private val ids = AtomicLong()
    private val pending = ConcurrentHashMap<Long, CompletableDeferred<String>>()
    private val ready = CompletableDeferred<Unit>()

    @Volatile
    private var closedBy: RailgunException? = null

    val isOpen: Boolean get() = closedBy == null

    /** Waits for the page's hello; only this channel's own port can carry it. */
    suspend fun awaitReady(timeout: Duration) {
        withTimeoutOrNull(timeout) { ready.await() } ?: throw RailgunException.Timeout("loading the page")
    }

    suspend fun call(
        method: RailgunMethod,
        paramsJson: String,
    ): String {
        val id = ids.incrementAndGet()
        val reply = CompletableDeferred<String>()
        pending[id] = reply
        try {
            closedBy?.let { throw it.forCaller() }
            post(RailgunProtocol.request(id, method, paramsJson))
            return withTimeoutOrNull(method.timeout) { reply.await() } ?: throw RailgunException.Timeout(method.wire)
        } finally {
            pending.remove(id)
        }
    }

    fun receive(data: String?) {
        when (val message = RailgunProtocol.decode(data)) {
            Message.Ready -> ready.complete(Unit)
            is Message.Event -> onEvent(message)
            is Message.Reply -> pending.remove(message.id)?.complete(message.resultJson)
            is Message.Failure -> pending.remove(message.id)?.completeExceptionally(message.error)
            null -> Unit
        }
    }

    fun close(reason: RailgunException) {
        if (closedBy == null) closedBy = reason
        ready.completeExceptionally(reason.forCaller())
        pending.values.forEach { it.completeExceptionally(reason.forCaller()) }
    }

    // Each caller gets its own: coroutines add to what they throw, so one instance can't go to several.
    private fun RailgunException.forCaller() = RailgunException.Disconnected(message ?: "the page closed", this)
}
