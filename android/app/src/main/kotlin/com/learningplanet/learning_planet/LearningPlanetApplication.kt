package com.learningplanet.learning_planet

import android.app.Application
import android.app.Activity
import android.os.Build
import android.os.Bundle
import java.util.Collections
import java.util.IdentityHashMap

class LearningPlanetApplication : Application() {
    val nativeDiagnostics by lazy { NativeDiagnostics(this) }
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT < 30) {
            // Before Activity/plugins start, but never make diagnostics a
            // prerequisite for opening the app if the OS rejects the hook.
            try { nativeDiagnostics.installLegacyCrashHandler() } catch (_: Exception) { }
            try {
                val started = Collections.newSetFromMap(IdentityHashMap<Activity, Boolean>())
                registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
                    override fun onActivityStarted(activity: Activity) {
                        started.add(activity); nativeDiagnostics.setForeground(true)
                    }
                    override fun onActivityStopped(activity: Activity) {
                        started.remove(activity); nativeDiagnostics.setForeground(started.isNotEmpty())
                    }
                    override fun onActivityDestroyed(activity: Activity) {
                        started.remove(activity); nativeDiagnostics.setForeground(started.isNotEmpty())
                    }
                    override fun onActivityCreated(activity: Activity, state: Bundle?) { }
                    override fun onActivityResumed(activity: Activity) { }
                    override fun onActivityPaused(activity: Activity) { }
                    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) { }
                })
                nativeDiagnostics.installLegacyAnrMonitor()
            } catch (_: Exception) { }
        }
    }
}
