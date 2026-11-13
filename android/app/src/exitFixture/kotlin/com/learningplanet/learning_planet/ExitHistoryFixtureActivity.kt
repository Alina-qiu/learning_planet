package com.learningplanet.learning_planet

import android.app.Activity
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.widget.TextView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/** Deliberate failures are compiled only into the independent exitfixture APK. */
class ExitHistoryFixtureActivity : Activity() {
    private val main = Handler(Looper.getMainLooper())
    private val messenger = BridgeMessenger()

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(TextView(this).apply { text = "系统退出记录本机验证"; textSize = 24f })
        (application as LearningPlanetApplication).nativeDiagnostics
            .install(MethodChannel(messenger, "test/native_diagnostics"))
        thread(name = "exit-history-fixture") { exercise() }
    }

    private fun exercise() {
        val scope = intent.getStringExtra("scope") ?: return
        val phase = intent.getStringExtra("phase") ?: return
        if (!NativeDiagnosticPolicy.uuid.matches(scope) || phase !in setOf("java", "native", "collect", "verify")) return
        val report = JSONObject().put("run", scope).put("phase", phase).put("pid", Process.myPid())
        var crash: String? = null
        try {
            check(Build.VERSION.SDK_INT == 36 && !Debug.isDebuggerConnected())
            when (phase) {
                "java" -> {
                    read(null)
                    check(read(scope).isEmpty())
                    crash = "java"
                }
                "native" -> {
                    val javaPid = prior(scope, "java").getInt("pid")
                    val observed = awaitExit(javaPid, ApplicationExitInfo.REASON_CRASH)
                    report.put("java_exit", observed)
                    val events = read(scope)
                    check(events.size == 1 && events.single()["operation"] == "androidJavaCrash")
                    checkFixedFields(events)
                    check(read(scope) == events)
                    report.put("java_event", events.single()["event_id"])
                    crash = "native"
                }
                "collect" -> {
                    val java = prior(scope, "java")
                    val native = prior(scope, "native")
                    report.put("java_exit", awaitExit(java.getInt("pid"), ApplicationExitInfo.REASON_CRASH))
                    report.put("native_exit", awaitExit(native.getInt("pid"), ApplicationExitInfo.REASON_CRASH_NATIVE))
                    val events = read(scope)
                    checkFixedFields(events)
                    check(events.size == 2 && events.map { it["operation"] }.toSet() ==
                        setOf("androidJavaCrash", "androidNativeCrash"))
                    check(events.single { it["operation"] == "androidJavaCrash" }["event_id"] == native.getString("java_event"))
                    check(read(scope) == events)
                    report.put("events", JSONArray(events.map { JSONObject(it) }))
                }
                "verify" -> {
                    val previous = prior(scope, "collect")
                    report.put("force_stop_exit", awaitExit(previous.getInt("pid"), ApplicationExitInfo.REASON_USER_REQUESTED))
                    val expected = previous.getJSONArray("events")
                    val events = read(scope)
                    checkFixedFields(events)
                    check(events.size == expected.length())
                    for (index in events.indices) {
                        val row = expected.getJSONObject(index)
                        check(events[index] == row.keys().asSequence().associateWith { row.getString(it) })
                    }
                    check(read(scope) == events)
                    call("ack", mapOf("scope" to scope, "ids" to events.map { it["event_id"] }))
                    check(read(scope).isEmpty())
                    check(read(scope).isEmpty())
                    check(read(UUID.randomUUID().toString()).isEmpty())
                    check(read(scope).isEmpty())
                    check(read(null).isEmpty())
                    check(read(scope).isEmpty())
                    read(null)
                    report.put("replay_ack_scope_unbind_passed", true)
                }
            }
            report.put("completed", true)
        } catch (failure: Throwable) {
            crash = null
            report.put("completed", false).put("failure", failure.javaClass.simpleName)
        }
        // Synthetic evidence only; no description, stack, trace stream or logcat.
        File(filesDir, "native-exit-$scope-$phase.json").writeText(report.toString())
        when (crash) {
            "java" -> main.postDelayed({ throw IllegalStateException("synthetic-exit-history-java") }, 1500)
            "native" -> {
                SystemClock.sleep(1500)
                Os.kill(Process.myPid(), OsConstants.SIGABRT)
            }
        }
    }

    private fun prior(scope: String, phase: String) =
        JSONObject(File(filesDir, "native-exit-$scope-$phase.json").readText()).also {
            check(it.getString("run") == scope && it.getString("phase") == phase && it.getBoolean("completed"))
        }

    private fun awaitExit(pid: Int, reason: Int): JSONObject {
        val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val until = SystemClock.elapsedRealtime() + 15000
        do {
            val exit = manager.getHistoricalProcessExitReasons(packageName, pid, 10)
                .firstOrNull { it.pid == pid && it.processName == packageName }
            if (exit != null && exit.reason == reason) {
                return JSONObject().put("pid", pid).put("reason", exit.reason).put("timestamp", exit.timestamp)
            }
            SystemClock.sleep(200)
        } while (SystemClock.elapsedRealtime() < until)
        error("Expected system exit record missing")
    }

    private fun checkFixedFields(events: List<Map<String, Any?>>) {
        check(events.all { it.keys == setOf("event_id", "day", "operation") })
        check(events.all { NativeDiagnosticPolicy.uuid.matches(it["event_id"] as String) })
        check(events.map { it["event_id"] }.toSet().size == events.size)
    }

    @Suppress("UNCHECKED_CAST")
    private fun read(scope: String?): List<Map<String, Any?>> =
        call("read", mapOf("scope" to scope)) as List<Map<String, Any?>>

    private fun call(method: String, arguments: Map<String, Any?>): Any? {
        val done = CountDownLatch(1)
        val outcome = AtomicReference<Result<Any?>?>()
        main.post {
            val input = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, arguments))
            input.flip()
            messenger.handler!!.onMessage(input) { reply ->
                outcome.set(runCatching {
                    requireNotNull(reply).flip()
                    StandardMethodCodec.INSTANCE.decodeEnvelope(reply)
                })
                done.countDown()
            }
        }
        check(done.await(10, TimeUnit.SECONDS))
        return outcome.get()!!.getOrThrow()
    }

    private class BridgeMessenger : BinaryMessenger {
        var handler: BinaryMessenger.BinaryMessageHandler? = null
        override fun send(channel: String, message: ByteBuffer?) { error("Unexpected native send") }
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            error("Unexpected native send")
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            this.handler = handler
        }
    }
}
