package com.learningplanet.learning_planet

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject

/** One lock for receipt, durable state, and display/cancel. No Flutter isolate or
 * account database is opened by a background message. Stored IDs are opaque. */
internal object ParentPushGate {
    private const val name = "parent_push_gate_v1"
    private const val channel = "parent_remote_v1"
    private const val tag = "parent-remote-v1"
    private fun prefs(context: Context) = context.getSharedPreferences(name, Context.MODE_PRIVATE)
    private fun clock(context: Context): PushClock {
        val boot = try { Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT).toString() }
            catch (_: Exception) { "" }
        return PushClock(System.currentTimeMillis(), SystemClock.elapsedRealtime(), boot)
    }
    private fun read(context: Context): PushGate {
        val p = prefs(context)
        val revision = p.getLong("revision", 0)
        return try {
            val encoded = p.getString("gate", null) ?: return PushGate(revision)
            val row = JSONObject(encoded)
            val seen = row.getJSONArray("seen")
            if (seen.length() > 1000) return PushGate(revision)
            PushGate(revision, row.getString("nonce"), row.getLong("server"), row.getLong("expires"),
                row.getLong("rtt"), row.getLong("settings"),
                PushClock(row.getLong("wall"), row.getLong("elapsed"), row.getString("boot")),
                List(seen.length()) { seen.getString(it) })
        } catch (_: Exception) { PushGate(revision) }
    }
    private fun write(context: Context, gate: PushGate) {
        val row = JSONObject().put("nonce", gate.nonce).put("server", gate.server).put("expires", gate.expires)
            .put("rtt", gate.rtt).put("settings", gate.minimumSettings).put("wall", gate.clock.wall)
            .put("elapsed", gate.clock.elapsed).put("boot", gate.clock.boot).put("seen", JSONArray(gate.seen))
        check(prefs(context).edit().putLong("revision", gate.revision).putString("gate", row.toString()).commit())
    }
    @Synchronized fun revision(context: Context): Long = read(context).revision
    @Synchronized fun enabled(context: Context): Boolean = read(context).nonce != null
    @Synchronized fun disable(context: Context): Long {
        val next = read(context).revision + 1
        check(next in 1..9007199254740991)
        check(prefs(context).edit().putLong("revision", next).remove("gate").commit())
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.cancel(tag, 1); manager.cancel(tag, 2)
        ParentPushTokens.cancel()
        return next
    }
    @Synchronized fun enable(context: Context, values: Map<*, *>): Boolean {
        val gate = ParentPushPolicy.activate(read(context), values, clock(context)) ?: return false
        if (!permitted(context)) return false
        write(context, gate)
        return true
    }
    fun permitted(context: Context): Boolean =
        (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            context.getSystemService(NotificationManager::class.java).areNotificationsEnabled()

    @Synchronized fun receive(context: Context, encoded: String?) {
        try {
            if (encoded == null || encoded.toByteArray(Charsets.UTF_8).size > 4096 || !permitted(context)) return
            val json = JSONObject(encoded)
            val data = mutableMapOf<String, String>()
            for (key in json.keys()) data[key] = json.get(key) as? String ?: return
            val gate = read(context)
            if (!ParentPushPolicy.accepts(gate, data, clock(context))) return
            val manager = context.getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                manager.createNotificationChannel(NotificationChannel(channel, "家长后台提醒", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                })
                if (manager.getNotificationChannel(channel).importance == NotificationManager.IMPORTANCE_NONE) return
            }
            // Persist before display: a process crash cannot turn a replay into
            // another alert. An OS failure may lose a prompt; inbox stays intact.
            write(context, gate.copy(seen = (gate.seen + data.getValue("message_id")).takeLast(1000)))
            val weekly = data["kind"] == "weekly"
            val intent = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val open = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channel) else Notification.Builder(context)
            manager.notify(tag, if (weekly) 2 else 1, builder.setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("学习星球").setContentText(if (weekly) "上一周学习报告已更新" else "有兑换申请待审批")
                .setVisibility(Notification.VISIBILITY_PRIVATE).setContentIntent(open).setAutoCancel(true)
                .setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_REMINDER).build())
        } catch (_: Exception) { /* Never log message bodies or device tokens. */ }
    }
}
