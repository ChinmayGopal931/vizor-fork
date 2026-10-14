package com.keplr.vizor.railgun

/** Everything this library throws, besides cancellation. */
sealed class RailgunException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause) {
    /** The page closed or its renderer died; nothing more runs on it. */
    class Disconnected(
        message: String,
        cause: Throwable? = null,
    ) : RailgunException(message, cause)

    /** No reply in time, so the page was closed. */
    class Timeout(
        method: String
    ) : RailgunException("$method timed out")

    /** No WebView to run the page in, e.g. while its package updates. */
    class Unavailable(
        cause: Throwable
    ) : RailgunException("the WebView is unavailable", cause)

    /** A request or reply one side couldn't read. */
    class Protocol(
        message: String,
        cause: Throwable? = null,
    ) : RailgunException(message, cause)

    /** The engine, the chain or a screening node failed. */
    class Failed(
        message: String
    ) : RailgunException(message)
}
