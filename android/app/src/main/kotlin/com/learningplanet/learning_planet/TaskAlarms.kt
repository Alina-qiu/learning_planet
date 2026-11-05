package com.learningplanet.learning_planet

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Executors

/** Serial, bounded native alarms. Only opaque IDs and delivery policy persist;
 * the receiver neither opens the account DB nor starts a Flutter engine. */
internal object TaskAlarms {
    private const val storeName = "task_alarms_v1"
    private const val tag = "learning-task-v1"
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "task-alarms").apply { isDaemon = true } }
    private val main = Handler(Looper.getMainLooper())
    private data class State(val revision: Long, val clock: TaskAlarmClock, val alarms: List<TaskAlarm>)
    private fun clock(context: Context) = TaskAlarmClock(System.currentTimeMillis(), SystemClock.elapsedRealtime(),
        runCatching { Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT) }.getOrDefault(-1))
    private fun prefs(context: Context) = context.getSharedPreferences(storeName, Context.MODE_PRIVATE)
    private fun read(context: Context): State {
        val p = prefs(context)
        val revision = p.getLong("revision", 0)
        return try {
            val json = JSONObject(p.getString("state", null) ?: return State(revision, clock(context), emptyList()))
            val rows = json.getJSONArray("alarms")
            require(rows.length() <= 60)
            val alarms = List(rows.length()) { i -> rows.getJSONObject(i).let {
                TaskAlarm(it.getInt("id"), it.getLong("at"), it.getString("timezone"), it.getString("quiet_start"),
                    it.getString("quiet_end"), it.getString("token"), it.getBoolean("consumed"))
            } }
            require(alarms.all(TaskAlarmPolicy::valid) && alarms.map { it.id }.toSet().size == alarms.size)
            State(revision, TaskAlarmClock(json.getLong("wall"), json.getLong("elapsed"), json.getInt("boot")), alarms)
        } catch (_: Exception) { State(revision, clock(context), emptyList()) }
    }
    private fun save(context: Context, state: State) {
        val rows = JSONArray(state.alarms.map { row -> JSONObject().put("id", row.id).put("at", row.at)
            .put("timezone", row.zone).put("quiet_start", row.quietStart).put("quiet_end", row.quietEnd)
            .put("token", row.token).put("consumed", row.consumed) })
        val json = JSONObject().put("wall", state.clock.wall).put("elapsed", state.clock.elapsed)
            .put("boot", state.clock.boot).put("alarms", rows)
        check(prefs(context).edit().putLong("revision", state.revision).putString("state", json.toString()).commit())
    }
    private fun intent(context: Context, row: TaskAlarm, revision: Long) = Intent(context, TaskAlarmReceiver::class.java)
        .setData(Uri.parse("learningplanet-task://alarm/$revision/${row.id}/${row.token}"))
    private fun pendingIntent(context: Context, row: TaskAlarm, revision: Long, create: Boolean) =
        PendingIntent.getBroadcast(context, row.id, intent(context, row, revision), PendingIntent.FLAG_IMMUTABLE or
            (if (create) PendingIntent.FLAG_UPDATE_CURRENT else PendingIntent.FLAG_NO_CREATE))
    private fun cancel(context: Context, state: State) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        for (row in state.alarms) pendingIntent(context, row, state.revision, false)?.let { alarms.cancel(it); it.cancel() }
    }
    private fun schedule(context: Context, state: State) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        for (row in state.alarms.filter { !it.consumed && it.at > System.currentTimeMillis() }) {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, row.at, pendingIntent(context, row, state.revision, true)!!)
        }
    }
    private fun clear(context: Context): Long {
        val state = read(context)
        val next = state.revision + 1
        require(next in 1..9007199254740991)
        save(context, State(next, clock(context), emptyList()))
        cancel(context, state)
        val manager = context.getSystemService(NotificationManager::class.java)
        for (notification in manager.activeNotifications.filter { it.tag == tag }) manager.cancel(tag, notification.id)
        return next
    }
    private fun replace(context: Context, args: Map<*, *>) {
        require(args.keys == setOf("revision", "alarms"))
        val old = read(context)
        if ((args["revision"] as? Number)?.toLong() != old.revision) throw ScopeChanged()
        val values = args["alarms"] as? List<*> ?: error("invalid")
        require(values.size <= 60)
        val now = clock(context)
        require(now.boot >= 0)
        val rows = values.map { value ->
            val row = value as? Map<*, *> ?: error("invalid")
            require(row.keys == setOf("id", "at", "timezone", "quiet_start", "quiet_end"))
            val id = (row["id"] as? Number)?.toLong() ?: error("invalid")
            require(id in 0..Int.MAX_VALUE)
            val at = (row["at"] as? Number)?.toLong() ?: error("invalid")
            val entry = TaskAlarm(id.toInt(), at, row["timezone"] as String, row["quiet_start"] as String,
                row["quiet_end"] as String, UUID.randomUUID().toString())
            require(TaskAlarmPolicy.valid(entry) && at - now.wall <= TaskAlarmPolicy.horizon)
            val existing = old.alarms.find { it.id == entry.id }
            if (existing != null && existing.copy(token = entry.token, consumed = false) == entry) existing else entry
        }.filter { it.at > now.wall }
        require(rows.map { it.id }.toSet().size == rows.size)
        if (rows == old.alarms && TaskAlarmPolicy.clockValid(old.clock, now) && ParentPushGate.permitted(context)) return
        // Retire all old intents before any replacement is eligible to display.
        save(context, old.copy(alarms = emptyList()))
        cancel(context, old)
        val next = State(old.revision, now, if (ParentPushGate.permitted(context)) rows else emptyList())
        save(context, next)
        try { schedule(context, next) } catch (error: Exception) { clear(context); throw error }
    }
    private class ScopeChanged : Exception()
    fun install(context: Context, channel: MethodChannel) {
        val app = context.applicationContext
        channel.setMethodCallHandler { call, result ->
            if (call.method !in setOf("clear", "replace", "pending")) { result.notImplemented(); return@setMethodCallHandler }
            worker.execute {
                try {
                    val response: Any? = when (call.method) {
                        "clear" -> clear(app)
                        "replace" -> { replace(app, call.arguments as? Map<*, *> ?: error("invalid")); null }
                        else -> read(app).alarms.filter { !it.consumed }.map { mapOf("id" to it.id, "at" to it.at) }
                    }
                    main.post { result.success(response) }
                } catch (_: ScopeChanged) { main.post { result.error("alarm_scope_changed", "提醒范围已变化，请重试", null) } }
                catch (_: Exception) {
                    // A rejected replacement may contain changed quiet hours.
                    // Do not leave the older policy eligible for delivery.
                    if (call.method == "replace") runCatching { clear(app) }
                    main.post { result.error("task_alarms_unavailable", "本机任务提醒暂不可用，请重试", null) }
                }
            }
        }
    }
    fun receive(context: Context, uri: Uri?, finished: () -> Unit) = worker.execute {
        try {
            if (uri?.scheme != "learningplanet-task" || uri.host != "alarm" || uri.pathSegments.size != 3) return@execute
            val state = read(context)
            if (uri.pathSegments[0].toLongOrNull() != state.revision) return@execute
            val row = state.alarms.find { it.id == uri.pathSegments[1].toIntOrNull() && it.token == uri.pathSegments[2] } ?: return@execute
            if (row.consumed) return@execute
            val permitted = ParentPushGate.permitted(context) && TaskAlarmPolicy.mayDeliver(row, state.clock, clock(context))
            save(context, state.copy(alarms = state.alarms.map { if (it.id == row.id) it.copy(consumed = true) else it }))
            // Recheck after durable consumption, including a quiet boundary crossed during IO.
            if (permitted && TaskAlarmPolicy.mayDeliver(row, state.clock, clock(context)) && ParentPushGate.permitted(context)) show(context, row)
        } catch (_: Exception) { /* Fail closed; no notification on corrupt state or failed persistence. */ }
        finally { finished() }
    }
    @Suppress("DEPRECATION")
    private fun show(context: Context, row: TaskAlarm) {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel("learning_tasks", "学习任务", NotificationManager.IMPORTANCE_DEFAULT))
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, "learning_tasks") else Notification.Builder(context)
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        manager.notify(tag, row.id, builder.setSmallIcon(R.drawable.ic_notification).setContentTitle("学习星球 · 任务提醒")
            .setContentText("有学习任务需要关注，请打开应用查看。").setContentIntent(open).setAutoCancel(true)
            .setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_PRIVATE).setCategory(Notification.CATEGORY_REMINDER).build())
    }
    fun restore(context: Context, timeChanged: Boolean, finished: () -> Unit) = worker.execute {
        try {
            val state = read(context)
            val now = clock(context)
            if (timeChanged || !ParentPushGate.permitted(context) || !TaskAlarmPolicy.canRestore(state.clock, now)) {
                clear(context)
            } else {
                val next = state.copy(clock = now, alarms = state.alarms.filter { !it.consumed && it.at > now.wall && it.at - now.wall <= TaskAlarmPolicy.horizon })
                save(context, next); cancel(context, state); schedule(context, next)
            }
        } catch (_: Exception) { runCatching { clear(context) } }
        finally { finished() }
    }
}

class TaskAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        TaskAlarms.receive(context.applicationContext, intent.data) { pending.finish() }
    }
}
class TaskAlarmBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED, Intent.ACTION_TIME_CHANGED)) return
        val pending = goAsync()
        TaskAlarms.restore(context.applicationContext, intent.action == Intent.ACTION_TIME_CHANGED) { pending.finish() }
    }
}
