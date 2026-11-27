package com.learningplanet.learning_planet

import java.util.concurrent.atomic.AtomicBoolean

/** No Throwable, thread name, stack or account identifier enters the journal. */
data class LegacyJavaCrash(
    val scope: String, val since: Long, val observed: Long, val timestamp: Long, val pid: Int
) {
    init {
        require(NativeDiagnosticPolicy.uuid.matches(scope))
        require(since > 0 && observed >= since && timestamp >= observed && pid > 0)
    }
    fun encode(): String = "1\n$scope\n$since\n$observed\n$timestamp\n$pid\n"
}

object LegacyJavaCrashPolicy {
    fun capture(state: NativeDiagnosticState?, now: Long, pid: Int): LegacyJavaCrash? {
        val scope = state?.scope ?: return null
        if (!NativeDiagnosticPolicy.uuid.matches(scope) || state.since <= 0 ||
            state.observed < state.since || now < state.observed || pid <= 0) return null
        return LegacyJavaCrash(scope, state.since, state.observed, now, pid)
    }

    fun decode(text: String): LegacyJavaCrash? = try {
        require(text.length <= 256)
        val fields = text.split('\n')
        require(fields.size == 7 && fields[0] == "1" && fields[6].isEmpty())
        val numbers = fields.subList(2, 6).map { raw -> raw.toLong().also { require(it.toString() == raw) } }
        require(numbers[3] in 1..Int.MAX_VALUE.toLong())
        LegacyJavaCrash(fields[1], numbers[0], numbers[1], numbers[2], numbers[3].toInt())
    } catch (_: Exception) { null }

    fun collect(state: NativeDiagnosticState, crash: LegacyJavaCrash?, now: Long): NativeDiagnosticState {
        if (crash == null || crash.scope != state.scope || crash.since != state.since) return state
        return NativeDiagnosticPolicy.collect(state, listOf(NativeExit(crash.timestamp, 4, crash.pid)), now)
    }
}

/** Observe once, then always forward the exact original thread and exception.
 * Do not wait for another crashing thread or retry after allocation/IO failure.
 */
class LegacyJavaCrashHandler(
    private val previous: Thread.UncaughtExceptionHandler,
    private val record: () -> Unit
) : Thread.UncaughtExceptionHandler {
    private val claimed = AtomicBoolean(false)
    override fun uncaughtException(thread: Thread, error: Throwable) {
        if (claimed.compareAndSet(false, true)) {
            try { record() } catch (_: Throwable) { /* Never replace the original fatal error. */ }
        }
        previous.uncaughtException(thread, error)
    }
}
