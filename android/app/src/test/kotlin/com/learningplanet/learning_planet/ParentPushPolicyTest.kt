package com.learningplanet.learning_planet

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class ParentPushPolicyTest {
    private val instant = Instant.parse("2026-11-05T04:00:00Z").toEpochMilli()
    private val clock = PushClock(instant, 100000, "boot-1")
    private val nonce = "11111111-1111-4111-8111-111111111111"
    private fun arguments() = mapOf<String, Any>("revision" to 7L, "scope_nonce" to nonce,
        "server_ms" to instant, "expires_ms" to instant + 2592000000L, "rtt_ms" to 100L, "settings_version" to 2L)
    private fun gate() = ParentPushPolicy.activate(PushGate(7), arguments(), clock)!!
    private fun data(at: Long = instant) = mapOf("version" to "parent-push-v1", "scope_nonce" to nonce,
        "message_id" to "22222222-2222-4222-8222-222222222222", "kind" to "redemption",
        "issued_ms" to at.toString(), "expires_ms" to (at + 60000).toString(), "timezone" to "Asia/Shanghai",
        "quiet_start" to "21:00:00", "quiet_end" to "07:00:00", "settings_version" to "2")

    @Test fun activationUsesRevisionFenceAndShortCalibration() {
        assertNotNull(ParentPushPolicy.activate(PushGate(7), arguments(), clock))
        assertNull(ParentPushPolicy.activate(PushGate(8), arguments(), clock))
        for (change in listOf(mapOf("rtt_ms" to 10001), mapOf("expires_ms" to instant),
            mapOf("scope_nonce" to "wrong"), mapOf("settings_version" to 0))) {
            assertNull(ParentPushPolicy.activate(PushGate(7), arguments() + change, clock))
        }
    }
    @Test fun acceptsOnlyCurrentOpaqueShortLivedMessages() {
        assertTrue(ParentPushPolicy.accepts(gate(), data(), clock))
        for (change in listOf(mapOf("child_name" to "PRIVATE"), mapOf("scope_nonce" to "33333333-3333-4333-8333-333333333333"),
            mapOf("kind" to "sync"), mapOf("settings_version" to "1"), mapOf("expires_ms" to (instant + 60001).toString()),
            mapOf("issued_ms" to (instant + 40000).toString()), mapOf("timezone" to "invalid/zone"))) {
            assertFalse(ParentPushPolicy.accepts(gate(), data() + change, clock))
        }
        assertFalse(ParentPushPolicy.accepts(PushGate(8), data(), clock))
        assertFalse(ParentPushPolicy.accepts(gate().copy(seen = listOf(data().getValue("message_id"))), data(), clock))
    }
    @Test fun quietHoursUseFamilyZoneAndBothClockBounds() {
        val evening = Instant.parse("2026-11-05T12:59:59Z").toEpochMilli()
        val calibrated = gate().copy(server = evening)
        assertFalse(ParentPushPolicy.accepts(calibrated, data(evening), clock)) // upper bound has entered 21:00
        assertTrue(ParentPushPolicy.accepts(calibrated, data(evening) + mapOf("quiet_start" to "00:00:00", "quiet_end" to "00:00:00"), clock))
        val morning = Instant.parse("2026-11-05T23:00:00Z").toEpochMilli()
        assertTrue(ParentPushPolicy.accepts(gate().copy(server = morning), data(morning), clock))
    }
    @Test fun dstAndDaytimeQuietIntervalsAreRespected() {
        val before = Instant.parse("2026-03-08T06:59:59Z").toEpochMilli()
        val message = data(before) + mapOf("timezone" to "America/New_York", "quiet_start" to "01:00:00", "quiet_end" to "03:00:00")
        assertFalse(ParentPushPolicy.accepts(gate().copy(server = before, expires = before + 2592000000L), message, clock))
        val after = before + 2000
        assertTrue(ParentPushPolicy.accepts(gate().copy(server = after, expires = after + 2592000000L), message + mapOf("issued_ms" to after.toString(), "expires_ms" to (after + 60000).toString()), clock))
    }
    @Test fun rebootClockChangesAndExpiryFailClosed() {
        assertFalse(ParentPushPolicy.accepts(gate(), data(), clock.copy(boot = "boot-2")))
        assertFalse(ParentPushPolicy.accepts(gate(), data(), clock.copy(wall = clock.wall - 31000)))
        assertFalse(ParentPushPolicy.accepts(gate(), data(), clock.copy(elapsed = clock.elapsed - 1)))
        assertFalse(ParentPushPolicy.accepts(gate(), data(), clock.copy(elapsed = clock.elapsed + 60000, wall = clock.wall + 60000)))
        assertFalse(ParentPushPolicy.accepts(gate().copy(expires = instant + 500), data(), clock))
    }
    @Test fun renewalPreservesDedupOnlyForTheSameScope() {
        val seen = gate().copy(seen = listOf(data().getValue("message_id")))
        assertEquals(seen.seen, ParentPushPolicy.activate(seen, arguments(), clock)!!.seen)
        assertTrue(ParentPushPolicy.activate(seen, arguments() + mapOf("scope_nonce" to "33333333-3333-4333-8333-333333333333"), clock)!!.seen.isEmpty())
    }
}
