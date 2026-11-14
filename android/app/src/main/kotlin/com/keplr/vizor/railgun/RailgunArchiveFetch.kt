package com.keplr.vizor.railgun

import android.net.Uri
import android.webkit.WebResourceResponse
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL

/**
 * Anon's archive of Railgun's history sends no CORS headers, so the page can't read it. The host fetches the page's
 * archive requests itself, through the page's own bridge, and answers them for the page's origin. Through a SOCKS
 * proxy the connection hands the bridge the hostname unresolved, so the bridge resolves it on the wallet's route (Tor
 * when that is on) and checks it against its allowlist, as it does the page's own connections.
 */
internal object RailgunArchiveFetch {
    private const val CONNECT_TIMEOUT_MS = 20_000
    private const val READ_TIMEOUT_MS = 60_000

    /** Whether the host answers a request itself: a GET of the archive, on the default https port. */
    fun handles(
        scheme: String?,
        host: String?,
        port: Int,
        method: String,
    ): Boolean = scheme == "https" && port == -1 && host == RailgunEndpoints.ARCHIVE_HOST && method == "GET"

    /** Whether the framework takes [status] as an answer: it throws on a redirect, or anything that isn't a status. */
    fun servable(status: Int): Boolean = status in 200..299 || status in 400..599

    /** [url] fetched through the bridge at [bridgePort]; a failure is a 502, which the page takes as the archive's. */
    fun fetch(
        url: Uri,
        bridgePort: Int,
    ): WebResourceResponse {
        val headers = mapOf("Access-Control-Allow-Origin" to RailgunRequests.PAGE_ORIGIN, "Cache-Control" to "no-store")
        if (bridgePort <= 0) return empty(BAD_GATEWAY, headers)
        val connection =
            try {
                val bridge = Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", bridgePort))
                URL(url.toString()).openConnection(bridge) as HttpURLConnection
            } catch (_: IOException) {
                return empty(BAD_GATEWAY, headers)
            }
        return try {
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            connection.instanceFollowRedirects = false
            // The files are gzip, checked against the archive's checksums as served: never unzipped on the way.
            connection.setRequestProperty("Accept-Encoding", "identity")
            val status = connection.responseCode
            if (!servable(status)) return empty(BAD_GATEWAY, headers)
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val body = stream?.use { it.readBytes() }
            val type = connection.contentType?.substringBefore(';') ?: "application/octet-stream"
            // The page reads no reason; the framework throws on an empty or non-ASCII one, so none is passed on.
            val reason = if (status in 200..299) "OK" else "Error"
            WebResourceResponse(type, null, status, reason, headers, (body ?: ByteArray(0)).inputStream())
        } catch (_: IOException) {
            empty(BAD_GATEWAY, headers)
        } finally {
            connection.disconnect()
        }
    }

    private const val BAD_GATEWAY = 502

    private fun empty(
        status: Int,
        headers: Map<String, String>,
    ) = WebResourceResponse("text/plain", "utf-8", status, "Bad Gateway", headers, ByteArray(0).inputStream())
}
