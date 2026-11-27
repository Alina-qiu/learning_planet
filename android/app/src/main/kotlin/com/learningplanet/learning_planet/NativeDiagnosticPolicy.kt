package com.learningplanet.learning_planet

import java.time.Instant
import java.time.ZoneOffset
import java.util.UUID

data class NativeExit(val timestamp: Long, val reason: Int, val pid: Int)
data class NativeDiagnosticEvent(val id: String, val day: String, val operation: String) {
    fun wire(): Map<String, String> = mapOf("event_id" to id, "day" to day, "operation" to operation)
}
data class NativeDiagnosticState(
    val scope: String? = null, val since: Long = 0, val observed: Long = 0,
    val pending: List<NativeDiagnosticEvent> = emptyList(), val seen: Map<String, String> = emptyMap()
)

/** No exception objects, trace streams or process descriptions enter this layer. */
object NativeDiagnosticPolicy {
    val uuid = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    val operations = setOf("androidJavaCrash", "androidNativeCrash", "androidAnr")
    fun day(millis: Long): String = Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate().toString()
    fun oldest(now: Long): String = Instant.ofEpochMilli(now).atZone(ZoneOffset.UTC).toLocalDate().minusDays(7).toString()

    fun bind(state: NativeDiagnosticState, scope: String?, now: Long): NativeDiagnosticState {
        require(scope == null || uuid.matches(scope))
        if (scope == null || scope != state.scope || now < state.observed || state.since <= 0) {
            return NativeDiagnosticState(scope, now, now)
        }
        val first = oldest(now); val last = day(now)
        return state.copy(observed = now,
            pending = state.pending.filter { it.day >= first && it.day <= last }.takeLast(250),
            seen = state.seen.filterValues { it >= first && it <= last }.entries.toList().takeLast(1000).associate { it.toPair() })
    }

    fun collect(state: NativeDiagnosticState, exits: List<NativeExit>, now: Long): NativeDiagnosticState {
        if (state.scope == null) return state
        val pending = state.pending.toMutableList(); val seen = state.seen.toMutableMap()
        val first = oldest(now)
        for (exit in exits.take(50).sortedBy { it.timestamp }) {
            // Android API30 exit constants; the pre-30 uncaught-Java adapter
            // uses reason 4 only. Other termination reasons are not crashes.
            val operation = when (exit.reason) { 4 -> "androidJavaCrash"; 5 -> "androidNativeCrash"; 6 -> "androidAnr"; else -> continue }
            if (exit.timestamp < state.since || exit.timestamp > now || exit.pid <= 0) continue
            val date = day(exit.timestamp)
            if (date < first) continue
            val id = UUID.nameUUIDFromBytes("${state.scope}:${state.since}:${exit.timestamp}:${exit.reason}:${exit.pid}".toByteArray(Charsets.UTF_8)).toString()
            if (seen.containsKey(id)) continue
            pending.add(NativeDiagnosticEvent(id, date, operation)); seen[id] = date
        }
        val retained = pending.takeLast(250)
        val required = retained.associate { it.id to it.day }
        // JSON object iteration order is not chronological. Never evict a
        // replay marker belonging to an event still awaiting acknowledgement.
        val historical = seen.filterKeys { it !in required }.entries
            .sortedWith(compareBy<Map.Entry<String, String>> { it.value }.thenBy { it.key })
            .takeLast(1000 - required.size).associate { it.toPair() }
        return state.copy(pending = retained, seen = historical + required)
    }

    fun acknowledge(state: NativeDiagnosticState, scope: String, ids: Set<String>): NativeDiagnosticState =
        if (state.scope != scope) state else state.copy(pending = state.pending.filter { it.id !in ids })
}
