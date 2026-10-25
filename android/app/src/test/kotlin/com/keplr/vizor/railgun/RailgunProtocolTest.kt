package com.keplr.vizor.railgun

import com.keplr.vizor.railgun.RailgunProtocol.Message
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

// The envelope only: Kotlin never reads params, results or event data, which stay raw JSON text for Dart. Robolectric
// provides `org.json`.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class RailgunProtocolTest {
    @Test
    fun requestCarriesIdMethodAndParams() {
        val request = JSONObject(RailgunProtocol.request(7, RailgunMethod.OPEN_WALLET, """{"network":"sepolia"}"""))

        assertEquals(7L, request.getLong("id"))
        assertEquals("openWallet", request.getString("method"))
        assertEquals("sepolia", request.getJSONObject("params").getString("network"))
    }

    @Test
    fun paramsAreOneObjectSplicedAsSent() {
        listOf("[]", "1", "\"text\"", "{} {}", """{"a":1}, "b"""", "not json", "").forEach {
            assertThrows(it, RailgunException.Protocol::class.java) {
                RailgunProtocol.request(1, RailgunMethod.START, it)
            }
        }
        // Not re-serialized, so a large number keeps every digit.
        val params = """{"amount":123456789012345678901234567890}"""
        assertTrue(RailgunProtocol.request(1, RailgunMethod.START, params).endsWith(""""params":$params}"""))
    }

    @Test
    fun decodesReplies() {
        assertEquals(
            Message.Reply(3, """{"address":"0zk1"}"""),
            RailgunProtocol.decode("""{"id":3,"result":{"address":"0zk1"}}"""),
        )
        assertEquals(Message.Reply(4, "null"), RailgunProtocol.decode("""{"id":4,"result":null}"""))
        assertEquals(Message.Reply(5, "\"0zk1\""), RailgunProtocol.decode("""{"id":5,"result":"0zk1"}"""))
    }

    @Test
    fun failuresKeepTheirKind() {
        assertTrue(failure("""{"code":"BAD_REQUEST","message":"no wallet is open"}""") is RailgunException.Protocol)
        assertTrue(failure("""{"code":"FAILED","message":"the RPC timed out"}""") is RailgunException.Failed)
        assertEquals("the RPC timed out", failure("""{"code":"FAILED","message":"the RPC timed out"}""").message)
        assertTrue(failure("""{"code":"RPC_FAILED","message":"the Ethereum RPC answers 403"}""") is RailgunException.RpcFailed)
    }

    @Test
    fun anUnknownCodeIsAFailure() {
        assertTrue(failure("""{"code":"SOMETHING_NEW","message":"?"}""") is RailgunException.Failed)
    }

    @Test
    fun aReplyItCannotReadStillFailsItsCall() {
        val message = RailgunProtocol.decode("""{"id":5,"error":"a bare string"}""") as Message.Failure

        assertEquals(5L, message.id)
        assertTrue(message.error is RailgunException.Protocol)
    }

    @Test
    fun decodesEvents() {
        assertEquals(Message.Ready, RailgunProtocol.decode("""{"event":"ready","data":null}"""))
        listOf(
            "scan" to """{"event":"scan","data":{"tree":"txid","status":"Updated","progress":0.4}}""",
            "proof" to """{"event":"proof","data":{"progress":0.25,"status":"proving"}}""",
            "screening" to """{"event":"screening","data":{"txids":null,"download":{"progress":0.5},"proving":null}}""",
            "log" to """{"event":"log","data":"scanning"}""",
        ).forEach { (name, raw) -> assertEquals(Message.Event(name, raw), RailgunProtocol.decode(raw)) }
    }

    @Test
    fun dropsWhatItDoesNotUnderstand() {
        assertNull(RailgunProtocol.decode(null))
        assertNull(RailgunProtocol.decode("not json"))
        assertNull(RailgunProtocol.decode("[1]"))
        assertNull(RailgunProtocol.decode("""{"event":"unknown","data":1}"""))
        assertNull(RailgunProtocol.decode("""{"event":7,"data":1}"""))
        assertNull(RailgunProtocol.decode("""{"result":1}"""))
    }

    @Test
    fun thePageAnswersEveryMethod() {
        val page = File(PAGE).readText()

        assertEquals(RailgunMethod.entries.map { it.wire }.sorted(), handlers(page, "handlers").sorted())
        // The debug-only call is never exposed to Dart.
        assertNull(RailgunMethod.fromWire("openNewWallet"))
    }

    @Test
    fun theHelloIsThePageOwn() {
        val init = Regex("""const INIT = '([^']*)';""").find(File(PAGE).readText())

        assertEquals(RailgunProtocol.INIT, checkNotNull(init).groupValues[1])
    }

    private fun handlers(
        page: String,
        table: String,
    ) = Regex("""const $table = \{([^}]*)}""")
        .find(page)
        .let { checkNotNull(it).groupValues[1] }
        .lines()
        .filterNot { it.trim().startsWith("//") }
        .joinToString("")
        .split(',')
        .map { it.substringBefore(':').trim() }
        .filter { it.isNotEmpty() }

    private fun failure(error: String): RailgunException =
        (RailgunProtocol.decode("""{"id":1,"error":$error}""") as Message.Failure).error

    private companion object {
        const val PAGE = "../railgun-web/src/index.js"
    }
}
