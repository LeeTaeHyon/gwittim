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
