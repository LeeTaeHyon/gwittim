"""귀띔 서버 API (W13, SPEC §7). Cloud Run에서 실행할 FastAPI 앱. 배포는 팀장의 별도 요청 후.

경로 (D-005 #10의 틀에 맞춘 HTTP 경로):
  GET    /v1/profile               get_profile
  PUT    /v1/profile               update_profile
  DELETE /v1/profile               탈퇴: 프로필·저장 삭제 (SPEC §10)
  GET    /v1/recommendations       list_recommendations
  GET    /v1/notices/{notice_id}   get_notice
  GET    /v1/saved                 list_saved_notices
  PUT    /v1/saved/{notice_id}     save_notice (반복 요청 안전)
  DELETE /v1/saved/{notice_id}     delete_saved_notice (반복 요청 안전)
  POST   /v1/analysis              request_detail_analysis: AI 상세 분석 요청 (동의·크레딧 필요, 성공해야 차감)
  GET    /v1/analysis/{notice_id}  get_detail_analysis: 받은 분석 다시 보기 (차감 없음)
  GET    /v1/credits               get_credits: 잔액·다음 충전·사용 내역
  POST   /v1/ingest/kakao          팀장 폰 수집기의 학교 채널 알림톡 올리기 (D-036). 수집 토큰(X-Ingest-Token)으로만.
                                   토큰이 설정되지 않은 서버에서는 없는 경로처럼 404
"""
from __future__ import annotations

import hmac

import logging

from fastapi import Depends, FastAPI, Header, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response

from backend.agent import service as agent
from backend.collectors.mjc_kakao.inbox import InboxError, accept
from backend.contracts import schema_errors
from backend.dictionaries import codes, unknown_profile_codes, unlisted_with_major
from backend.recommendation import recommend

from .deps import Deps

log = logging.getLogger("gwittim.api")

_STATUS = {
    "unauthenticated": 401,
    "permission_denied": 403,
    "invalid_argument": 400,
    "not_found": 404,
    "unavailable": 503,
    # 크레딧은 결제가 아니라 무료 지급분이지만, 다른 오류와 구분되는 상태가 필요해 402로 둔다
    "insufficient_credits": 402,
    "request_in_progress": 409,
    "consent_required": 403,
}
_MESSAGES = {
    "unauthenticated": "다시 로그인해 주세요.",
    "permission_denied": "권한이 없어요.",
    "invalid_argument": "입력 값을 확인해 주세요.",
    "not_found": "찾을 수 없어요.",
    "unavailable": "잠시 후 다시 시도해 주세요.",
    "insufficient_credits": "크레딧이 부족합니다.",
    "request_in_progress": "같은 요청을 처리하고 있습니다.",
    "consent_required": "AI 상세 분석 동의가 필요합니다.",
}
_SUMMARY_FIELDS = (
    "notice_id",
    "notice_version",
    "title",
    "category",
    "source_url",
    "published",
    "application_deadline",
    "deadline_note",
    "lifecycle_status",
)


class ApiError(Exception):
    def __init__(self, code: str):
        self.code = code


def _error(code: str) -> JSONResponse:
    return JSONResponse({"error": {"code": code, "message": _MESSAGES[code]}}, status_code=_STATUS[code])


def _summary(notice: dict) -> dict:
    return {k: notice[k] for k in _SUMMARY_FIELDS}


def create_app(deps: Deps) -> FastAPI:
    app = FastAPI(title="Gwittim API", version="0.1.0", docs_url=None, redoc_url=None, openapi_url=None)

    @app.exception_handler(ApiError)
    async def _api_error(_: Request, exc: ApiError):
        return _error(exc.code)

    @app.exception_handler(agent.AgentError)
    async def _agent_error(_: Request, exc: agent.AgentError):
        return _error(exc.code)

    @app.exception_handler(RequestValidationError)
    async def _bad_request(_: Request, __: RequestValidationError):
        return _error("invalid_argument")

    @app.exception_handler(Exception)
    async def _unexpected(_: Request, exc: Exception):
        log.exception("unexpected error")  # 서버 로그에만 남기고 응답에는 상세를 넣지 않는다
        return _error("unavailable")

    def current_uid(authorization: str | None = Header(default=None)) -> str:
        if not authorization or not authorization.startswith("Bearer "):
            raise ApiError("unauthenticated")
        uid = deps.verifier.verify(authorization.removeprefix("Bearer ").strip())
        if not uid:
            raise ApiError("unauthenticated")
        return uid

    @app.get("/v1/profile")
    def get_profile(uid: str = Depends(current_uid)):
        profile = deps.profiles.get(uid)
        if profile is None:
            raise ApiError("not_found")
        return profile

    @app.put("/v1/profile")
    def update_profile(body: dict, uid: str = Depends(current_uid)):
        profile = {**body, "updated_at": deps.now_iso()}
        if schema_errors("user_profile", profile) or not _codes_known(profile):
            raise ApiError("invalid_argument")
        previous = (deps.profiles.get(uid) or {}).get("agent_consent")
        consent = profile.get("agent_consent")
        if consent is not None:
            # 동의 시각은 앱 시계를 믿지 않는다: 새 동의나 version 변경이면 서버 시각, 그대로면 이전 값
            same = previous is not None and previous["version"] == consent["version"]
            profile["agent_consent"] = {
                "version": consent["version"],
                "agreed_at": previous["agreed_at"] if same else deps.now_iso(),
            }
        elif previous is not None:
            # agent_consent가 빠지면 철회다. 저장된 리포트도 지운다(명세 §5). 프로필을 쓰기 전에 지워
            # 중간에 실패해도 철회한 사용자에게 저장본이 남지 않게 한다
            deps.reports.delete_all(uid)
        deps.profiles.put(uid, profile)
        return profile

    @app.delete("/v1/profile", status_code=204)
    def delete_account_data(uid: str = Depends(current_uid)):
        deps.saved.delete_all(uid)
        deps.reports.delete_all(uid)
        deps.credits.delete(uid)
        deps.profiles.delete(uid)
        return Response(status_code=204)

    @app.get("/v1/recommendations")
    def list_recommendations(
        limit: int = Query(default=20, ge=1, le=50),
        q: str | None = Query(default=None, max_length=50),
        category: str | None = Query(default=None),
        uid: str = Depends(current_uid),
    ):
        # 공고 탭 검색·분류 칩 (D-026). 모르는 분류 코드는 입력 오류
        if category is not None and category not in codes("categories"):
            raise ApiError("invalid_argument")
        profile = deps.profiles.get(uid) or _empty_profile()
        return recommend(
            deps.notices.list_published(),
            profile,
            today=deps.today_kst(),
            generated_at=deps.now_iso(),
            limit=limit,
            query=q,
            category=category,
        )

    @app.get("/v1/notices/{notice_id}")
    def get_notice(notice_id: str, uid: str = Depends(current_uid)):
        notice = deps.notices.get(notice_id)
        if notice is None:
            raise ApiError("not_found")
        return notice

    @app.get("/v1/saved")
    def list_saved(uid: str = Depends(current_uid)):
        items = []
        for saved in deps.saved.list(uid)[:50]:
            notice = deps.notices.get(saved["notice_id"])
            if notice is not None:  # 공개본이 내려간(검토 대기) 공고는 다시 게시될 때까지 목록에서 뺀다
                items.append({"saved": saved, "notice": _summary(notice)})
        return {"items": items, "next_cursor": None, "generated_at": deps.now_iso()}

    @app.put("/v1/saved/{notice_id}")
    def save_notice(notice_id: str, uid: str = Depends(current_uid)):
        existing = deps.saved.get(uid, notice_id)
        if existing:
            return existing
        notice = deps.notices.get(notice_id)
        if notice is None:
            raise ApiError("not_found")
        saved = {
            "notice_id": notice_id,
            "saved_at": deps.now_iso(),
            "saved_notice_version": notice["notice_version"],
            "saved_deadline_snapshot": notice["application_deadline"],
        }
        deps.saved.put(uid, saved)
        return saved

    @app.delete("/v1/saved/{notice_id}", status_code=204)
    def delete_saved(notice_id: str, uid: str = Depends(current_uid)):
        deps.saved.delete(uid, notice_id)
        return Response(status_code=204)

    @app.post("/v1/analysis")
    def request_detail_analysis(body: dict, uid: str = Depends(current_uid)):
        return agent.request_analysis(uid, body, deps)

    @app.get("/v1/analysis/{notice_id}")
    def get_detail_analysis(notice_id: str, uid: str = Depends(current_uid)):
        return agent.get_analysis(uid, notice_id, deps)

    @app.get("/v1/credits")
    def get_credits(uid: str = Depends(current_uid)):
        return agent.get_credits(uid, deps)

    @app.post("/v1/ingest/kakao")
    def ingest_kakao(body: dict, x_ingest_token: str | None = Header(default=None)):
        # 사용자 로그인과 따로: 팀장 폰의 수집 앱은 Firebase가 없는 별도 패키지라 수집 전용 토큰을 쓴다
        if deps.kakao_inbox is None or not deps.ingest_token:
            raise ApiError("not_found")
        if not x_ingest_token:
            raise ApiError("unauthenticated")
        if not hmac.compare_digest(x_ingest_token.encode(), deps.ingest_token.encode()):
            raise ApiError("permission_denied")
        try:
            accepted = accept(body, deps.now_iso())
        except InboxError:
            raise ApiError("invalid_argument") from None
        if accepted is None:  # 개인 알림·잡음: 저장하지 않는다. 폰이 다시 올리지 않게 성공으로 답한다
            return {"stored": False, "reason": "not_broadcast"}
        doc_id, doc = accepted
        created = deps.kakao_inbox.put(doc_id, doc)
        return {"stored": True, "id": doc_id, "new": created}

    return app


def _empty_profile() -> dict:
    return {
        "university_id": None,
        "major_id": None,
        "grade": None,
        "enrollment_status": None,
        "interest_ids": [],
        "target_role_ids": [],
    }


def _codes_known(profile: dict) -> bool:
    """사전에 있는 코드만 받는다. '목록에 없는 학교'(unlisted)는 학과를 가질 수 없다."""
    return not unknown_profile_codes(profile) and not unlisted_with_major(profile)
