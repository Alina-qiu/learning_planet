package com.learningplanet.learning_planet

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.huawei.hms.aaid.HmsInstanceId
import com.huawei.hms.api.HuaweiApiAvailability
import com.huawei.hms.push.HmsMessaging
import com.huawei.agconnect.config.AGConnectServicesConfig
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import android.os.Bundle
import android.os.SystemClock
import android.util.Log

class MainActivity : FlutterActivity() {
    private val measureStartup = BuildConfig.MEASURE_STARTUP && BuildConfig.BUILD_TYPE != "release"
    private var activityStarted = 0L
    private var firstFrameReported = false
    private fun startupMark(stage: String, started: Long) {
        if (measureStartup) Log.i("LP_STARTUP", "source=android stage=$stage elapsed_us=${(SystemClock.elapsedRealtime() - started) * 1000} outcome=ok")
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        if (measureStartup) activityStarted = SystemClock.elapsedRealtime()
        super.onCreate(savedInstanceState)
        startupMark("activity_create", activityStarted)
    }
    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        if (!firstFrameReported) {
            firstFrameReported = true
            startupMark("activity_first_frame", activityStarted)
        }
    }
    private val nativeDiagnostics get() = (application as LearningPlanetApplication).nativeDiagnostics
    private val pushConfigured get() = BuildConfig.HMS_APP_ID.isNotEmpty() && BuildConfig.HMS_PROJECT_ID.isNotEmpty()
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        val pluginsStarted = if (measureStartup) SystemClock.elapsedRealtime() else 0L
        super.configureFlutterEngine(flutterEngine)
        startupMark("plugins", pluginsStarted)
        val channelsStarted = if (measureStartup) SystemClock.elapsedRealtime() else 0L
        TaskAlarms.install(applicationContext, MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "learning_planet/task_alarms"))
        nativeDiagnostics.install(MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "learning_planet/native_diagnostics"))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "learning_planet/parent_push").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "availability" -> result.success(mapOf("transport" to "hms", "configured" to pushConfigured,
                        "revision" to ParentPushGate.revision(applicationContext), "enabled" to ParentPushGate.enabled(applicationContext),
                        "available" to (pushConfigured && runCatching {
                            HuaweiApiAvailability.getInstance().isHuaweiMobileServicesAvailable(applicationContext) == 0
                        }.getOrDefault(false))))
                    "startup", "disable" -> result.success(ParentPushGate.disable(applicationContext))
                    "enable" -> result.success(ParentPushGate.enable(applicationContext, call.arguments as? Map<*, *> ?: emptyMap<String, Any>()))
                    "token" -> {
                        val revision = call.argument<Number>("revision")?.toLong()
                        if (revision == null || revision != ParentPushGate.revision(applicationContext) ||
                            !pushConfigured || !ParentPushGate.permitted(applicationContext)) {
                            result.success(null)
                        } else {
                            val waiting = ParentPushTokens.waitForToken()
                            thread(name = "parent-push-token") {
                                val token = try {
                                    // Supply only public identifiers read by HMS TokenReq.
                                    // Do not bundle an AGConnect server client/app secret.
                                    AGConnectServicesConfig.fromContext(applicationContext).apply {
                                        setParam("/client/app_id", BuildConfig.HMS_APP_ID)
                                        setParam("/client/project_id", BuildConfig.HMS_PROJECT_ID)
                                        setParam("/client/package_name", BuildConfig.APPLICATION_ID)
                                    }
                                    HmsMessaging.getInstance(applicationContext).isAutoInitEnabled = false
                                    val immediate = HmsInstanceId.getInstance(applicationContext).getToken(BuildConfig.HMS_APP_ID, "HCM")
                                    if (!immediate.isNullOrEmpty()) immediate else waiting.get(10, TimeUnit.SECONDS)
                                } catch (_: Exception) { null } finally { ParentPushTokens.remove(waiting) }
                                runOnUiThread { result.success(if (revision == ParentPushGate.revision(applicationContext)) token else null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("parent_push_unavailable", "后台提醒暂时不可用，请重试。", null)
            }
        }
        startupMark("channels", channelsStarted)
    }
}
