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
"""
from __future__ import annotations

import logging

from fastapi import Depends, FastAPI, Header, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response

from backend.contracts import schema_errors
from backend.dictionaries import unknown_profile_codes
from backend.recommendation import recommend

from .deps import Deps

log = logging.getLogger("gwittim.api")

_STATUS = {
    "unauthenticated": 401,
    "permission_denied": 403,
    "invalid_argument": 400,
    "not_found": 404,
    "unavailable": 503,
}
_MESSAGES = {
    "unauthenticated": "다시 로그인해 주세요.",
    "permission_denied": "권한이 없어요.",
    "invalid_argument": "입력 값을 확인해 주세요.",
    "not_found": "찾을 수 없어요.",
    "unavailable": "잠시 후 다시 시도해 주세요.",
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
        deps.profiles.put(uid, profile)
        return profile

    @app.delete("/v1/profile", status_code=204)
    def delete_account_data(uid: str = Depends(current_uid)):
        deps.saved.delete_all(uid)
        deps.profiles.delete(uid)
        return Response(status_code=204)

    @app.get("/v1/recommendations")
    def list_recommendations(limit: int = Query(default=20, ge=1, le=50), uid: str = Depends(current_uid)):
        profile = deps.profiles.get(uid) or _empty_profile()
        return recommend(
            deps.notices.list_published(), profile, today=deps.today_kst(), generated_at=deps.now_iso(), limit=limit
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
    """사전에 있는 코드만 받는다."""
    return not unknown_profile_codes(profile)
