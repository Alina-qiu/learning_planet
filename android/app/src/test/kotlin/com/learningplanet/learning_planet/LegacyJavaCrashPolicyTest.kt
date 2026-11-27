package com.learningplanet.learning_planet

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class LegacyJavaCrashPolicyTest {
    private val now = Instant.parse("2026-11-05T04:00:00Z").toEpochMilli()
    private val scope = "11111111-1111-4111-8111-111111111111"
    private val other = "22222222-2222-4222-8222-222222222222"
    private fun initial() = NativeDiagnosticPolicy.bind(NativeDiagnosticState(), scope, now - 1000)

    @Test fun markerContainsOnlyVersionOpaqueScopeTimesAndPid() {
        val crash = LegacyJavaCrashPolicy.capture(initial(), now, 42)!!
        assertEquals("1\n$scope\n${now-1000}\n${now-1000}\n$now\n42\n", crash.encode())
        assertEquals(crash, LegacyJavaCrashPolicy.decode(crash.encode()))
        val result = LegacyJavaCrashPolicy.collect(initial(), crash, now)
        assertEquals(1, result.pending.size)
        assertEquals("androidJavaCrash", result.pending.single().operation)
        assertEquals(setOf("event_id", "day", "operation"), result.pending.single().wire().keys)
    }

    @Test fun invalidAndUnboundCaptureDoesNotCreateAMarker() {
        for (state in listOf(null, NativeDiagnosticState(), initial().copy(scope = "not-a-scope"),
            initial().copy(since = 0), initial().copy(observed = now + 1))) {
            assertNull(LegacyJavaCrashPolicy.capture(state, now, 42))
        }
        assertNull(LegacyJavaCrashPolicy.capture(initial(), now, 0))
    }

    @Test fun corruptOrExtendedMarkersAreDiscardedWithoutParsingPrivateFields() {
        val encoded = LegacyJavaCrashPolicy.capture(initial(), now, 42)!!.encode()
        for (bad in listOf("", "x".repeat(257), encoded + "PRIVATE_EXCEPTION", encoded.replaceFirst("1\n", "2\n"),
            encoded.replace(scope, scope.uppercase().replace('1', 'G')), encoded.replace("42\n", "-1\n"),
            encoded.replace("42\n", "2147483648\n"), encoded.replace("42\n", "-4294967295\n"), encoded.replace("42\n", "+42\n"),
            encoded.replace("$now\n", "${now-2000}\n"), encoded.dropLast(1))) {
            assertNull(bad, LegacyJavaCrashPolicy.decode(bad))
        }
    }

    @Test fun accountBoundaryFutureRollbackAndRetentionPreventMisattribution() {
        val state = initial()
        val crash = LegacyJavaCrashPolicy.capture(state, now, 42)!!
        for (next in listOf(NativeDiagnosticPolicy.bind(state, other, now+10),
            NativeDiagnosticPolicy.bind(state, null, now+10),
            NativeDiagnosticPolicy.bind(state, scope, now-2000), state.copy(since=now))) {
            assertEquals(next, LegacyJavaCrashPolicy.collect(next, crash, now+10))
        }
        assertTrue(LegacyJavaCrashPolicy.collect(state, crash, now-1).pending.isEmpty())
        assertTrue(LegacyJavaCrashPolicy.collect(state, crash, now+8L*86400000).pending.isEmpty())
    }

    @Test fun failedImportOrAcknowledgementReplaysTheOriginalIdOnce() {
        val state = initial()
        val crash = LegacyJavaCrashPolicy.capture(state, now, 42)!!
        val imported = LegacyJavaCrashPolicy.collect(state, crash, now)
        assertEquals(imported, LegacyJavaCrashPolicy.collect(state, LegacyJavaCrashPolicy.decode(crash.encode()), now))
        assertEquals(imported, LegacyJavaCrashPolicy.collect(imported, crash, now))
        val ack = NativeDiagnosticPolicy.acknowledge(imported, scope, setOf(imported.pending.single().id))
        assertTrue(LegacyJavaCrashPolicy.collect(ack, crash, now).pending.isEmpty())
    }

    @Test fun originalHandlerReceivesTheSameObjectsEvenIfRecordingThrows() {
        val original = object : Error() {
            override fun toString(): String = throw AssertionError("Do not format private errors")
        }
        val thread = Thread.currentThread()
        for (fail in listOf(false, true)) {
            var records = 0
            var forwarded = 0
            val handler = LegacyJavaCrashHandler(Thread.UncaughtExceptionHandler { t, e ->
                assertSame(thread, t); assertSame(original, e); forwarded++
            }) { records++; if (fail) throw OutOfMemoryError("fixture only") }
            handler.uncaughtException(thread, original)
            handler.uncaughtException(thread, original)
            assertEquals(1, records); assertEquals(2, forwarded)
        }
    }

    @Test fun concurrentCrashDoesNotWaitForAnotherRecorderBeforeForwarding() {
        val started = CountDownLatch(1); val release = CountDownLatch(1)
        val forwarded = AtomicInteger(); val records = AtomicInteger()
        val handler = LegacyJavaCrashHandler(Thread.UncaughtExceptionHandler { _, _ -> forwarded.incrementAndGet() }) {
            records.incrementAndGet(); started.countDown(); check(release.await(5, TimeUnit.SECONDS))
        }
        val first = Thread { handler.uncaughtException(Thread.currentThread(), Error()) }
        first.start()
        try {
            assertTrue(started.await(5, TimeUnit.SECONDS))
            handler.uncaughtException(Thread.currentThread(), Error())
            assertEquals(1, forwarded.get())
        } finally { release.countDown(); first.join(5000) }
        assertFalse(first.isAlive); assertEquals(1, records.get()); assertEquals(2, forwarded.get())
    }
}
