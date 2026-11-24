package de.kintura.app

import android.content.Intent
import android.os.Bundle
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Push messages of Aktuelles and Nachrichten through Firebase Cloud Messaging. The system shows them by
 * itself while the app is closed; here the app gets the key of the device for the
 * server, and hears when one of them was tapped. Without google-services.json there is
 * no Firebase, and the app says so.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /** What a tapped push message that opened the app leads to, until the app asks for it. */
    private var opened: Map<String, String>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        opened = fromPush(intent) ?: opened
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        fromPush(intent)?.let { channel?.invokeMethod("opened", it) }
    }

    /**
     * The server puts kintura=activity into what it sends of Aktuelles, and kintura=message
     * with the circle and the chat for a new message.
     */
    private fun fromPush(intent: Intent?): Map<String, String>? {
        val kind = intent?.getStringExtra("kintura")
        if (kind != "activity" && kind != "message") return null
        return mapOf(
            "kind" to kind,
            "family_id" to (intent?.getStringExtra("family_id") ?: ""),
            "chat_id" to (intent?.getStringExtra("chat_id") ?: ""),
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        UpdateInstaller.register(this, flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "de.kintura.app/push")
        this.channel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(FirebaseApp.getApps(this).isNotEmpty())
                "token" -> {
                    if (FirebaseApp.getApps(this).isEmpty()) {
                        result.success(null)
                    } else {
                        FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                            if (task.isSuccessful) result.success(task.result) else result.success(null)
                        }
                    }
                }
                "deleteToken" -> {
                    if (FirebaseApp.getApps(this).isEmpty()) {
                        result.success(null)
                    } else {
                        FirebaseMessaging.getInstance().deleteToken().addOnCompleteListener { result.success(null) }
                    }
                }
                "openedFrom" -> {
                    result.success(opened)
                    opened = null
                }
                else -> result.notImplemented()
            }
        }
    }
}
