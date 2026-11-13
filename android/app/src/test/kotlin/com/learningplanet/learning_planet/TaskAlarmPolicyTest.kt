package com.learningplanet.learning_planet

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class TaskAlarmPolicyTest {
    private fun ms(value: String) = Instant.parse(value).toEpochMilli()
    private val before = ms("2026-11-05T12:59:30Z")
    private val anchor = TaskAlarmClock(before - 60000, 1000, 2)
    private fun clock(at: Long) = TaskAlarmClock(at, 1000 + at - anchor.wall, 2)
    private fun row(at: Long = before) = TaskAlarm(3, at, "Asia/Shanghai", "21:00:00", "07:00:00", "11111111-1111-4111-8111-111111111111")
    @Test fun deliveryRechecksQuietBoundaryInsteadOfScheduledTime() {
        assertTrue(TaskAlarmPolicy.mayDeliver(row(), anchor, clock(before)))
        assertFalse(TaskAlarmPolicy.mayDeliver(row(), anchor, clock(before + 30000)))
        assertFalse(TaskAlarmPolicy.mayDeliver(row(), anchor, clock(before + 60000)))
        assertTrue(TaskAlarmPolicy.mayDeliver(row().copy(quietStart="00:00:00", quietEnd="00:00:00"), anchor, clock(before + 60000)))
    }
    @Test fun quietEndIsInclusiveForDeliveryAndDaytimeRangesWork() {
        val morning = ms("2026-11-05T23:00:00Z")
        assertTrue(TaskAlarmPolicy.mayDeliver(row(morning), anchor, clock(morning)))
        assertFalse(TaskAlarmPolicy.mayDeliver(row(morning).copy(quietStart="06:00:00", quietEnd="08:00:00"), anchor, clock(morning)))
    }
    @Test fun expirationEarlyEventsAndConsumedRecordsAreDropped() {
        val open = row().copy(quietStart="00:00:00", quietEnd="00:00:00")
        assertFalse(TaskAlarmPolicy.mayDeliver(open, anchor, clock(before - 1)))
        assertTrue(TaskAlarmPolicy.mayDeliver(open, anchor, clock(before + TaskAlarmPolicy.lateness - 1)))
        assertFalse(TaskAlarmPolicy.mayDeliver(open, anchor, clock(before + TaskAlarmPolicy.lateness)))
        assertFalse(TaskAlarmPolicy.mayDeliver(open.copy(consumed=true), anchor, clock(before)))
    }
    @Test fun clockJumpAndRebootDoNotReuseOldDeliveryAnchors() {
        assertFalse(TaskAlarmPolicy.mayDeliver(row(), anchor, clock(before).copy(boot=3)))
        assertFalse(TaskAlarmPolicy.mayDeliver(row(), anchor, clock(before).copy(elapsed=0)))
        assertFalse(TaskAlarmPolicy.mayDeliver(row(), anchor, clock(before).copy(elapsed=1000)))
        assertTrue(TaskAlarmPolicy.canRestore(anchor, clock(before).copy(boot=3, elapsed=10)))
        assertFalse(TaskAlarmPolicy.canRestore(anchor, clock(anchor.wall - 1).copy(boot=3)))
        assertFalse(TaskAlarmPolicy.canRestore(anchor, clock(anchor.wall + TaskAlarmPolicy.horizon + 1).copy(boot=3)))
    }
    @Test fun daylightSavingRepeatsAreEvaluatedInFamilyZone() {
        for (value in listOf("2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z")) {
            val at = ms(value)
            val r = row(at).copy(zone="America/New_York", quietStart="01:00:00", quietEnd="02:00:00")
            assertFalse(TaskAlarmPolicy.mayDeliver(r, anchor.copy(wall=at, elapsed=1000), TaskAlarmClock(at,1000,2)))
        }
    }
    @Test fun malformedPersistedPolicyFailsClosed() {
        for (r in listOf(row().copy(zone="bad/zone"), row().copy(quietStart="25:00:00"),
            row().copy(quietEnd="7:00"), row().copy(id=-1), row().copy(at=0), row().copy(token="broken"))) {
            assertFalse(TaskAlarmPolicy.valid(r))
            assertFalse(TaskAlarmPolicy.mayDeliver(r, anchor, clock(before)))
        }
    }
}
