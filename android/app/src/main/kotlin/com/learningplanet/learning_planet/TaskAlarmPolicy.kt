package com.learningplanet.learning_planet

import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId
import kotlin.math.abs

internal data class TaskAlarmClock(val wall: Long, val elapsed: Long, val boot: Int)
internal data class TaskAlarm(val id: Int, val at: Long, val zone: String,
    val quietStart: String, val quietEnd: String, val token: String, val consumed: Boolean = false)

internal object TaskAlarmPolicy {
    const val horizon = 7 * 24 * 60 * 60 * 1000L
    const val lateness = 15 * 60 * 1000L
    private val time = Regex("([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]")
    fun valid(row: TaskAlarm): Boolean = try {
        row.id >= 0 && row.at in 1000000000000..9999999999999 && row.zone.length <= 100 &&
            time.matches(row.quietStart) && time.matches(row.quietEnd) &&
            row.token.length == 36 && ZoneId.of(row.zone) != null
    } catch (_: Exception) { false }
    fun clockValid(anchor: TaskAlarmClock, now: TaskAlarmClock): Boolean =
        anchor.boot >= 0 && now.boot == anchor.boot && now.elapsed >= anchor.elapsed &&
            abs((now.wall - anchor.wall) - (now.elapsed - anchor.elapsed)) <= 30000
    fun canRestore(anchor: TaskAlarmClock, now: TaskAlarmClock): Boolean =
        anchor.boot >= 0 && now.boot >= 0 && now.wall >= anchor.wall && now.wall - anchor.wall <= horizon &&
            (anchor.boot != now.boot || clockValid(anchor, now))
    fun mayDeliver(row: TaskAlarm, anchor: TaskAlarmClock, now: TaskAlarmClock): Boolean {
        if (!valid(row) || row.consumed || !clockValid(anchor, now) ||
            now.wall < row.at || now.wall - row.at >= lateness) return false
        val time = Instant.ofEpochMilli(now.wall).atZone(ZoneId.of(row.zone)).toLocalTime()
        val start = LocalTime.parse(row.quietStart)
        val end = LocalTime.parse(row.quietEnd)
        return start == end || !(if (start < end) time >= start && time < end else time >= start || time < end)
    }
}
