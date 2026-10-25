package com.keplr.vizor.railgun

import android.content.Context
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Binds one Activity's Flutter engine to the process-wide Railgun page. The host and its page outlive the Activity;
 * only a finishing Activity closes the page.
 *
 * Never log a call's `paramsJson`, its result or a failure's message: `start` carries keyed RPC URLs, `openWallet`
 * and `deleteWallet` the wallet's mnemonic, and engine errors can quote either.
 */
class RailgunHostHandler(
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
            // Every Android build can host the page (minSdk 30); answered without loading the WebView package. A
            // WebView without `PROXY_OVERRIDE` still fails `load` with `unavailable`.
            "supported" -> result.success(true)
            "load" -> {
                val port = (call.arg("proxyPort") as? Number)?.toInt()
                if (port == null || port !in 1..65535) return result.error(BAD_ARGS, "proxyPort", null)
                val debug = debuggable && call.arg("debug") == true
                reply(result) {
                    host.load(port, debug)
                    null
                }
            }
            "call" -> {
                val method = (call.arg("method") as? String)?.let(RailgunMethod::fromWire)
                val params = call.arg("paramsJson") as? String
                if (method == null || params == null) return result.error(BAD_ARGS, "method or paramsJson", null)
                reply(result) { host.call(method, params) }
            }
            "close" ->
                reply(result) {
                    host.close()
                    null
                }
            "wipe" ->
                reply(result) {
                    host.wipe()
                    null
                }
            "isOpen" -> result.success(host.isOpen)
            else -> result.notImplemented()
        }
    }

    // Called on the main thread; so is every event sent, since the scope runs there.
    override fun onListen(
        arguments: Any?,
        sink: EventChannel.EventSink,
    ) {
        events?.cancel()
        events = Pages.scope.launch { host.events.collect { sink.success(it) } }
    }

    override fun onCancel(arguments: Any?) {
        events?.cancel()
        events = null
    }

    /** Detaches from the engine. The page stays up across recreation, and closes when the Activity finishes. */
    fun dispose(finishing: Boolean) {
        onCancel(null)
        if (finishing) Pages.scope.launch { host.close() }
    }

    private fun MethodCall.arg(key: String): Any? = (arguments as? Map<*, *>)?.get(key)

    // Exactly one answer per call, on the main thread: a second one crashes the engine, and none hangs Dart. Any
    // failure but a RailgunException gets a fixed message, as on iOS: its own could quote a URL.
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
                        result.error(FAILED, "the Railgun host failed", null)
                    }
                },
            )
        }
    }

    companion object {
        const val METHOD_CHANNEL = "com.zcash.wallet/railgun"
        const val EVENT_CHANNEL = "com.zcash.wallet/railgun/events"

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

    /** The process-level host, built once with the application context. */
    private object Pages {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

        @Volatile
        private var shared: RailgunWebViewHost? = null

        fun host(context: Context): RailgunWebViewHost =
            shared ?: synchronized(this) {
                shared ?: RailgunWebViewHost(context.applicationContext).also { shared = it }
            }
    }
}
