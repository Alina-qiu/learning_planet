package com.learningplanet.learning_planet

/** A live API29 error state is an observation, not a timeout guessed by a
 * heartbeat. The adapter supplies only this process's system condition code.
 * A fresh binding/foreground interval must observe a healthy process first.
 */
class LegacyAnrPolicy {
    private var scope: String? = null
    private var since = 0L
    private var lastNow = 0L
    private var needsClear = true
    private var episode: NativeExit? = null

    fun reset() { needsClear = true; episode = null }

    fun observe(
        binding: NativeDiagnosticState?, foreground: Boolean, debugging: Boolean,
        condition: Int?, now: Long, pid: Int
    ): NativeExit? {
        val valid = binding != null && binding.scope != null &&
            NativeDiagnosticPolicy.uuid.matches(binding.scope) && binding.since > 0 &&
            binding.observed >= binding.since && now >= binding.observed && pid > 0
        val changed = !valid || binding.scope != scope || binding.since != since || now < lastNow
        if (changed || !foreground || debugging) {
            scope = if (valid) binding.scope else null
            since = if (valid) binding.since else 0
            needsClear = true
            episode = null
        }
        lastNow = now
        if (!valid || !foreground || debugging) return null
        // A failed OS query must neither rearm nor duplicate a previous episode.
        if (condition == null) return null
        if (condition == 0) {
            needsClear = false
            episode = null
            return null
        }
        if (condition != 2 || needsClear) return null // NOT_RESPONDING = 2.
        if (episode == null) episode = NativeExit(now, 6, pid) // REASON_ANR = 6.
        return episode
    }
}
