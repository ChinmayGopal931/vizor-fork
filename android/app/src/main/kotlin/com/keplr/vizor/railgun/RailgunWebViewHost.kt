package com.keplr.vizor.railgun

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.util.AndroidRuntimeException
import android.webkit.ConsoleMessage
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebMessage
import android.webkit.WebMessagePort
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.annotation.MainThread
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewFeature
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.util.concurrent.Executor
import kotlin.coroutines.resume
import kotlin.time.Duration.Companion.seconds

/**
 * Hidden WebViews that load only the page's own assets, one page at a time, each over a port of its own. Every
 * request the page makes to the network goes through the Rust bridge's loopback SOCKS5 port, so it follows the
 * wallet's route (Tor or direct).
 *
 * One instance per process, built with the application context: the page outlives Activity recreation.
 */
internal class RailgunWebViewHost(
    private val context: Context,
) {
    // With no collector an event is dropped, where iOS buffers it: Dart listens before it loads a page.
    private val mutableEvents =
        MutableSharedFlow<String>(
            extraBufferCapacity = EVENT_BUFFER,
            onBufferOverflow = BufferOverflow.DROP_OLDEST,
        )

    /** Raw event messages, `{"event": …, "data": …}`. */
    val events: SharedFlow<String> = mutableEvents.asSharedFlow()

    // The page's messages are decoded here, off the main thread.
    private val messages by lazy { Handler(HandlerThread("railgun-page").apply { start() }.looper) }

    // Main thread only.
    private var current: Page? = null

    // Main thread only. Whether a proxy override this host set may still be in force. The override is
    // process-wide and outlives the page, so it is lifted on every close; tracking it spares a close that has
    // nothing to lift from loading the WebView package.
    private var proxied = false

    /** A loaded page that is still open. */
    val isOpen: Boolean
        @MainThread get() = current?.let { it.isLoaded && it.isOpen } == true

    /**
     * Loads a fresh page, closing the one before it. Its traffic goes through the bridge at [proxyPort]. [debug]
     * enables content debugging and forwards the page's `log` events.
     */
    suspend fun load(
        proxyPort: Int,
        debug: Boolean,
    ) =
        withContext(Dispatchers.Main) {
            current?.close(RailgunException.Disconnected("a new page replaced it"))
            val page = Page(createWebView(debug), debug)
            current = page
            page.load(proxyPort)
        }

    /** Calls [method] on the loaded page; one that times out closes it. */
    suspend fun call(
        method: RailgunMethod,
        paramsJson: String,
    ): String {
        val page =
            withContext(Dispatchers.Main) { current?.takeIf { it.isLoaded && it.isOpen } }
                ?: throw RailgunException.Disconnected("no page")
        return page.call(method, paramsJson)
    }

    /** Closes the page, if any, and lifts the proxy override. Idempotent. */
    suspend fun close() =
        withContext(Dispatchers.Main) {
            current?.close(RailgunException.Disconnected("closed"))
            clearProxy()
        }

    /** Closes the page and deletes everything it stored. */
    suspend fun wipe() =
        withContext(Dispatchers.Main) {
            current?.close(RailgunException.Disconnected("wiped"))
            clearProxy()
            forget(RailgunRequests.PAGE_ORIGIN)
        }

    @SuppressLint("SetJavaScriptEnabled")
    @MainThread
    private fun createWebView(debug: Boolean): WebView =
        unavailableOnFailure {
            if (debug) WebView.setWebContentsDebuggingEnabled(true)
            WebView(context)
        }.apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            webChromeClient = Chrome(debug)
        }

    @MainThread
    private fun forget(origin: String) = unavailableOnFailure { WebStorage.getInstance() }.deleteOrigin(origin)

    /** Points every WebView in the process at the bridge, and returns once the override is in force. */
    @MainThread
    private suspend fun overrideProxy(port: Int) {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            throw RailgunException.Unavailable(UnsupportedOperationException("this WebView can't take a proxy"))
        }
        val config = ProxyConfig.Builder().addProxyRule("socks://127.0.0.1:$port").build()
        proxied = true
        withTimeoutOrNull(PROXY_TIMEOUT) {
            suspendCancellableCoroutine<Unit> { applied ->
                ProxyController.getInstance().setProxyOverride(config, DIRECT) { applied.resume(Unit) }
            }
        } ?: throw RailgunException.Timeout("setting the proxy")
    }

    @MainThread
    private fun clearProxy() {
        if (!proxied) return
        proxied = false
        ProxyController.getInstance().clearProxyOverride(DIRECT) {}
    }

    private inner class Page(
        private val view: WebView,
        private val debug: Boolean,
    ) {
        private val channel =
            RailgunChannel(::post) { event ->
                if (debug || event.name != RailgunProtocol.LOG) mutableEvents.tryEmit(event.raw)
            }

        // Main thread only.
        private var port: WebMessagePort? = null
        var isLoaded = false
            private set

        val isOpen: Boolean get() = channel.isOpen

        @MainThread
        suspend fun load(proxyPort: Int) {
            view.webViewClient = Client(this)
            try {
                // Nothing may load before the override is in place: it is process-wide and asynchronous.
                overrideProxy(proxyPort)
                // A close, or a newer load, while the override was pending has already torn this page down.
                if (!isOpen) throw RailgunException.Disconnected("closed while loading")
                view.loadUrl(RailgunRequests.PAGE_URL)
                channel.awaitReady(LOAD_TIMEOUT)
                isLoaded = true
            } finally {
                if (!isLoaded) close(RailgunException.Disconnected("the page did not load"))
            }
        }

        suspend fun call(
            method: RailgunMethod,
            paramsJson: String,
        ): String =
            try {
                channel.call(method, paramsJson)
            } catch (e: RailgunException.Timeout) {
                withContext(NonCancellable + Dispatchers.Main) { close(e) }
                throw e
            }

        @MainThread
        fun handshake() {
            if (port != null || !isOpen) return
            val (hostPort, pagePort) = view.createWebMessageChannel()
            port = hostPort
            hostPort.setWebMessageCallback(
                object : WebMessagePort.WebMessageCallback() {
                    override fun onMessage(
                        port: WebMessagePort,
                        message: WebMessage,
                    ) = channel.receive(message.data)
                },
                messages,
            )
            val hello = WebMessage(RailgunProtocol.INIT, arrayOf(pagePort))
            view.postWebMessage(hello, Uri.parse(RailgunRequests.PAGE_ORIGIN))
        }

        /** Only the current page is ever open, so lifting the process-wide override here can't strand another. */
        @MainThread
        fun close(reason: RailgunException) {
            if (current === this) current = null
            if (!isOpen) return
            channel.close(reason)
            port?.close()
            port = null
            view.destroy()
            clearProxy()
        }

        private suspend fun post(message: String) =
            withContext(Dispatchers.Main) {
                try {
                    checkNotNull(port?.takeIf { isOpen }).postMessage(WebMessage(message))
                } catch (e: IllegalStateException) {
                    throw RailgunException.Disconnected("the page closed", e)
                }
            }
    }

    private inner class Client(
        private val page: Page,
    ) : WebViewClient() {
        private val assets =
            WebViewAssetLoader
                .Builder()
                .setDomain(RailgunRequests.PAGE_HOST)
                .addPathHandler(RailgunRequests.ASSETS_PATH, OwnAssets(context))
                .build()

        override fun shouldInterceptRequest(
            view: WebView,
            request: WebResourceRequest,
        ): WebResourceResponse? {
            val url = request.url
            return when (RailgunRequests.route(url.scheme, url.host, url.port)) {
                RailgunRequests.Route.OWN_ASSET -> assets.shouldInterceptRequest(url) ?: refusal(NOT_FOUND)
                RailgunRequests.Route.ALLOWED -> null
                RailgunRequests.Route.BLOCKED -> refusal(FORBIDDEN)
            }
        }

        override fun shouldOverrideUrlLoading(
            view: WebView,
            request: WebResourceRequest,
        ) = true

        override fun onPageFinished(
            view: WebView,
            url: String,
        ) {
            if (url == RailgunRequests.PAGE_URL) page.handshake()
        }

        override fun onReceivedError(
            view: WebView,
            request: WebResourceRequest,
            error: WebResourceError,
        ) = failLoading(request)

        override fun onReceivedHttpError(
            view: WebView,
            request: WebResourceRequest,
            errorResponse: WebResourceResponse,
        ) = failLoading(request)

        // `true` keeps the app alive: the renderer died, not us. Only the page is gone.
        override fun onRenderProcessGone(
            view: WebView,
            detail: RenderProcessGoneDetail,
        ): Boolean {
            page.close(RailgunException.Disconnected("the page's renderer stopped"))
            return true
        }

        // Without its own files the page never answers, so don't wait out the load for it.
        private fun failLoading(request: WebResourceRequest) {
            val url = request.url
            val isOwnFile =
                url.host == RailgunRequests.PAGE_HOST && url.path?.startsWith(RailgunRequests.ASSETS_PATH) == true
            if (!page.isLoaded && isOwnFile) {
                page.close(RailgunException.Disconnected("the page's ${url.path} did not load"))
            }
        }
    }

    private inner class Chrome(
        private val debug: Boolean,
    ) : WebChromeClient() {
        // Consumed either way, so nothing the page prints reaches logcat.
        override fun onConsoleMessage(message: ConsoleMessage): Boolean {
            if (debug) {
                val line = "console ${message.messageLevel()}: ${message.message()}"
                mutableEvents.tryEmit(JSONObject().put("event", RailgunProtocol.LOG).put("data", line).toString())
            }
            return true
        }
    }

    // The page's own directory, and nothing else of the APK's assets.
    private class OwnAssets(
        context: Context,
    ) : WebViewAssetLoader.PathHandler {
        private val assets = WebViewAssetLoader.AssetsPathHandler(context)

        override fun handle(path: String): WebResourceResponse? = assets.handle(RailgunRequests.ASSETS_DIR + path)
    }

    private companion object {
        const val EVENT_BUFFER = 256
        const val FORBIDDEN = 403
        const val NOT_FOUND = 404
        val LOAD_TIMEOUT = 30.seconds
        val PROXY_TIMEOUT = 10.seconds
        val DIRECT = Executor(Runnable::run)

        fun refusal(status: Int) =
            WebResourceResponse("text/plain", "utf-8", status, "Refused", emptyMap(), ByteArray(0).inputStream())

        // The framework throws this when the WebView package is missing, or updating.
        inline fun <T> unavailableOnFailure(block: () -> T): T =
            try {
                block()
            } catch (e: AndroidRuntimeException) {
                throw RailgunException.Unavailable(e)
            }
    }
}

/** Where the page's requests go: its own assets, the allowed hosts over https, and nowhere else. */
internal object RailgunRequests {
    const val PAGE_HOST = "railgun.appassets.androidplatform.net"
    const val PAGE_ORIGIN = "https://$PAGE_HOST"
    const val ASSETS_DIR = "railgun/"
    const val ASSETS_PATH = "/assets/$ASSETS_DIR"
    const val PAGE_URL = "$PAGE_ORIGIN${ASSETS_PATH}index.html"
    private const val HTTPS = "https"
    private const val DEFAULT_PORT = -1

    // Never leave the WebView; the CSP governs them.
    private val LOCAL_SCHEMES = setOf("blob", "data")

    enum class Route { OWN_ASSET, ALLOWED, BLOCKED }

    fun route(
        scheme: String?,
        host: String?,
        port: Int,
    ): Route {
        val isHttps = scheme == HTTPS && port == DEFAULT_PORT
        return when {
            isHttps && host == PAGE_HOST -> Route.OWN_ASSET
            isHttps && host != null && RailgunEndpoints.allows(host) -> Route.ALLOWED
            scheme in LOCAL_SCHEMES -> Route.ALLOWED
            else -> Route.BLOCKED
        }
    }
}
