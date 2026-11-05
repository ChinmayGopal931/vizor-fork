package com.keplr.vizor.railgun

import android.content.Context
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Binds one Activity's Flutter engine to the process-wide anon-rpc page: the hidden page that runs the anon-rpc
 * browser harness, through whose `fetch` Rust relays every Ethereum JSON-RPC request. The page outlives the
 * Activity; only a finishing Activity closes it. It shares the host with the Railgun page ([Pages]) and needs no
 * proxy of its own: its KPS transport is WebRTC, and its few https requests ride the Railgun page's override when
 * one is set.
 *
 * Never log a call's `paramsJson`, its result or a failure's message: a `fetch` carries the RPC URL, which may hold a
 * key.
 */
class AnonRpcHostHandler(
    context: Context,
    /** Whether this build may debug the page at all (`BuildConfig.DEBUG`); `load`'s `debug` can only narrow it. */
    private val debuggable: Boolean,
) : EventChannel.StreamHandler {
    private val host = Pages.host(context.applicationContext)
    private var events: Job? = null

    fun handle(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "supported" -> result.success(true)
            "load" -> {
                val debug = debuggable && call.arg("debug") == true
                reply(result) {
                    host.load(PageKind.ANON, proxyPort = null, debug = debug)
                    null
                }
            }
            "call" -> {
                val method = (call.arg("method") as? String)?.let(AnonRpcMethod::fromWire)
                val params = call.arg("paramsJson") as? String
                if (method == null || params == null) return result.error(BAD_ARGS, "method or paramsJson", null)
                reply(result) { host.call(PageKind.ANON, method, params) }
            }
            "close" ->
                reply(result) {
                    host.close(PageKind.ANON)
                    null
                }
            "isOpen" -> result.success(host.isOpen(PageKind.ANON))
            else -> result.notImplemented()
        }
    }

    override fun onListen(
        arguments: Any?,
        sink: EventChannel.EventSink,
    ) {
        events?.cancel()
        events = Pages.scope.launch { host.events(PageKind.ANON).collect { sink.success(it) } }
    }

    override fun onCancel(arguments: Any?) {
        events?.cancel()
        events = null
    }

    /** Detaches from the engine. The page stays up across recreation, and closes when the Activity finishes. */
    fun dispose(finishing: Boolean) {
        onCancel(null)
        if (finishing) Pages.scope.launch { host.close(PageKind.ANON) }
    }

    private fun MethodCall.arg(key: String): Any? = (arguments as? Map<*, *>)?.get(key)

    // Exactly one answer per call, on the main thread. Any failure but a RailgunException gets a fixed message: its
    // own could quote a URL.
    private fun reply(
        result: MethodChannel.Result,
        block: suspend () -> Any?,
    ) {
        Pages.scope.launch {
            val outcome =
                try {
                    Result.success(block())
                } catch (e: CancellationException) {
                    result.error(CLOSED, "cancelled", null)
                    throw e
                } catch (e: Exception) {
                    Result.failure(e)
                }
            outcome.fold(
                onSuccess = { result.success(it) },
                onFailure = { e ->
                    if (e is RailgunException) {
                        result.error(e.code(), e.message, null)
                    } else {
                        result.error(FAILED, "the anon-rpc host failed", null)
                    }
                },
            )
        }
    }

    companion object {
        const val METHOD_CHANNEL = "com.zcash.wallet/anon_rpc"
        const val EVENT_CHANNEL = "com.zcash.wallet/anon_rpc/events"

        private const val BAD_ARGS = "bad_args"
        private const val CLOSED = "closed"
        private const val FAILED = "failed"

        private fun RailgunException.code() =
            when (this) {
                is RailgunException.Disconnected -> CLOSED
                is RailgunException.Timeout -> "timeout"
                is RailgunException.Unavailable -> "unavailable"
                is RailgunException.Protocol -> "protocol"
                is RailgunException.Failed -> FAILED
                is RailgunException.RpcFailed -> "rpc_failed"
            }
    }
}
