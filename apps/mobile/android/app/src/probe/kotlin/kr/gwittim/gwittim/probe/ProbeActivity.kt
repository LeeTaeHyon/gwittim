package kr.gwittim.gwittim.probe

import android.content.ComponentName
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 측정 앱 화면: 알림 읽기 권한 상태와 기록 건수만 보여 준다. */
class ProbeActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gwittim/notif_probe_ui")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(
                        mapOf(
                            "permission" to listenerEnabled(),
                            "records" to ProbeStore.count(this, "records.jsonl"),
                            "classified" to ProbeStore.count(this, "classified.jsonl"),
                            "last_record" to ProbeStore.lastLine(this, "records.jsonl"),
                            "last_event" to ProbeStore.lastLine(this, "events.jsonl"),
                            "dir" to ProbeStore.dir(this).absolutePath,
                        ),
                    )
                    "openSettings" -> {
                        // 권한은 사용자가 이 화면에서 직접 켠다
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun listenerEnabled(): Boolean {
        val enabled = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: return false
        val me = ComponentName(this, NotifProbeService::class.java)
        return enabled.split(":").any { ComponentName.unflattenFromString(it) == me }
    }
}
