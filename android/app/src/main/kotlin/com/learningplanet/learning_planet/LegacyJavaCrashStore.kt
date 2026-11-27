package com.learningplanet.learning_planet

import android.content.Context
import android.os.Process
import android.util.AtomicFile
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** One small atomic marker, outside backups. The fatal path never acquires a
 * worker/SharedPreferences lock or starts Flutter, a network call or another UI.
 */
class LegacyJavaCrashStore(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "legacy_java_crash_v1"))
    private val busy = AtomicBoolean(false)
    private val binding = AtomicReference<NativeDiagnosticState?>(null)

    fun bind(state: NativeDiagnosticState?) { binding.set(state) }

    fun record() {
        if (!busy.compareAndSet(false, true)) return
        try {
            val crash = LegacyJavaCrashPolicy.capture(binding.get(), System.currentTimeMillis(), Process.myPid()) ?: return
            var stream: FileOutputStream? = null
            try {
                stream = file.startWrite()
                stream.write(crash.encode().toByteArray(Charsets.US_ASCII))
                file.finishWrite(stream)
            } catch (error: Throwable) {
                file.failWrite(stream)
                throw error
            }
        } finally { busy.set(false) }
    }

    /** Keep the marker until the consumer has durably saved its stable event ID.
     * An interrupted import or failed delete is safely replayed on the next read.
     */
    fun consume(accept: (LegacyJavaCrash?) -> Unit): Boolean {
        if (!busy.compareAndSet(false, true)) return false
        try {
            val crash = try {
                file.openRead().use { input ->
                    val bytes = ByteArray(257)
                    var count = 0
                    while (count < bytes.size) {
                        val read = input.read(bytes, count, bytes.size - count)
                        if (read < 0) break
                        count += read
                    }
                    if (count > 256) null else LegacyJavaCrashPolicy.decode(String(bytes, 0, count, Charsets.US_ASCII))
                }
            } catch (_: java.io.FileNotFoundException) { null }
            accept(crash)
            file.delete()
            return true
        } finally { busy.set(false) }
    }
}
