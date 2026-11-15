package com.keplr.vizor.railgun

import android.net.Uri
import android.os.SystemClock
import android.webkit.WebResourceResponse
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
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
    private const val READ_TIMEOUT_MS = 20_000

    // The page gives up on a request after a minute, and so does the host, so a server that trickles can't hold a
    // WebView thread: the page's abort never reaches a read here.
    private const val DEADLINE_MS = 60_000L

    /** Far above the archive's largest file and far below the app's heap: a body past it is refused, never buffered. */
    const val MAX_BYTES = 16 * 1024 * 1024

    // The same for every phone; the platform's own names the device and its build.
    private const val USER_AGENT = "Mozilla/5.0"

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
        now: () -> Long = SystemClock::elapsedRealtime,
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
        val deadline = now() + DEADLINE_MS
        return try {
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            connection.instanceFollowRedirects = false
            // The files are gzip, checked against the archive's checksums as served: never unzipped on the way.
            connection.setRequestProperty("Accept-Encoding", "identity")
            connection.setRequestProperty("User-Agent", USER_AGENT)
            val status = connection.responseCode
            if (!servable(status)) return empty(BAD_GATEWAY, headers)
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val body = stream?.use { read(it, connection.contentLengthLong, deadline, now) } ?: ByteArray(0)
            val type = connection.contentType?.substringBefore(';') ?: "application/octet-stream"
            // The page reads no reason; the framework throws on an empty or non-ASCII one, so none is passed on.
            val reason = if (status in 200..299) "OK" else "Error"
            WebResourceResponse(type, null, status, reason, headers, body.inputStream())
        } catch (_: Exception) {
            // The connection's failures, a body refused, or anything else it throws: never into the WebView.
            empty(BAD_GATEWAY, headers)
        } finally {
            connection.disconnect()
        }
    }

    /** [stream] read whole: refused past [MAX_BYTES] (or a [declared] length past it), or once [deadline] has passed. */
    fun read(
        stream: InputStream,
        declared: Long,
        deadline: Long,
        now: () -> Long,
    ): ByteArray {
        if (declared > MAX_BYTES) throw IOException("the archive's answer is too large")
        val body = ByteArrayOutputStream(if (declared > 0) declared.toInt() else BUFFER_BYTES)
        val buffer = ByteArray(BUFFER_BYTES)
        while (true) {
            if (now() > deadline) throw IOException("the archive answered too slowly")
            val read = stream.read(buffer)
            if (read < 0) return body.toByteArray()
            if (body.size() + read > MAX_BYTES) throw IOException("the archive's answer is too large")
            body.write(buffer, 0, read)
        }
    }

    private const val BUFFER_BYTES = 64 * 1024

    private const val BAD_GATEWAY = 502

    private fun empty(
        status: Int,
        headers: Map<String, String>,
    ) = WebResourceResponse("text/plain", "utf-8", status, "Bad Gateway", headers, ByteArray(0).inputStream())
}
