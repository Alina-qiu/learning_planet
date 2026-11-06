package com.learningplanet.learning_planet

import android.os.Bundle
import com.huawei.hms.push.HmsMessageService
import com.huawei.hms.push.RemoteMessage
import java.util.concurrent.CompletableFuture

internal object ParentPushTokens {
    private val pending = mutableSetOf<CompletableFuture<String?>>()
    @Synchronized fun waitForToken(): CompletableFuture<String?> = CompletableFuture<String?>().also { pending.add(it) }
    @Synchronized fun complete(token: String?) {
        if (token.isNullOrEmpty() || token.length > 4096) return
        pending.forEach { it.complete(token) }; pending.clear()
    }
    @Synchronized fun remove(value: CompletableFuture<String?>) { pending.remove(value) }
    @Synchronized fun cancel() { pending.forEach { it.complete(null) }; pending.clear() }
}

class ParentPushService : HmsMessageService() {
    override fun onMessageReceived(message: RemoteMessage?) {
        ParentPushGate.receive(applicationContext, message?.data)
    }
    override fun onNewToken(token: String?) { ParentPushTokens.complete(token) }
    override fun onNewToken(token: String?, bundle: Bundle?) { ParentPushTokens.complete(token) }
    override fun onTokenError(error: Exception?) { ParentPushTokens.cancel() }
    override fun onTokenError(error: Exception?, bundle: Bundle?) { ParentPushTokens.cancel() }
}
