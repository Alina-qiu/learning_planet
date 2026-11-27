package com.learningplanet.learning_planet

import android.app.Activity
import android.app.ActivityManager
import android.app.Instrumentation
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.view.KeyEvent
import android.view.WindowManager
import android.widget.TextView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/** Included only with -PlegacyAnrFixture=true, in a separate application ID. */
class LegacyAnrFixtureActivity : Activity() {
    private val main = Handler(Looper.getMainLooper())
    private val messenger = BridgeMessenger()
    private val started = AtomicBoolean(false)

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(TextView(this).apply { text = "原生ANR采集本机验证"; textSize = 24f })
        (application as LearningPlanetApplication).nativeDiagnostics
            .install(MethodChannel(messenger, "test/native_diagnostics"))
    }

    override fun onWindowFocusChanged(focus: Boolean) {
        super.onWindowFocusChanged(focus)
        if (focus && started.compareAndSet(false, true)) thread(name = "anr-fixture") { exercise() }
    }

    private fun exercise() {
        val scope = intent.getStringExtra("scope") ?: return
        val phase = intent.getStringExtra("phase") ?: return
        if (!NativeDiagnosticPolicy.uuid.matches(scope) || phase !in setOf("capture", "verify")) return
        val report = JSONObject().put("run", scope).put("phase", phase).put("pid", Process.myPid())
        try {
            check(Build.VERSION.SDK_INT == 29 && !Debug.isDebuggerConnected())
            if (phase == "verify") {
                val expected = requireNotNull(intent.getStringExtra("event"))
                val events = read(scope)
                check(events.size == 1 && events.single()["event_id"] == expected)
                check(events.single().keys == setOf("event_id", "day", "operation"))
                check(events.single()["operation"] == "androidAnr")
                check(read(scope) == events)
                call("ack", mapOf("scope" to scope, "ids" to listOf(expected)))
                SystemClock.sleep(3000)
                check(read(scope).isEmpty())
                check(read(UUID.randomUUID().toString()).isEmpty())
                check(read(scope).isEmpty())
                read(null)
                report.put("fixed_fields_replay_ack_scope_passed", true)
            } else {
                read(null)
                check(read(scope).isEmpty())
                SystemClock.sleep(5000)
                val entered = CountDownLatch(1)
                val released = CountDownLatch(1)
                val unblock = CountDownLatch(1)
                main.post {
                    entered.countDown()
                    try { unblock.await(45, TimeUnit.SECONDS) } finally { released.countDown() }
                }
                try {
                    check(entered.await(5, TimeUnit.SECONDS))
                    // No registered Instrumentation runner: Android uses its normal
                    // foreground ANR handling. Public input helpers target our own
                    // focused window. Two senders keep input queued while UI stalls.
                    for (delay in listOf(0L, 2000L)) thread(name = "fixture-input", isDaemon = true) {
                        SystemClock.sleep(delay)
                        try { Instrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_A) }
                        catch (_: Exception) { /* The ANR dialog may take focus. */ }
                    }
                    val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val deadline = SystemClock.elapsedRealtime() + 35000
                    var confirmed = false
                    while (SystemClock.elapsedRealtime() < deadline) {
                        confirmed = manager.processesInErrorState?.any {
                            it.pid == Process.myPid() && it.processName == packageName &&
                                it.condition == ActivityManager.ProcessErrorStateInfo.NOT_RESPONDING
                        } == true
                        if (confirmed) break
                        SystemClock.sleep(100)
                    }
                    check(confirmed) { "System did not confirm the fixture ANR" }
                    report.put("system_confirmed_anr", true)
                    SystemClock.sleep(3000)
                } finally { unblock.countDown() }
                check(released.await(10, TimeUnit.SECONDS))
                val events = read(scope)
                check(events.size == 1) { "Expected one persisted ANR" }
                val event = events.single()
                check(event.keys == setOf("event_id", "day", "operation"))
                check(event["operation"] == "androidAnr")
                check(read(scope) == events)
                report.put("event", event["event_id"])
            }
            report.put("completed", true)
        } catch (failure: Throwable) {
            report.put("failure", failure.javaClass.simpleName + ": " + failure.message)
            report.put("completed", false)
        }
        // Synthetic result fields only; never serialize the OS error report.
        File(filesDir, "native-anr-$scope-$phase.json").writeText(report.toString())
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
        check(done.await(10, TimeUnit.SECONDS)) { "Native bridge timeout" }
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
