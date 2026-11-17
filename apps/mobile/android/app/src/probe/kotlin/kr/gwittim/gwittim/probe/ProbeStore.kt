package kr.gwittim.gwittim.probe

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 기록 파일. 앱 전용 외부 폴더라 USB로 연결하면 adb pull로 받는다:
 *   /sdcard/Android/data/kr.gwittim.gwittim.probe/files/notif_probe/
 *     records.jsonl     알림 한 건에 한 줄
 *     classified.jsonl  기기 안 분류 결과 (records의 id로 잇는다)
 *     events.jsonl      서비스 연결·분류 실패 같은 상태 기록 (알림 내용 없음)
 *     bodies.jsonl      학교 채널 알림 본문 (받는 사람 이름 찾기용, 폰 밖으로 나가지 않음)
 *     upload_queue.jsonl  아직 못 올린 공통 공지 (가린 본문), uploaded.jsonl  올린 기록 (본문 없음)
 */
object ProbeStore {
    private const val DIR = "notif_probe"

    fun dir(context: Context): File {
        val base = context.getExternalFilesDir(null) ?: context.filesDir
        return File(base, DIR).apply { mkdirs() }
    }

    fun iso(millis: Long): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US).format(Date(millis))

    /** 파이썬 len과 같은 글자 수 (코드 포인트) */
    fun length(s: String): Int = s.codePointCount(0, s.length)

    @Synchronized
    private fun append(context: Context, name: String, json: JSONObject) {
        File(dir(context), name).appendText(json.toString() + "\n", Charsets.UTF_8)
    }

    fun appendRecord(context: Context, json: JSONObject) = append(context, "records.jsonl", json)

    fun appendClassified(context: Context, json: JSONObject) = append(context, "classified.jsonl", json)

    private fun prefs(context: Context) = context.getSharedPreferences("notif_probe", Context.MODE_PRIVATE)

    /** 이 방에서 마지막으로 처리한 메시지 시각(밀리초). 처음이면 0. */
    fun lastMessageTime(context: Context, room: String): Long = prefs(context).getLong("last_time:$room", 0L)

    fun setLastMessageTime(context: Context, room: String, millis: Long) {
        prefs(context).edit().putLong("last_time:$room", millis).apply()
    }

    fun appendBody(context: Context, body: String) = append(context, "bodies.jsonl", JSONObject().put("body", body))

    /** 최근 학교 채널 알림 본문. 받는 사람 이름은 두 번 이상 나온 '○○○님'이라 이전 알림이 필요하다 (parser.detect_names). */
    fun recentBodies(context: Context, limit: Int = 300): List<String> {
        val f = File(dir(context), "bodies.jsonl")
        if (!f.exists()) return emptyList()
        return f.useLines { lines ->
            lines.filter { it.isNotBlank() }.map { JSONObject(it).optString("body") }.toList().takeLast(limit)
        }
    }

    fun event(context: Context, kind: String, detail: String? = null) = append(
        context, "events.jsonl",
        JSONObject().apply {
            put("at", iso(System.currentTimeMillis()))
            put("event", kind)
            if (detail != null) put("detail", detail)
        },
    )

    fun count(context: Context, name: String): Int {
        val f = File(dir(context), name)
        if (!f.exists()) return 0
        return f.useLines { lines -> lines.count { it.isNotBlank() } }
    }

    fun lastLine(context: Context, name: String): String? {
        val f = File(dir(context), name)
        if (!f.exists()) return null
        return f.useLines { lines -> lines.lastOrNull { it.isNotBlank() } }
    }
}
