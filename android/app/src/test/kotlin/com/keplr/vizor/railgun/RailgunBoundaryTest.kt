package com.keplr.vizor.railgun

import com.keplr.vizor.railgun.RailgunRequests.Route
import java.io.File
import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Test

// Unit tests run in `android/app`, so the page source is `../railgun-web/src/` and the built page
// `src/main/assets/railgun/`.
class RailgunBoundaryTest {
    @Test
    fun thePageReachesItsAssetsAndItsHostsOnly() {
        assertEquals(Route.OWN_ASSET, route(RailgunRequests.PAGE_URL))
        RailgunEndpoints.hosts.forEach { assertEquals(Route.ALLOWED, route("https://$it/any/path")) }
        // The keyed providers' URLs carry a key in the path, on an allowed host.
        listOf(
            "https://eth-sepolia.g.alchemy.com/v2/key",
            "https://mainnet.infura.io/v3/key",
            "https://ethereum-rpc.publicnode.com",
        ).forEach { assertEquals(it, Route.ALLOWED, route(it)) }
        assertEquals(Route.ALLOWED, route("blob:https://railgun.appassets.androidplatform.net/0f1e"))
        assertEquals(Route.ALLOWED, route("data:application/wasm;base64,AGFzbQ=="))
    }

    @Test
    fun everythingElseIsBlocked() {
        listOf(
            "https://example.com/",
            "http://ethereum-sepolia-rpc.publicnode.com/",
            "https://ethereum-sepolia-rpc.publicnode.com:8443/",
            "https://evil.ipfs-lb.com/",
            "https://appassets.androidplatform.net/assets/railgun/index.html",
            "file:///data/data/com.keplr.vizor/shared_prefs/prefs.xml",
            "content://com.keplr.vizor.provider/x",
        ).forEach { assertEquals(it, Route.BLOCKED, route(it)) }
    }

    @Test
    fun theCspListsTheSameHosts() {
        val csp = csp(File(ASSET).readText())

        val hosts = RailgunEndpoints.hosts.map { "https://$it" }.sorted()
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
