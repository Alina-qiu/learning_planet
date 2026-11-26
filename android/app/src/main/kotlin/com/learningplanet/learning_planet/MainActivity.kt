package com.learningplanet.learning_planet

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
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
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        val pluginsStarted = if (measureStartup) SystemClock.elapsedRealtime() else 0L
        super.configureFlutterEngine(flutterEngine)
        startupMark("plugins", pluginsStarted)
        val channelsStarted = if (measureStartup) SystemClock.elapsedRealtime() else 0L
        TaskAlarms.install(applicationContext, MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "learning_planet/task_alarms"))
        nativeDiagnostics.install(MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "learning_planet/native_diagnostics"))
        startupMark("channels", channelsStarted)
    }
}
