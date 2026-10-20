package com.keplr.vizor.railgun

import com.keplr.vizor.railgun.RailgunProtocol.Message
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.time.Duration.Companion.seconds

// Params and results are raw JSON text, and events reach their listener as the page sent them. Robolectric provides
// `org.json`.
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class RailgunChannelTest {
    private val posted = mutableListOf<String>()
    private val events = mutableListOf<Message.Event>()
    private val channel = RailgunChannel({ posted += it }, { events += it })

    @Test
    fun aReplyAnswersItsOwnCall() =
        runTest {
            val first = async { channel.call(RailgunMethod.REVERSE_COST, EMPTY) }
            val second = async { channel.call(RailgunMethod.REVERSE_COST, EMPTY) }
            runCurrent()

            channel.receive("""{"id":${idOf(1)},"result":"second"}""")
            channel.receive("""{"id":${idOf(0)},"result":"first"}""")

            assertEquals("\"first\"", first.await())
            assertEquals("\"second\"", second.await())
        }

    @Test
    fun aCallWithoutAReplyTimesOutAsAnError() =
        runTest {
            val call = async { runCatching { channel.call(RailgunMethod.REVERSE_COST, EMPTY) } }

            advanceTimeBy(RailgunMethod.REVERSE_COST.timeout + 1.seconds)

            val timeout = call.await().failure<RailgunException.Timeout>()
            assertEquals("reverseCost timed out", timeout.message)
        }

    @Test
    fun aReplyItCannotReadFailsTheCallAtOnce() =
        runTest {
            val call = async { runCatching { channel.call(RailgunMethod.REFRESH, EMPTY) } }
            runCurrent()

            channel.receive("""{"id":${idOf(0)},"error":"a bare string"}""")

            call.await().failure<RailgunException.Protocol>()
        }

    @Test
    fun closingFailsWhatWaitsAndWhatComesAfter() =
        runTest {
            val call = async { runCatching { channel.call(RailgunMethod.REFRESH, EMPTY) } }
            runCurrent()

            channel.close(RailgunException.Disconnected("the renderer stopped"))
            channel.receive("""{"id":${idOf(0)},"result":"late"}""")

            assertFalse(channel.isOpen)
            call.await().failure<RailgunException.Disconnected>()
            runCatching { channel.call(RailgunMethod.REFRESH, EMPTY) }.failure<RailgunException.Disconnected>()
            assertEquals(1, posted.size)
        }

    @Test
    fun theHelloOnlyCountsOnItsOwnChannel() =
        runTest {
            val other = RailgunChannel({}, {})
            other.receive("""{"event":"ready","data":null}""")

            runCatching { channel.awaitReady(1.seconds) }.failure<RailgunException.Timeout>()

            channel.receive("""{"event":"ready","data":null}""")
            channel.awaitReady(1.seconds)
        }

    @Test
    fun closingBeforeTheHelloFailsTheLoad() =
        runTest {
            channel.close(RailgunException.Disconnected("the page did not load"))

            runCatching { channel.awaitReady(1.seconds) }.failure<RailgunException.Disconnected>()
        }

    @Test
    fun eventsGoToTheirListener() {
        val proof = """{"event":"proof","data":{"progress":0.5,"status":"proving"}}"""

        channel.receive(proof)

        assertEquals(listOf(Message.Event("proof", proof)), events)
        assertTrue(channel.isOpen)
    }

    private fun idOf(request: Int): Long = JSONObject(posted[request]).getLong("id")

    // The failure a call ended with: JUnit's assertThrows can't run a suspending call itself.
    private inline fun <reified T : Throwable> Result<*>.failure(): T = assertThrows(T::class.java) { getOrThrow() }

    private companion object {
        const val EMPTY = "{}"
    }
}
