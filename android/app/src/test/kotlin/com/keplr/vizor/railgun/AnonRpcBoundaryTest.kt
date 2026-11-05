package com.keplr.vizor.railgun

import com.keplr.vizor.railgun.RailgunRequests.Route
import java.io.File
import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Test

// Unit tests run in `android/app`, so the page source is `../anon-rpc-web/src/` and the built page
// `src/main/assets/anon/`.
class AnonRpcBoundaryTest {
    @Test
    fun thePageReachesItsAssetsAndItsHostsOnly() {
        assertEquals(Route.OWN_ASSET, route(AnonRpcRequests.PAGE_URL))
        assertEquals(Route.OWN_ASSET, route("${AnonRpcRequests.PAGE_ORIGIN}${AnonRpcRequests.ASSETS_PATH}sandbox.html"))
        AnonRpcEndpoints.hosts.forEach { assertEquals(it, Route.ALLOWED, route("https://$it/any/path")) }
        // The harness's worker, from a blob inside its null-origin frame.
        assertEquals(Route.ALLOWED, route("blob:null/0f1e"))
        listOf(
            "https://example.com/",
            // The Railgun page's hosts are not this page's.
            "https://ppoi.fdi.network/",
            "https://eth-mainnet.g.alchemy.com/v2/key",
            // Nor is the loopback relay: the page reaches Rust the other way round.
            "http://127.0.0.1:41931/",
            "http://cdn.jsdelivr.net/",
            "https://cdn.jsdelivr.net:8443/",
            RailgunRequests.PAGE_URL,
            "file:///data/data/com.keplr.vizor/shared_prefs/prefs.xml",
        ).forEach { assertEquals(it, Route.BLOCKED, route(it)) }
    }

    @Test
    fun theTwoPagesHaveTheirOwnOrigins() {
        assertEquals(false, RailgunRequests.PAGE_HOST == AnonRpcRequests.PAGE_HOST)
        assertEquals(PageKind.ANON, AnonRpcRequests.SITE.kind)
        assertEquals(false, AnonRpcRequests.SITE.needsProxy)
        assertEquals(true, RailgunRequests.SITE.needsProxy)
    }

    @Test
    fun theCspListsTheSameHosts() {
        val csp = csp(File(ASSET).readText())

        assertEquals(AnonRpcEndpoints.hosts.map { "https://$it" }.toSet(), csp.getValue("connect-src").toSet())
        assertEquals(listOf("'none'"), csp.getValue("default-src"))
        assertEquals(listOf("'self'"), csp.getValue("script-src"))
        assertEquals(listOf("'self'"), csp.getValue("frame-src"))
        assertEquals(listOf("blob:"), csp.getValue("worker-src"))
        assertEquals(listOf("'none'"), csp.getValue("base-uri"))
        assertEquals(listOf("'none'"), csp.getValue("form-action"))
    }

    @Test
    fun theBuiltPageIsItsSource() {
        assertEquals(File(SOURCE).readText(), File(ASSET).readText())
        assertEquals(File(SANDBOX_SOURCE).readText(), File(SANDBOX_ASSET).readText())
    }

    private fun route(url: String): Route = URI(url).let { AnonRpcRequests.route(it.scheme, it.host, it.port) }

    private fun csp(html: String): Map<String, List<String>> =
        Regex("""http-equiv="Content-Security-Policy" content="([^"]*)"""")
            .find(html)
            .let { checkNotNull(it).groupValues[1] }
            .split(';')
            .map { it.trim().split(' ') }
            .associate { it.first() to it.drop(1) }

    private companion object {
        const val ASSET = "src/main/assets/anon/index.html"
        const val SOURCE = "../anon-rpc-web/src/index.html"
        const val SANDBOX_ASSET = "src/main/assets/anon/sandbox.html"
        const val SANDBOX_SOURCE = "../anon-rpc-web/src/sandbox.html"
    }
}
