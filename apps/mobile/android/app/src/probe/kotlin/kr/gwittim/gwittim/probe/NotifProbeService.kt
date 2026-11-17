package kr.gwittim.gwittim.probe

import android.app.Notification
import android.os.Bundle
import android.os.Parcelable
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * 카카오톡 학교 채널 알림만 기록한다 (D-034 1주차 측정).
 * 다른 알림은 받는 즉시 버리고 아무것도 남기지 않는다.
 * 수집 주소·토큰을 넣고 빌드하면 공통 공지를 거르고 가려 서버로 올린다 (D-036, tool/notif_probe/collector.dart).
 */
class NotifProbeService : NotificationListenerService() {

    companion object {
        const val KAKAO = "com.kakao.talk"

        // localModel/kakaoTalk_data/ 내보내기 파일 이름의 방 6개
        val ROOMS = listOf(
            "명지전문대학 교수학습지원",
            "명지전문대학 공지사항",
            "명지전문대학 원격교육지원센터",
            "명지전문대학 상담센터",
            "명지전문대학 스마트케어",
            "명지전문대학 글로벌교육센터",
        )

        // 같은 key의 몇 번째 알림인지 (서비스가 다시 시작되면 0부터. post_time으로도 구분된다)
        private val seen = HashMap<String, Int>()
    }

    override fun onListenerConnected() {
        ProbeStore.event(this, "listener_connected")
    }

    override fun onListenerDisconnected() {
        ProbeStore.event(this, "listener_disconnected")
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName != KAKAO) return
        val n = sbn.notification ?: return
        val extras = n.extras ?: return

        val title = extras.text(Notification.EXTRA_TITLE)
        val conversationTitle = extras.text(Notification.EXTRA_CONVERSATION_TITLE)
        val subText = extras.text(Notification.EXTRA_SUB_TEXT)
        val summaryText = extras.text(Notification.EXTRA_SUMMARY_TEXT)
        val (room, roomField) = matchRoom(
            "title" to title, "conversation_title" to conversationTitle,
            "sub_text" to subText, "summary_text" to summaryText,
        ) ?: return // 학교 채널이 아니면 버린다

        val text = extras.text(Notification.EXTRA_TEXT)
        val bigText = extras.text(Notification.EXTRA_BIG_TEXT)
        val messages = messagesOf(extras)
        val lines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.map { it.toString() }

        val index = (seen[sbn.key] ?: -1) + 1
        seen[sbn.key] = index
        val isSummary = n.flags and Notification.FLAG_GROUP_SUMMARY != 0
        val id = UUID.randomUUID().toString()

        val record = JSONObject().apply {
            put("id", id)
            put("received_at", ProbeStore.iso(System.currentTimeMillis()))
            put("post_time", ProbeStore.iso(sbn.postTime))
            put("when", if (n.`when` > 0) ProbeStore.iso(n.`when`) else JSONObject.NULL)
            put("package", sbn.packageName)
            put("key", sbn.key)
            put("update_index", index)
            put("group_key", sbn.groupKey)
            put("is_group", sbn.isGroup)
            put("is_group_summary", isSummary)
            put("channel_id", n.channelId ?: JSONObject.NULL)
            put("category", n.category ?: JSONObject.NULL)
            put("template", extras.getString(Notification.EXTRA_TEMPLATE) ?: JSONObject.NULL)
            put("room", room)
            put("room_field", roomField)
            put("fields", JSONObject().apply {
                field("title", title)
                field("conversation_title", conversationTitle)
                field("text", text)
                field("big_text", bigText)
                field("sub_text", subText)
                field("summary_text", summaryText)
                field("info_text", extras.text(Notification.EXTRA_INFO_TEXT))
            })
            put("text_lines", if (lines == null) JSONObject.NULL else JSONArray(lines))
            put("messages", JSONArray().apply {
                for (m in messages) put(JSONObject().apply {
                    put("text", m.text)
                    put("length", ProbeStore.length(m.text))
                    put("time", if (m.time > 0) ProbeStore.iso(m.time) else JSONObject.NULL)
                    put("sender", m.sender ?: JSONObject.NULL)
                })
            })
            put("has_picture", extras.containsKey(Notification.EXTRA_PICTURE))
            put("has_large_icon", n.getLargeIcon() != null)
            put("actions", JSONArray().apply { n.actions?.forEach { put(it.title?.toString() ?: "") } })
            put("extras_keys", JSONArray(extras.keySet().sorted()))
        }
        ProbeStore.appendRecord(this, record)

        if (isSummary) return // 묶음 요약 알림은 본문이 없다
        // 분류할 본문과 그 메시지의 시각: 펼친 본문 > 메시지 묶음 > 본문.
        // 카톡은 안 읽은 메시지를 한 알림에 묶어(MessagingStyle) 다시 띄우므로, 메시지마다 자기 시각으로 따로 처리하고
        // 이 방에서 이미 처리한 시각 이후의 메시지만 넘긴다. (가장 긴 메시지 하나를 알림 시각으로 올리면
        // 짧은 새 메시지 대신 예전 메시지가 새 발송처럼 올라간다. 2026-11-17 10:06)
        val eventTime = if (n.`when` > 0) n.`when` else sbn.postTime
        val (items, source) = when {
            !bigText.isNullOrBlank() -> listOf(bigText to eventTime) to "big_text"
            messages.any { it.text.isNotBlank() } -> messages.filter { it.text.isNotBlank() }
                .map { it.text to (if (it.time > 0) it.time else eventTime) } to "messages"
            !text.isNullOrBlank() -> listOf(text to eventTime) to "text"
            else -> return
        }
        val since = ProbeStore.lastMessageTime(this, room)
        val fresh = items.filter { it.second > since }.sortedBy { it.second }
        if (fresh.isEmpty()) return // 같은 알림의 갱신: 새 메시지 없음
        ProbeStore.setLastMessageTime(this, room, fresh.last().second)
        for ((i, item) in fresh.withIndex()) {
            val (body, time) = item
            // 받는 사람 이름 찾기용 이전 본문은 지금 본문을 넣기 전에 읽는다
            val history = ProbeStore.recentBodies(this)
            ProbeStore.appendBody(this, body)
            // 가장 새 메시지가 기록 id를 그대로 쓴다 (비교 도구가 이 id로 잇는다)
            val cid = if (i == fresh.lastIndex) id else "$id#$i"
            ProbeEngine.classify(applicationContext, cid, body, source, room, time, history)
        }
    }

    private fun Bundle.text(key: String): String? = getCharSequence(key)?.toString()

    private fun JSONObject.field(name: String, value: String?) {
        put(name, if (value == null) JSONObject.NULL else JSONObject().apply {
            put("value", value)
            put("length", ProbeStore.length(value))
        })
    }

    private fun matchRoom(vararg candidates: Pair<String, String?>): Pair<String, String>? {
        for ((field, value) in candidates) {
            if (value == null) continue
            val room = ROOMS.firstOrNull { value.contains(it) } ?: continue
            return room to field
        }
        return null
    }

    private data class Message(val text: String, val time: Long, val sender: String?)

    @Suppress("DEPRECATION")
    private fun messagesOf(extras: Bundle): List<Message> {
        val raw: Array<Parcelable> = extras.getParcelableArray(Notification.EXTRA_MESSAGES) ?: return emptyList()
        return raw.mapNotNull { p ->
            val b = p as? Bundle ?: return@mapNotNull null
            val person = b.getParcelable<android.app.Person>("sender_person")
            Message(
                text = b.getCharSequence("text")?.toString() ?: "",
                time = b.getLong("time"),
                sender = person?.name?.toString() ?: b.getCharSequence("sender")?.toString(),
            )
        }
    }
}
