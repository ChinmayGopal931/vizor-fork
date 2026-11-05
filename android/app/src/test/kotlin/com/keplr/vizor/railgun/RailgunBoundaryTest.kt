package com.keplr.vizor.railgun

import com.keplr.vizor.railgun.RailgunRequests.Route
import java.io.File
import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Unit tests run in `android/app`, so the page source is `../railgun-web/src/` and the built page
// `src/main/assets/railgun/`.
class RailgunBoundaryTest {
    @Test
    fun thePageReachesItsAssetsAndItsHostsOnly() {
        assertEquals(Route.OWN_ASSET, route(RailgunRequests.PAGE_URL))
        // A `*.` entry: an endpoint of the user's own name.
        RailgunEndpoints.hosts.forEach {
            assertEquals(it, Route.ALLOWED, route("https://${it.replace("*.", "my-endpoint.")}/any/path"))
        }
        // The keyed providers' URLs carry a key in the path, on an allowed host; QuickNode and a Chainstack
        // dedicated node name the host too, in any case.
        listOf(
            "https://eth-sepolia.g.alchemy.com/v2/key",
            "https://mainnet.infura.io/v3/key",
            "https://ethereum-rpc.publicnode.com",
            "https://my-endpoint.quiknode.pro/key/",
            "https://my-endpoint.ethereum-sepolia.quiknode.pro/key/",
            "https://MY-ENDPOINT.QuikNode.pro/key/",
            "https://nd-123-456-789.p2pify.com/key",
        ).forEach { assertEquals(it, Route.ALLOWED, route(it)) }
        assertEquals(Route.ALLOWED, route("blob:https://railgun.appassets.androidplatform.net/0f1e"))
        assertEquals(Route.ALLOWED, route("data:application/wasm;base64,AGFzbQ=="))
        // The anon-rpc loopback relay, on whichever port Rust bound.
        assertEquals(Route.ALLOWED, route("http://127.0.0.1:41931/"))
        assertEquals(Route.ALLOWED, route("http://127.0.0.1/"))
    }

    @Test
    fun everythingElseIsBlocked() {
        listOf(
            "https://example.com/",
            "http://ethereum-sepolia-rpc.publicnode.com/",
            // Only the loopback relay is reached over http, and only at 127.0.0.1.
            "http://localhost:41931/",
            "http://127.0.0.2:41931/",
            "https://127.0.0.1:41931/",
            "https://ethereum-sepolia-rpc.publicnode.com:8443/",
            "https://evil.ipfs-lb.com/",
            // A `*.` entry never takes the domain itself, or a lookalike.
            "https://quiknode.pro/key",
            "https://my-endpoint.quiknode.pro.evil.example/",
            "https://evilquiknode.pro/",
            "https://appassets.androidplatform.net/assets/railgun/index.html",
            "file:///data/data/com.keplr.vizor/shared_prefs/prefs.xml",
            "content://com.keplr.vizor.provider/x",
        ).forEach { assertEquals(it, Route.BLOCKED, route(it)) }
    }

    @Test
    fun aWildcardTakesHostnameLabelsOnly() {
        // As the iOS content rules match them: letters, digits and inner hyphens, in any case.
        listOf("a.quiknode.pro", "xn--abc.a-b.quiknode.pro", "A.QuikNode.PRO", "nd-1.p2pify.com").forEach {
            assertTrue(it, RailgunEndpoints.allows(it))
        }
        listOf("quiknode.pro", "a_b.quiknode.pro", "a..quiknode.pro", "-a.quiknode.pro", "a-.quiknode.pro", "")
            .forEach { assertFalse(it, RailgunEndpoints.allows(it)) }
    }

    @Test
    fun theCspListsTheSameHosts() {
        val csp = csp(File(ASSET).readText())

        // 'self' first; the rest sorted, which puts the anon-rpc loopback relay (http) before the https hosts.
        val hosts = (RailgunEndpoints.hosts.map { "https://$it" } + "http://127.0.0.1:*").sorted()
        assertEquals(listOf("'self'") + hosts, csp.getValue("connect-src"))
        assertEquals(listOf("'none'"), csp.getValue("default-src"))
        assertEquals(listOf("'none'"), csp.getValue("base-uri"))
        assertEquals(listOf("'none'"), csp.getValue("form-action"))
    }

    @Test
    fun theBuiltPageIsItsSource() {
        assertEquals(File(SOURCE).readText(), File(ASSET).readText())
    }

    private fun route(url: String): Route = URI(url).let { RailgunRequests.route(it.scheme, it.host, it.port) }

    private fun csp(html: String): Map<String, List<String>> =
        Regex("""http-equiv="Content-Security-Policy" content="([^"]*)"""")
            .find(html)
            .let { checkNotNull(it).groupValues[1] }
            .split(';')
            .map { it.trim().split(' ') }
            .associate { it.first() to it.drop(1).let { values -> listOf(values.first()) + values.drop(1).sorted() } }

    private companion object {
        const val ASSET = "src/main/assets/railgun/index.html"
        const val SOURCE = "../railgun-web/src/index.html"
    }
}
