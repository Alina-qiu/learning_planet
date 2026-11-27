package com.learningplanet.learning_planet

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.Process
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** OS-owned exit history is inspected on a serial worker, never the UI thread. */
class NativeDiagnostics(context: Context) {
    private val app = context.applicationContext
    private val preferences = app.getSharedPreferences("native_diagnostics_v1", Context.MODE_PRIVATE)
    private val legacy by lazy { LegacyJavaCrashStore(app) }
    private var legacyInstalled = false
    private var anrInstalled = false
    private val anrPolicy = LegacyAnrPolicy()
    @Volatile private var foreground = false
    // Updated only after a successful journal commit, on the shared worker.
    private var anrBinding: NativeDiagnosticState? = null
    companion object {
        // Shared across Activity/engine recreation: one journal writer per process.
        private val worker = Executors.newSingleThreadScheduledExecutor { runnable -> Thread(runnable, "native-diagnostics").apply { isDaemon = true } }
    }
    private val main = Handler(Looper.getMainLooper())

    fun installLegacyCrashHandler() {
        if (Build.VERSION.SDK_INT >= 30 || legacyInstalled) return
        val previous = Thread.getDefaultUncaughtExceptionHandler() ?: return
        legacy.bind(restore())
        Thread.setDefaultUncaughtExceptionHandler(LegacyJavaCrashHandler(previous, legacy::record))
        legacyInstalled = true
    }

    fun setForeground(value: Boolean) {
        if (foreground == value) return
        foreground = value
        // Even a background/resume shorter than the poll interval is a boundary.
        worker.execute { anrPolicy.reset() }
    }

    fun installLegacyAnrMonitor() {
        if (Build.VERSION.SDK_INT >= 30 || anrInstalled) return
        anrInstalled = true
        // No wake lock or foreground service. While background/unbound this
        // does not query the OS or write storage. It can be suspended by Android.
        worker.scheduleWithFixedDelay({
            try {
                val state = anrBinding
                val now = System.currentTimeMillis()
                val active = foreground && state?.scope != null
                val debugging = active && (Debug.isDebuggerConnected() || Debug.waitingForDebugger())
                val condition = if (active && !debugging) {
                    try {
                        val manager = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                        // Never read/retain longMsg, shortMsg, stackTrace or tag.
                        manager.processesInErrorState?.firstOrNull {
                            it.pid == Process.myPid() && it.processName == app.packageName
                        }?.condition ?: ActivityManager.ProcessErrorStateInfo.NO_ERROR
                    } catch (_: Exception) { null }
                } else null
                val observed = anrPolicy.observe(state, active, debugging, condition, now, Process.myPid())
                if (state != null && observed != null) {
                    val updated = NativeDiagnosticPolicy.collect(state, listOf(observed), now)
                    if (updated != state) save(updated)
                }
            } catch (_: Exception) {
                // Diagnostic failure must not change application behavior.
            }
        }, 2, 2, TimeUnit.SECONDS)
    }

    fun install(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            if (call.method !in setOf("read", "ack")) { result.notImplemented(); return@setMethodCallHandler }
            worker.execute {
                try {
                    val args = call.arguments as? Map<*, *> ?: error("invalid")
                    val scope = args["scope"] as? String
                    require(args["scope"] == null || (scope != null && NativeDiagnosticPolicy.uuid.matches(scope)))
                    val state = restore()
                    val response: Any?
                    if (call.method == "read") {
                        require(args.keys == setOf("scope"))
                        val now = System.currentTimeMillis()
                        val bound = NativeDiagnosticPolicy.bind(state, scope, now)
                        // Persist the scope boundary even if an OEM denies the history API.
                        save(bound)
                        val exits = if (scope != null && Build.VERSION.SDK_INT >= 30) {
                            val manager = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                            manager.getHistoricalProcessExitReasons(app.packageName, 0, 50)
                                .filter { it.processName == app.packageName }
                                .map { NativeExit(it.timestamp, it.reason, it.pid) }
                        } else emptyList()
                        var updated = NativeDiagnosticPolicy.collect(bound, exits, now)
                        check(legacy.consume { crash ->
                            // API30+ keeps the OS-confirmed source; do not count
                            // an old pre-upgrade marker a second time.
                            if (Build.VERSION.SDK_INT < 30) updated = LegacyJavaCrashPolicy.collect(updated, crash, now)
                            save(updated)
                        })
                        response = updated.pending.take(50).map { it.wire() }
                    } else {
                        require(args.keys == setOf("scope", "ids") && scope != null)
                        val ids = args["ids"] as? List<*> ?: error("invalid")
                        require(ids.size <= 50 && ids.all { it is String && NativeDiagnosticPolicy.uuid.matches(it) })
                        save(NativeDiagnosticPolicy.acknowledge(state, scope, ids.filterIsInstance<String>().toSet()))
                        response = null
                    }
                    main.post { result.success(response) }
                } catch (_: Exception) {
                    main.post { result.error("native_diagnostics_unavailable", "运行诊断暂不可用", null) }
                }
            }
        }
    }

    private fun restore(): NativeDiagnosticState = try {
        val raw = preferences.getString("state", null)
        if (raw == null || raw.length > 262144) NativeDiagnosticState() else {
            val value = JSONObject(raw)
            require(value.keys().asSequence().toSet() == setOf("scope", "since", "observed", "pending", "seen"))
            val scope = if (value.isNull("scope")) null else value.get("scope") as String
            require(scope == null || NativeDiagnosticPolicy.uuid.matches(scope))
            val since = (value.get("since") as Number).toLong(); val observed = (value.get("observed") as Number).toLong()
            require(since > 0 && observed >= since)
            val pending = value.getJSONArray("pending"); val seen = value.getJSONObject("seen")
            require(pending.length() <= 250 && seen.length() <= 1000)
            val events = (0 until pending.length()).map { index ->
                val row = pending.getJSONObject(index)
                require(row.keys().asSequence().toSet() == setOf("event_id", "day", "operation"))
                val id = row.get("event_id") as String; val day = row.get("day") as String; val operation = row.get("operation") as String
                require(NativeDiagnosticPolicy.uuid.matches(id) && operation in NativeDiagnosticPolicy.operations && java.time.LocalDate.parse(day).toString() == day)
                NativeDiagnosticEvent(id, day, operation)
            }
            val markers = seen.keys().asSequence().associateWith { key ->
                val date = seen.get(key) as String
                require(NativeDiagnosticPolicy.uuid.matches(key) && java.time.LocalDate.parse(date).toString() == date)
                date
            }
            require(events.map { it.id }.toSet().size == events.size && events.all { markers[it.id] == it.day })
            NativeDiagnosticState(scope, since, observed, events, markers)
        }
    } catch (_: Exception) { NativeDiagnosticState() }

    private fun save(state: NativeDiagnosticState) {
        // No attribution while a scope transition or persistence is incomplete.
        anrBinding = null
        if (Build.VERSION.SDK_INT < 30) legacy.bind(null)
        val json = JSONObject().put("scope", state.scope ?: JSONObject.NULL).put("since", state.since).put("observed", state.observed)
            .put("pending", JSONArray(state.pending.map { JSONObject(it.wire()) })).put("seen", JSONObject(state.seen))
        check(preferences.edit().putString("state", json.toString()).commit())
        anrBinding = state
        if (Build.VERSION.SDK_INT < 30) legacy.bind(state)
    }
}
