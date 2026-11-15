package kr.gwittim.gwittim.probe

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * 알림을 받은 순간 Dart 분류기(lib/classifier)로 분류한다.
 * 화면 없는 Flutter 엔진에서 tool/notif_probe/main.dart의 notifProbeBackground를 돌린다.
 * 알림 수신 콜백은 메인 스레드에서 오므로 이 객체도 메인 스레드에서만 쓴다.
 */
object ProbeEngine {
    private const val CHANNEL = "gwittim/notif_probe"
    private const val ENTRYPOINT = "notifProbeBackground"

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var ready = false
    private val pending = ArrayList<Map<String, Any?>>()

    fun classify(
        context: Context, id: String, body: String, source: String,
        room: String, postTime: Long, history: List<String>,
    ) {
        val request = mapOf(
            "method" to "classify", "id" to id, "body" to body, "source" to source,
            "room" to room, "post_time" to postTime, "history" to history,
            "dir" to ProbeStore.dir(context).absolutePath,
        )
        if (!ensureStarted(context)) return
        if (ready) send(context, request) else pending.add(request)
    }

    /** 못 올린 공지를 다시 올린다 (앱 화면을 열 때). */
    fun flush(context: Context) {
        val request = mapOf("method" to "flush", "dir" to ProbeStore.dir(context).absolutePath)
        if (!ensureStarted(context)) return
        if (ready) send(context, request) else pending.add(request)
    }

    private fun ensureStarted(context: Context): Boolean = try {
        start(context)
        true
    } catch (e: Exception) {
        ProbeStore.event(context, "engine_start_failed", e.javaClass.simpleName)
        false
    }

    private fun start(context: Context) {
        if (engine != null) return
        val app = context.applicationContext
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(app)
        loader.ensureInitializationComplete(app, null)
        val e = FlutterEngine(app, null, false) // 플러그인은 쓰지 않는다
        val ch = MethodChannel(e.dartExecutor.binaryMessenger, CHANNEL)
        ch.setMethodCallHandler { call, result ->
            if (call.method == "ready") {
                ready = true
                val queued = pending.toList()
                pending.clear()
                queued.forEach { send(app, it) }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        engine = e
        channel = ch
        e.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), ENTRYPOINT),
        )
    }

    private fun send(context: Context, request: Map<String, Any?>) {
        val method = request["method"] as String
        channel?.invokeMethod(method, request - "method", object : MethodChannel.Result {
            override fun success(result: Any?) {
                val map = result as? Map<*, *> ?: return
                if (method == "flush") {
                    ProbeStore.event(context, "flush", "sent=" + map["sent"] + " left=" + map["left"])
                    return
                }
                ProbeStore.appendClassified(context, JSONObject().apply {
                    put("id", request["id"])
                    put("body_source", request["source"])
                    for ((k, v) in map) {
                        put(k.toString(), if (v is List<*>) JSONArray(v) else if (v is Map<*, *>) JSONObject(v) else v)
                    }
                })
            }

            override fun error(code: String, message: String?, details: Any?) {
                ProbeStore.event(context, method + "_failed", code)
            }

            override fun notImplemented() {
                ProbeStore.event(context, method + "_not_implemented")
            }
        })
    }
}
