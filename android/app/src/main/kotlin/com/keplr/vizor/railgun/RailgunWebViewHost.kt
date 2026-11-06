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
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.annotation.MainThread
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewFeature
import java.util.EnumMap
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

/** The hidden pages the host runs: the Railgun page, and the anon-rpc page whose `fetch` Rust relays through. */
internal enum class PageKind { RAILGUN, ANON }

/** Where one page's requests may go, and how it is addressed. */
internal class PageSite(
    val kind: PageKind,
    /** The asset loader's domain: one origin per page, so neither page reads the other's storage. */
    val host: String,
    /** The page's directory under the APK's assets. */
    val assetsDir: String,
    /** The page's hello on the port it is handed. */
    val init: String,
    /**
     * Whether the page's traffic must go through the bridge: the process-wide proxy override is set before such a
     * page loads and lifted when it closes. A page without it still rides an override another page set.
     */
    val needsProxy: Boolean,
    val route: (scheme: String?, host: String?, port: Int) -> RailgunRequests.Route,
) {
    val origin = "https://$host"
    val assetsPath = "/assets/$assetsDir"
    val url = "$origin${assetsPath}index.html"
}

internal fun PageKind.site(): PageSite =
    when (this) {
        PageKind.RAILGUN -> RailgunRequests.SITE
        PageKind.ANON -> AnonRpcRequests.SITE
    }

/**
 * Hidden WebViews that load only a page's own assets, one page of each kind at a time. Every request the Railgun
 * page makes to the network goes through the Rust bridge's loopback SOCKS5 port, so it follows the wallet's route
 * (Tor or direct); the anon-rpc page needs no proxy of its own.
 *
 * One instance per process, built with the application context: the pages outlive Activity recreation.
 */
internal class RailgunWebViewHost(
    private val context: Context,
) {
    // With no collector an event is dropped, where iOS buffers it: Dart listens before it loads a page.
    private val flows: Map<PageKind, MutableSharedFlow<String>> =
        PageKind.entries.associateWith {
            MutableSharedFlow(extraBufferCapacity = EVENT_BUFFER, onBufferOverflow = BufferOverflow.DROP_OLDEST)
        }

    /** The Railgun page's raw event messages, `{"event": …, "data": …}`. */
    val events: SharedFlow<String> get() = events(PageKind.RAILGUN)

    /** A page's raw event messages, `{"event": …, "data": …}`. */
    fun events(kind: PageKind): SharedFlow<String> = flows.getValue(kind).asSharedFlow()

    // The pages' messages are decoded here, off the main thread.
    private val messages by lazy { Handler(HandlerThread("hidden-pages").apply { start() }.looper) }

    // Main thread only: the open page of each kind.
    private val pages = EnumMap<PageKind, Page>(PageKind::class.java)

    // Main thread only. Whether a proxy override this host set may still be in force. The override is
    // process-wide and outlives the page, so it is lifted on every close; tracking it spares a close that has
    // nothing to lift from loading the WebView package.
    private var proxied = false

    /** A loaded Railgun page that is still open. */
    val isOpen: Boolean
        @MainThread get() = isOpen(PageKind.RAILGUN)

    @MainThread
    fun isOpen(kind: PageKind): Boolean = pages[kind]?.let { it.isLoaded && it.isOpen } == true

    /** Loads a fresh Railgun page whose traffic goes through the bridge at [proxyPort]. */
    suspend fun load(
        proxyPort: Int,
        debug: Boolean,
    ) = load(PageKind.RAILGUN, proxyPort, debug)

    /**
     * Loads a fresh [kind] page, closing the one before it. A page that needs the bridge goes through [proxyPort].
     * [debug] enables content debugging and forwards the page's `log` events.
     */
    suspend fun load(
        kind: PageKind,
        proxyPort: Int?,
        debug: Boolean,
    ) = withContext(Dispatchers.Main) {
        val site = kind.site()
        if (site.needsProxy && proxyPort == null) throw RailgunException.Protocol("the ${kind.name} page needs a bridge")
        pages[kind]?.close(RailgunException.Disconnected("a new page replaced it"))
        val page = Page(site, createWebView(debug), debug)
        pages[kind] = page
        page.load(proxyPort)
    }

    /** Calls [method] on the loaded Railgun page; one that times out closes it. */
    suspend fun call(
        method: RailgunMethod,
        paramsJson: String,
    ): String = call(PageKind.RAILGUN, method, paramsJson)

    /** Calls [method] on the loaded [kind] page; one that times out closes it. */
    suspend fun call(
        kind: PageKind,
        method: PageMethod,
        paramsJson: String,
    ): String {
        val page =
            withContext(Dispatchers.Main) { pages[kind]?.takeIf { it.isLoaded && it.isOpen } }
                ?: throw RailgunException.Disconnected("no page")
        return page.call(method, paramsJson)
    }

    /** Closes the Railgun page, if any, and lifts the proxy override. Idempotent. */
    suspend fun close() = close(PageKind.RAILGUN)

    /** Closes the [kind] page, if any; a page that set the proxy override lifts it. Idempotent. */
    suspend fun close(kind: PageKind) =
        withContext(Dispatchers.Main) {
            pages[kind]?.close(RailgunException.Disconnected("closed"))
            if (kind.site().needsProxy) clearProxy()
        }

    /** Closes the Railgun page and deletes everything it stored. */
    suspend fun wipe() = wipe(PageKind.RAILGUN)

    /** Closes the [kind] page and deletes everything its origin stored. */
    suspend fun wipe(kind: PageKind) =
        withContext(Dispatchers.Main) {
            val site = kind.site()
            pages[kind]?.close(RailgunException.Disconnected("wiped"))
            if (site.needsProxy) clearProxy()
            forget(site.origin)
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
            // The page is served over https (asset loader) but its RPC providers,
            // under anonymous RPC, point at the http loopback relay. The default
            // never-allow mixed-content mode blocks that request before it leaves
            // the WebView. The request interceptor still blocks every host but the
            // allowlist and http only for 127.0.0.1, so this does not widen reach.
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
        }

    @MainThread
    private fun forget(origin: String) = unavailableOnFailure { WebStorage.getInstance() }.deleteOrigin(origin)

    /** Points every WebView in the process at the bridge, and returns once the override is in force. */
    @MainThread
    private suspend fun overrideProxy(port: Int) {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            throw RailgunException.Unavailable(UnsupportedOperationException("this WebView can't take a proxy"))
        }
        // The anon-rpc loopback relay (http://127.0.0.1:<relayPort>) that the page's RPC
        // providers point at must be reached directly. Without a loopback bypass the
        // page's reads to it are themselves sent through this SOCKS proxy and never
        // arrive, so Railgun never gets a block number and the page fails to start.
        // Everything else (POI nodes, the indexer, screening, artifacts) still goes
        // through the bridge.
        val config =
            ProxyConfig
                .Builder()
                .addProxyRule("socks://127.0.0.1:$port")
                .addBypassRule("127.0.0.1")
                .addBypassRule("localhost")
                .build()
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
        private val site: PageSite,
        private val view: WebView,
        private val debug: Boolean,
    ) {
        private val channel =
            RailgunChannel(::post) { event ->
                if (debug || event.name != RailgunProtocol.LOG) flows.getValue(site.kind).tryEmit(event.raw)
            }

        // Main thread only.
        private var port: WebMessagePort? = null
        var isLoaded = false
            private set

        val isOpen: Boolean get() = channel.isOpen

        @MainThread
        suspend fun load(proxyPort: Int?) {
            view.webChromeClient = Chrome(site.kind, debug)
            view.webViewClient = Client(this, site)
            try {
                // Nothing may load before the override is in place: it is process-wide and asynchronous.
                if (site.needsProxy) overrideProxy(checkNotNull(proxyPort))
                // A close, or a newer load, while the override was pending has already torn this page down.
                if (!isOpen) throw RailgunException.Disconnected("closed while loading")
                view.loadUrl(site.url)
                channel.awaitReady(LOAD_TIMEOUT)
                isLoaded = true
            } finally {
                if (!isLoaded) close(RailgunException.Disconnected("the page did not load"))
            }
        }

        suspend fun call(
            method: PageMethod,
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
            val hello = WebMessage(site.init, arrayOf(pagePort))
            view.postWebMessage(hello, Uri.parse(site.origin))
        }

        /** Only the current page of its kind is ever open, and only the Railgun page owns the process-wide override. */
        @MainThread
        fun close(reason: RailgunException) {
            if (pages[site.kind] === this) pages.remove(site.kind)
            if (!isOpen) return
            channel.close(reason)
            port?.close()
            port = null
            view.destroy()
            if (site.needsProxy) clearProxy()
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
        private val site: PageSite,
    ) : WebViewClient() {
        private val assets =
            WebViewAssetLoader
                .Builder()
                .setDomain(site.host)
                .addPathHandler(site.assetsPath, OwnAssets(context, site.assetsDir))
                .build()

        override fun shouldInterceptRequest(
            view: WebView,
            request: WebResourceRequest,
        ): WebResourceResponse? {
            val url = request.url
            return when (site.route(url.scheme, url.host, url.port)) {
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
            if (url == site.url) page.handshake()
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
            val isOwnFile = url.host == site.host && url.path?.startsWith(site.assetsPath) == true
            if (!page.isLoaded && isOwnFile) {
                page.close(RailgunException.Disconnected("the page's ${url.path} did not load"))
            }
        }
    }

    private inner class Chrome(
        private val kind: PageKind,
        private val debug: Boolean,
    ) : WebChromeClient() {
        // Consumed either way, so nothing a page prints reaches logcat.
        override fun onConsoleMessage(message: ConsoleMessage): Boolean {
            if (debug) {
                val line = "console ${message.messageLevel()}: ${message.message()}"
                flows
                    .getValue(kind)
                    .tryEmit(JSONObject().put("event", RailgunProtocol.LOG).put("data", line).toString())
            }
            return true
        }
    }

    // A page's own directory, and nothing else of the APK's assets.
    private class OwnAssets(
        context: Context,
        private val assetsDir: String,
    ) : WebViewAssetLoader.PathHandler {
        private val assets = WebViewAssetLoader.AssetsPathHandler(context)

        override fun handle(path: String): WebResourceResponse? = assets.handle(assetsDir + path)
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

/**
 * Where the Railgun page's requests go: its own assets, the allowed hosts over https, the anon-rpc loopback relay,
 * and nowhere else.
 */
internal object RailgunRequests {
    const val PAGE_HOST = "railgun.appassets.androidplatform.net"
    const val PAGE_ORIGIN = "https://$PAGE_HOST"
    const val ASSETS_DIR = "railgun/"
    const val ASSETS_PATH = "/assets/$ASSETS_DIR"
    const val PAGE_URL = "$PAGE_ORIGIN${ASSETS_PATH}index.html"
    private const val HTTPS = "https"
    private const val HTTP = "http"
    private const val DEFAULT_PORT = -1

    /**
     * The anon-rpc loopback relay (Rust `anon_rpc::LOOPBACK_RELAY_SOURCE`): the page's providers point at
     * `http://127.0.0.1:<port>/` while the anonymous RPC mode is on, and Rust relays each request through the
     * anon-rpc worker. The WebView reaches the loopback directly, never through the bridge, so it is admitted here
     * on any port: the port is the relay's choice at each start.
     */
    private const val LOOPBACK = "127.0.0.1"

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
            scheme == HTTP && host == LOOPBACK -> Route.ALLOWED
            scheme in LOCAL_SCHEMES -> Route.ALLOWED
            else -> Route.BLOCKED
        }
    }

    val SITE = PageSite(PageKind.RAILGUN, PAGE_HOST, ASSETS_DIR, RailgunProtocol.INIT, needsProxy = true, ::route)
}

/** Where the anon-rpc page's requests go: its own assets, [AnonRpcEndpoints] over https, and nowhere else. */
internal object AnonRpcRequests {
    const val PAGE_HOST = "anon.appassets.androidplatform.net"
    const val PAGE_ORIGIN = "https://$PAGE_HOST"
    const val ASSETS_DIR = "anon/"
    const val ASSETS_PATH = "/assets/$ASSETS_DIR"
    const val PAGE_URL = "$PAGE_ORIGIN${ASSETS_PATH}index.html"
    private const val HTTPS = "https"
    private const val DEFAULT_PORT = -1

    // The harness's worker runs from a `blob:` URL inside its null-origin frame.
    private val LOCAL_SCHEMES = setOf("blob", "data")

    fun route(
        scheme: String?,
        host: String?,
        port: Int,
    ): RailgunRequests.Route {
        val isHttps = scheme == HTTPS && port == DEFAULT_PORT
        return when {
            isHttps && host == PAGE_HOST -> RailgunRequests.Route.OWN_ASSET
            isHttps && host != null && AnonRpcEndpoints.allows(host) -> RailgunRequests.Route.ALLOWED
            scheme in LOCAL_SCHEMES -> RailgunRequests.Route.ALLOWED
            else -> RailgunRequests.Route.BLOCKED
        }
    }

    val SITE = PageSite(PageKind.ANON, PAGE_HOST, ASSETS_DIR, RailgunProtocol.ANON_INIT, needsProxy = false, ::route)
}
