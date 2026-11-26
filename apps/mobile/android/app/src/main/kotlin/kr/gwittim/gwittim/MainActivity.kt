package kr.gwittim.gwittim

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

// 카카오톡 공고 넘기기 (D-058): ACTION_SEND(text/plain, image/*)를 받아 Dart로 넘긴다.
// 콜드 스타트는 Dart가 시작할 때 take로 가져가고, 앱이 켜져 있을 때(onNewIntent)는 arrived로 알린다.
// 이미지는 캐시 폴더에 복사해 경로만 넘긴다. Dart가 글자 인식을 끝내면 지운다(원본 이미지는 서버로 보내지 않음).
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: Map<String, String>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kr.gwittim.gwittim/share")
        ch.setMethodCallHandler { call, result ->
            if (call.method == "take") {
                result.success(pending)
                pending = null
            } else {
                result.notImplemented()
            }
        }
        channel = ch
        capture(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (capture(intent)) channel?.invokeMethod("arrived", null)
    }

    private fun capture(intent: Intent?): Boolean {
        if (intent == null || intent.action != Intent.ACTION_SEND) return false
        val type = intent.type ?: return false
        val payload: Map<String, String>? = when {
            type.startsWith("text/") -> intent.getStringExtra(Intent.EXTRA_TEXT)?.let { mapOf("kind" to "text", "text" to it) }
            type.startsWith("image/") -> copyImage(intent)?.let { mapOf("kind" to "image", "path" to it) }
            else -> null
        }
        if (payload == null) return false
        pending = payload
        // 같은 인텐트를 다시 처리하지 않게 비운다
        intent.action = null
        return true
    }

    @Suppress("DEPRECATION")
    private fun copyImage(intent: Intent): String? {
        val uri = intent.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM) ?: return null
        return try {
            val dir = File(cacheDir, "share_in").apply { mkdirs() }
            val file = File(dir, UUID.randomUUID().toString() + ".img")
            contentResolver.openInputStream(uri)?.use { input -> file.outputStream().use { input.copyTo(it) } } ?: return null
            file.absolutePath
        } catch (e: Exception) {
            null
        }
    }
}
