package com.learningplanet.learning_planet

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class LegacyAnrPolicyTest {
    private val now = Instant.parse("2026-11-05T04:00:00Z").toEpochMilli()
    private val scope = "11111111-1111-4111-8111-111111111111"
    private val other = "22222222-2222-4222-8222-222222222222"
    private fun binding() = NativeDiagnosticPolicy.bind(NativeDiagnosticState(), scope, now - 1000)
    private fun observe(policy: LegacyAnrPolicy, condition: Int?, time: Long = now,
        state: NativeDiagnosticState? = binding(), foreground: Boolean = true, debugging: Boolean = false,
        pid: Int = 42) = policy.observe(state, foreground, debugging, condition, time, pid)

    @Test fun preExistingOrUnknownConditionsDoNotBecomeNewAnrs() {
        val policy = LegacyAnrPolicy()
        for (condition in listOf(2, null, 1, 99, 2)) assertNull(observe(policy, condition))
        assertNull(observe(policy, 0))
        for (condition in listOf(null, 1, 99)) assertNull(observe(policy, condition))
        val event = observe(policy, 2, now + 1)!!
        assertEquals(NativeExit(now + 1, 6, 42), event)
    }
    @Test fun repeatedAnrObservationsAndAckDoNotDuplicateAnEpisode() {
        val policy = LegacyAnrPolicy(); observe(policy, 0)
        val first = observe(policy, 2)!!
        val recorded = NativeDiagnosticPolicy.collect(binding(), listOf(first), now)
        assertEquals("androidAnr", recorded.pending.single().operation)
        assertEquals(setOf("event_id", "day", "operation"), recorded.pending.single().wire().keys)
        val acked = NativeDiagnosticPolicy.acknowledge(recorded, scope, setOf(recorded.pending.single().id))
        assertEquals(first, observe(policy, 2, now + 2000, acked))
        assertTrue(NativeDiagnosticPolicy.collect(acked, listOf(first), now + 2000).pending.isEmpty())
    }
    @Test fun failedQueriesKeepTheOriginalEpisodeAndStableRetryIdentity() {
        val policy = LegacyAnrPolicy(); observe(policy, 0)
        val first = observe(policy, 2)!!
        assertNull(observe(policy, null, now + 2000))
        val retry = observe(policy, 2, now + 4000)!!
        assertEquals(first, retry)
        // If the journal was not committed, retrying collection has the same ID.
        assertEquals(NativeDiagnosticPolicy.collect(binding(), listOf(first), now).pending,
            NativeDiagnosticPolicy.collect(binding(), listOf(retry), now + 4000).pending)
    }
    @Test fun healthyObservationSeparatesRecoveredAndLaterAnrs() {
        val policy = LegacyAnrPolicy(); observe(policy, 0)
        val first = observe(policy, 2)!!
        assertNull(observe(policy, 0, now + 2000))
        val second = observe(policy, 2, now + 4000)!!
        assertNotEquals(first, second)
        val recorded = NativeDiagnosticPolicy.collect(binding(), listOf(first, second), now + 4000)
        assertEquals(2, recorded.pending.size)
    }
    @Test fun scopeSwitchLogoutAndBoundaryChangesRequireAnotherHealthyObservation() {
        val replacements = listOf<NativeDiagnosticState?>(null,
            NativeDiagnosticState(null, now, now),
            NativeDiagnosticState(other, now, now), binding().copy(since = now, observed = now))
        for (replacement in replacements) {
            val policy = LegacyAnrPolicy(); observe(policy, 0); observe(policy, 2)
            assertNull(observe(policy, 2, now + 1, replacement))
            assertNull(observe(policy, 2, now + 2))
            observe(policy, 0, now + 3)
            assertNotNull(observe(policy, 2, now + 4))
        }
    }
    @Test fun backgroundAndDebuggerIntervalsNeverBecomeAnrsOnResume() {
        for (debugging in listOf(false, true)) {
            val policy = LegacyAnrPolicy(); observe(policy, 0); observe(policy, 2)
            assertNull(observe(policy, 2, now + 1, foreground = debugging, debugging = debugging))
            assertNull(observe(policy, 2, now + 2))
            observe(policy, 0, now + 3)
            assertNotNull(observe(policy, 2, now + 4))
        }
    }
    @Test fun invalidPidBindingAndClockRollbackCannotBeAttributed() {
        val invalid = listOf(binding().copy(scope = "invalid"), binding().copy(since = 0),
            binding().copy(observed = now + 5000), binding().copy(observed = now - 2000))
        for (state in invalid) {
            val policy = LegacyAnrPolicy(); observe(policy, 0)
            assertNull(observe(policy, 2, state = state))
        }
        val policy = LegacyAnrPolicy(); observe(policy, 0)
        assertNull(observe(policy, 2, pid = 0))
        observe(policy, 0, now + 4000)
        assertNull(observe(policy, 2, now + 2000))
        assertNull(observe(policy, 2, now + 6000))
        observe(policy, 0, now + 6001)
        assertNotNull(observe(policy, 2, now + 6002))
    }
    @Test fun restoredBindingDoesNotInventAnErrorForAnAlreadyUnresponsiveProcess() {
        val old = LegacyAnrPolicy(); observe(old, 0)
        val captured = observe(old, 2)!!
        val stored = NativeDiagnosticPolicy.collect(binding(), listOf(captured), now)
        val restarted = LegacyAnrPolicy()
        assertNull(observe(restarted, 2, now + 1000, stored))
        assertEquals(1, stored.pending.size)
    }
    @Test fun shortLifecycleBoundaryBetweenPollsRequiresHealthyObservation() {
        val policy = LegacyAnrPolicy(); observe(policy, 0)
        policy.reset()
        assertNull(observe(policy, 2, now + 1))
        observe(policy, 0, now + 2)
        assertNotNull(observe(policy, 2, now + 3))
    }
}
