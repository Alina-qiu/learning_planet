package com.learningplanet.learning_planet

import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId
import kotlin.math.abs

internal data class PushClock(val wall: Long, val elapsed: Long, val boot: String)
internal data class PushGate(
    val revision: Long,
    val nonce: String? = null,
    val server: Long = 0,
    val expires: Long = 0,
    val rtt: Long = 0,
    val minimumSettings: Long = 0,
    val clock: PushClock = PushClock(0, 0, ""),
    val seen: List<String> = emptyList(),
)

/** Pure policy, shared by the native bridge and background HMS receiver. */
internal object ParentPushPolicy {
    private val uuid = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    private val time = Regex("([01][0-9]|2[0-3]):[0-5][0-9]:00")
    private val epoch = Regex("[0-9]{13}")
    private val version = Regex("[1-9][0-9]{0,15}")
    private val fields = setOf("version", "message_id", "scope_nonce", "kind", "issued_ms", "expires_ms", "timezone", "quiet_start", "quiet_end", "settings_version")
    fun activate(current: PushGate, values: Map<*, *>, clock: PushClock): PushGate? {
        val revision = (values["revision"] as? Number)?.toLong() ?: return null
        val nonce = values["scope_nonce"] as? String ?: return null
        val server = (values["server_ms"] as? Number)?.toLong() ?: return null
        val expires = (values["expires_ms"] as? Number)?.toLong() ?: return null
        val rtt = (values["rtt_ms"] as? Number)?.toLong() ?: return null
        val minimum = (values["settings_version"] as? Number)?.toLong() ?: return null
        if (revision != current.revision || !uuid.matches(nonce) || rtt !in 0..10000 ||
            minimum !in 1..9007199254740991 || server !in 1000000000000..9999999999999 ||
            expires - server !in 1..2592001000 || clock.boot.isEmpty()) return null
        return PushGate(revision, nonce, server, expires, rtt, minimum, clock,
            if (nonce == current.nonce) current.seen else emptyList())
    }

    fun accepts(gate: PushGate, data: Map<String, String>, now: PushClock): Boolean {
        if (gate.nonce == null || !uuid.matches(gate.nonce) || gate.rtt !in 0..10000 ||
            gate.minimumSettings !in 1..9007199254740991 || gate.clock.boot.isEmpty() ||
            gate.server !in 1000000000000..9999999999999 || gate.expires - gate.server !in 1..2592001000 ||
            data.keys != fields || data["version"] != "parent-push-v1" ||
            data["scope_nonce"] != gate.nonce || !uuid.matches(data["message_id"].orEmpty()) ||
            data["message_id"] in gate.seen || data["kind"] !in setOf("redemption", "weekly") ||
            !epoch.matches(data["issued_ms"].orEmpty()) || !epoch.matches(data["expires_ms"].orEmpty()) ||
            !version.matches(data["settings_version"].orEmpty())) return false
        val settings = data.getValue("settings_version").toLongOrNull() ?: return false
        if (settings < gate.minimumSettings || settings > 9007199254740991) return false
        val elapsed = now.elapsed - gate.clock.elapsed
        if (now.boot != gate.clock.boot || elapsed < 0 || abs((now.wall - gate.clock.wall) - elapsed) > 30000) return false
        val low = gate.server + elapsed
        val high = low + gate.rtt + 1000
        val issued = data.getValue("issued_ms").toLong()
        val expires = data.getValue("expires_ms").toLong()
        if (issued > low + 30000 || expires - issued !in 1..60000 || expires <= high ||
            expires > gate.expires || high >= gate.expires) return false
        val start = data["quiet_start"].orEmpty()
        val end = data["quiet_end"].orEmpty()
        if (!time.matches(start) || !time.matches(end) || data.getValue("timezone").length > 100) return false
        return try {
            val zone = ZoneId.of(data.getValue("timezone"))
            fun quiet(at: Long): Boolean {
                val local = Instant.ofEpochMilli(at).atZone(zone).toLocalTime()
                val a = LocalTime.parse(start)
                val b = LocalTime.parse(end)
                return if (a == b) false else if (a < b) local >= a && local < b else local >= a || local < b
            }
            !quiet(low) && !quiet(high)
        } catch (_: Exception) { false }
    }
}
