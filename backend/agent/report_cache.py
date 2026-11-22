"""리포트 저장본의 키와 만료 계산(명세 docs/agent-privacy-spec.md §4). 순수 함수만 둔다.

시간대: 이 환경에는 tzdata가 없어 zoneinfo('Asia/Seoul')가 동작하지 않는다.
한국은 서머타임이 없으므로 고정 +09:00(KST)를 쓴다. 시간대 없는(naive) datetime은 KST로 본다.
"""
import hashlib
import json
from datetime import date, datetime, time, timedelta, timezone

KST = timezone(timedelta(hours=9), "KST")
DEADLINE_RETENTION_DAYS = 30
NO_DEADLINE_RETENTION_DAYS = 60
LEDGER_RETENTION_DAYS = 90


def _normalize(value):
    if isinstance(value, dict):
        return {str(k): _normalize(v) for k, v in value.items()}
    if isinstance(value, (list, tuple, set, frozenset)):
        items = [_normalize(v) for v in value]
        return sorted(items, key=lambda v: json.dumps(v, sort_keys=True, ensure_ascii=False))
    return value


def cache_key(notice_id: str, payload: dict, harness: str | None = None) -> str:
    """공고 id + 보낸 값 전체(+ 지침 버전)의 SHA-256(16진 문자열).

    harness(지침 버전)를 주면 해시에 넣는다. 지침을 고쳐 버전을 올리면 같은 입력도 키가 달라져 새로 분석한다.

    보낸 값은 키를 정렬하고, 목록 값은 정렬해서 해시한다. 칩·관심사 목록은 순서가 의미 없으므로
    순서만 다른 입력은 같은 키가 된다(순서가 의미 있는 목록이 생기면 이 판단을 다시 봐야 한다).
    값이 하나라도 바뀌면 키가 달라진다. 공고 id는 해시 입력에 구분해서 넣는다.
    """
    keyed = {"notice_id": notice_id, "payload": _normalize(payload)}
    if harness:
        keyed["harness"] = harness
    body = json.dumps(
        keyed,
        sort_keys=True, ensure_ascii=False, separators=(",", ":"),
    )
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def _aware(dt: datetime) -> datetime:
    return dt.replace(tzinfo=KST) if dt.tzinfo is None else dt


def deadline_from_date_info(info: dict | None) -> date | datetime | None:
    """공고 계약의 마감일(date_info: date, time, timezone, precision)을 만료 계산용 값으로 바꾼다.

    - None → None(마감 미상)
    - precision=minute이고 시간대가 Asia/Seoul 또는 UTC → 그 시각(datetime)
    - 그 밖(precision=date, 시간대 미상·그 밖의 시간대) → 날짜만(date). 시간대를 임의로 정하지 않고
      그 날 0시 KST 기준으로 계산한다(실제 마감보다 늦게 지우는 일은 없음)
    """
    if info is None:
        return None
    day = date.fromisoformat(info["date"])
    clock, zone = info.get("time"), info.get("timezone")
    if info.get("precision") == "minute" and clock and zone in ("Asia/Seoul", "UTC"):
        tz = KST if zone == "Asia/Seoul" else timezone.utc
        return datetime.combine(day, time.fromisoformat(clock), tzinfo=tz)
    return day


def report_expires_at(deadline: dict | date | datetime | None, created_at: datetime) -> datetime:
    """저장본 만료 시각. 마감일이 있으면 마감일 + 30일, None(미상)이면 생성 시각 + 60일.

    마감 시각이 없는 날짜(date)는 그 날 0시(00:00 KST)를 기준으로 30일을 더한다.
    마감 시각이 있는 datetime이면 그 시각 + 30일. 공고의 date_info(dict)를 그대로 넘겨도 된다.
    """
    if isinstance(deadline, dict):
        deadline = deadline_from_date_info(deadline)
    if deadline is None:
        return _aware(created_at) + timedelta(days=NO_DEADLINE_RETENTION_DAYS)
    if isinstance(deadline, datetime):
        return _aware(deadline) + timedelta(days=DEADLINE_RETENTION_DAYS)
    start_of_day = datetime.combine(deadline, time.min, tzinfo=KST)
    return start_of_day + timedelta(days=DEADLINE_RETENTION_DAYS)


def is_expired(expires_at: datetime, now: datetime) -> bool:
    """만료 시각과 같거나 지났으면 True."""
    return _aware(now) >= _aware(expires_at)


def ledger_expires_at(created_at: datetime) -> datetime:
    """크레딧 내역 보관 만료: 생성 후 90일."""
    return _aware(created_at) + timedelta(days=LEDGER_RETENTION_DAYS)
