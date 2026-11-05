package com.learningplanet.learning_planet

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class NativeDiagnosticPolicyTest {
    private val now = Instant.parse("2026-11-05T04:00:00Z").toEpochMilli()
    private val scope = "11111111-1111-4111-8111-111111111111"
    private val other = "22222222-2222-4222-8222-222222222222"
    private fun initial() = NativeDiagnosticPolicy.bind(NativeDiagnosticState(), scope, now - 1000)
    @Test fun onlyConfirmedMainProcessCrashReasonsAreClassified() {
        val exits = (0..18).map { NativeExit(now - 100, it, 10) }
        val state = NativeDiagnosticPolicy.collect(initial(), exits, now)
        assertEquals(listOf("androidJavaCrash", "androidNativeCrash", "androidAnr"), state.pending.map { it.operation })
        assertTrue(state.pending.all { it.wire().keys == setOf("event_id", "day", "operation") && it.day == "2026-11-05" })
    }
    @Test fun repeatHistoryAndLostAckKeepStableIds() {
        val exits = listOf(NativeExit(now, 5, 10), NativeExit(now, 6, 11))
        val once = NativeDiagnosticPolicy.collect(initial(), exits, now)
        assertEquals(once, NativeDiagnosticPolicy.collect(once, exits, now))
        val acknowledged = NativeDiagnosticPolicy.acknowledge(once, scope, setOf(once.pending.first().id))
        assertEquals(1, NativeDiagnosticPolicy.collect(acknowledged, exits, now).pending.size)
        assertEquals(once, NativeDiagnosticPolicy.acknowledge(once, other, once.pending.map { it.id }.toSet()))
    }
    @Test fun accountChangeLogoutAndRollbackResetAttribution() {
        val state = NativeDiagnosticPolicy.collect(initial(), listOf(NativeExit(now, 4, 10)), now)
        for (target in listOf(other, null)) {
            val next = NativeDiagnosticPolicy.bind(state, target, now + 100)
            assertTrue(next.pending.isEmpty()); assertTrue(next.seen.isEmpty())
            assertTrue(NativeDiagnosticPolicy.collect(next, listOf(NativeExit(now, 4, 10)), now + 100).pending.isEmpty())
        }
        val rollback = NativeDiagnosticPolicy.bind(state, scope, now - 2000)
        assertTrue(rollback.pending.isEmpty()); assertEquals(now - 2000, rollback.since)
    }
    @Test fun timestampsAndPidAreCheckedBeforeImport() {
        val state = NativeDiagnosticPolicy.collect(initial(), listOf(NativeExit(now - 1001, 4, 10), NativeExit(now + 1, 4, 10), NativeExit(now, 4, 0)), now)
        assertTrue(state.pending.isEmpty())
    }
    @Test fun utcRetentionCapacityAndReplayedPendingStayBounded() {
        var state = initial()
        for (batch in 0 until 25) state = NativeDiagnosticPolicy.collect(state, (1..50).map { NativeExit(now, 4, batch * 50 + it) }, now)
        assertEquals(250, state.pending.size); assertEquals(1000, state.seen.size)
        val future = NativeDiagnosticPolicy.bind(state, scope, now + 8L * 86400000)
        assertTrue(future.pending.isEmpty()); assertTrue(future.seen.isEmpty())
        assertTrue(NativeDiagnosticPolicy.collect(future, listOf(NativeExit(now, 4, 10)), now + 8L * 86400000).pending.isEmpty())
    }
    @Test fun restoredJsonOrderCannotEvictMarkersForPendingEvents() {
        var state = initial()
        for (batch in 0 until 25) state = NativeDiagnosticPolicy.collect(state, (1..50).map { NativeExit(now, 5, batch * 50 + it) }, now)
        val pending = state.pending.associate { it.id to it.day }
        val unordered = state.pending.reversed().associate { it.id to it.day } + state.seen.filterKeys { it !in pending }
        state = NativeDiagnosticPolicy.collect(state.copy(seen = unordered), (1251..1300).map { NativeExit(now, 5, it) }, now)
        assertEquals(1000, state.seen.size)
        assertTrue(state.pending.all { state.seen[it.id] == it.day })
    }
}
