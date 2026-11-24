"""자체 학습한 공고 줄 분류 모델로 규칙 분석을 보강한다 (D-042). Gemma(D-007)의 추출 역할을 맡는다.

모델은 공고를 줄로 나눠 줄마다 "마감 근거인가, 자격·우대 조건인가, 재학·학교·학년 조건인가"를 여러 꼬리표로
동시에 맞힌다. 날짜·코드로 바꾸는 일은 하지 않는다. 고른 줄의 날짜는 기존 날짜 파서가 읽고, 값은 꼬리표가 정한다.
그래서 이 분석기가 내는 근거는 항상 원문 한 줄 그대로다(지어낸 문구가 나올 수 없다).

합치는 방식 (시험 공고 94건 비교, docs/extract-model.md):
- 신청 마감: 모델만. 모델이 마감 줄을 고르지 않으면 마감 없음(미상)으로 둔다. 규칙으로 메우면 맞는 것만큼
  틀린 마감도 늘었다. 틀린 마감은 열린 공고를 닫힌 것으로 보이게 하므로 미상보다 나쁘다.
- 재학 상태·학년·학교: 규칙이 찾은 필드는 그대로, 규칙이 못 찾은 필드만 모델로 채운다.
- 기타 자격·우대 조건(미해석 조건): 규칙 결과에 모델이 고른 줄을 더한다. 놓친 조건이 판정을 뒤집는 쪽이 더 나쁘다.
- 누구나(제한 없음): 모델 점수가 낮아 쓰지 않는다. 규칙 판단을 그대로 둔다.

가중치(약 225MB)는 저장소에 넣지 않는다. 기본 위치 <data-dir>/models/extract-v1/ (meta.json, config.json,
tokenizer.json, tokenizer_config.json, model.safetensors). torch·transformers는 `uv sync --group extract`로 설치한다.
모델을 불러오지 못하거나 예측이 실패하면 규칙 분석 결과를 규칙 분석 버전으로 돌려준다 (LLM 분석기와 같은 규칙).
"""
from __future__ import annotations

import json
import re
import sys
from datetime import date
from pathlib import Path
from typing import Callable

from backend.sources import SourceConfig

from .dates import date_info, parse_line, points_near
from .llm import redact
from .rules import EXCLUDES, OTHER_STATUS, RuleBasedAnalyzer, tidy_unresolved

MODEL_SUBDIR = Path("models/extract-v1")  # 배치 --data-dir 아래 (기본 data/local/models/extract-v1)
MODEL_NOTE = "모델 추출"  # unresolved_condition.note: 규칙이 아니라 이 모델이 고른 줄

# 줄 확률 예측기: 줄 목록 -> 줄마다 꼬리표 확률 목록. 테스트에서는 가짜를 넣는다.
Predictor = Callable[[list[str]], list[list[float]]]

_ENROLLMENT = {"enr_enrolled": "enrolled", "enr_on_leave": "on_leave", "enr_graduated": "graduated"}
_ENROLLMENT_ORDER = ["enrolled", "on_leave", "graduated"]


def _compact(text: str) -> str:
    return re.sub(r"\s+", "", text)


def model_lines(raw: dict) -> list[str]:
    """학습 때와 같은 줄 나누기: 제목 한 줄 + 본문의 빈 줄 아닌 줄(앞뒤 공백 제거)."""
    return [raw["title"].strip()] + [l.strip() for l in raw["body_text"].splitlines() if l.strip()]


class ExtractModelAnalyzer:
    # 마감은 이 분석기가 정한다. 알림톡 분석기가 빈 마감을 날짜 규칙으로 다시 메우지 않게 알린다 (kakao.py)
    decides_deadline = True

    def __init__(
        self,
        predictor: Predictor,
        labels: list[str],
        thresholds: dict[str, float],
        model_version: str,
        base: RuleBasedAnalyzer | None = None,
    ):
        self.predictor = predictor
        self.labels = labels
        self.thresholds = thresholds
        self.base = base or RuleBasedAnalyzer()
        self.version = f"{self.base.version}+{model_version}"
        self.model_analyzed = 0  # 모델 예측을 쓴 공고 수
        self.model_failed = 0  # 예측 실패로 규칙 분석만 쓴 공고 수

    @classmethod
    def load(cls, model_dir: Path, base: RuleBasedAnalyzer | None = None) -> "ExtractModelAnalyzer":
        meta = json.loads((model_dir / "meta.json").read_text(encoding="utf-8"))
        return cls(KoElectraPredictor(model_dir, meta), meta["labels"], meta["thresholds"], model_version(meta), base)

    def analyze(self, raw: dict, source: SourceConfig) -> dict:
        fields = self.base.analyze(raw, source)
        if fields["category"] == "admin_notice":
            return fields  # 업체·교직원 대상 행정 공지: 규칙이 일부러 비운 마감·조건을 모델이 되살리지 않는다 (rule-0.9)
        lines = model_lines(raw)
        try:
            probs = self.predictor([redact(l) for l in lines])  # 학습 데이터처럼 연락처를 지우고 넣는다
            if len(probs) != len(lines):
                raise ValueError("줄 수가 맞지 않음")
            self.model_analyzed += 1
        except Exception:
            self.model_failed += 1
            return {**fields, "_analysis_version": self.base.version}

        tags = [{n for n, p in zip(self.labels, row) if p >= self.thresholds[n]} for row in probs]
        self._deadline(fields, raw, source, lines, probs)
        self._conditions(fields["eligibility"], source, lines, tags)
        self._others(fields["eligibility"], raw, lines, tags)
        return fields

    # ---------- 마감 ----------

    def _deadline(self, fields: dict, raw: dict, source: SourceConfig, lines: list[str], probs: list[list[float]]) -> None:
        """마감 확률이 가장 높은 줄 하나. 문턱을 넘지 않으면 마감 없음. 그 줄의 날짜는 기존 파서가 읽는다."""
        j = self.labels.index("deadline")
        best = max(range(len(lines)), key=lambda i: probs[i][j])
        fields["application_start"] = fields["application_deadline"] = None
        if probs[best][j] < self.thresholds["deadline"]:
            return
        line = lines[best]
        start, end = parse_line(line)
        if raw.get("published") and (raw["source_id"] == "mjc_kakao" or start is None):
            # 연도 없는 날짜('11월 15일(일) 23:59까지')는 게시·발송일 기준으로 읽는다 (D-019, kakao.fill_dates와 같은 규칙).
            # 알림톡은 늘, 게시판은 연도 있는 날짜를 못 읽었을 때만. 범위면 끝 날짜
            points = points_near(line, date.fromisoformat(raw["published"]["date"]))
            if points:
                # 한 줄의 여러 날짜가 범위인지 따로 열거한 일정인지 모르므로 시작일은 정하지 않는다 (fill_dates와 같게)
                start, end = None, max(points, key=lambda p: p.day)
        point = end or start
        if point is None:
            return  # 모델이 고른 줄에서 날짜를 읽지 못하면 미상
        fields["application_deadline"] = date_info(point, line, source.timezone)
        if end and start and start.day <= end.day:
            fields["application_start"] = date_info(start, line, source.timezone)

    # ---------- 재학 상태·학년·학교 ----------

    def _conditions(self, elig: dict, source: SourceConfig, lines: list[str], tags: list[set[str]]) -> None:
        """규칙이 못 찾은 필드만 채운다. 값마다 처음 나온 줄을 근거로 쓰고, 근거는 첫 값의 줄."""
        found: dict[str, tuple[list, str]] = {}

        def add(field: str, value, line: str) -> None:
            values, evidence = found.setdefault(field, ([], line))
            if value not in values:
                values.append(value)

        for line, t in zip(lines, tags):
            if EXCLUDES.search(line):  # 누구를 빼는 줄은 허용 조건으로 만들지 않는다 (D-023)
                continue
            for name in sorted(t):
                if name in _ENROLLMENT:
                    if OTHER_STATUS.search(line):  # 졸업 예정·복학·편입 줄은 재학 상태로 판정 못 함, 규칙이 직접 확인으로 보냄 (D-046)
                        continue
                    add("enrollment_status", _ENROLLMENT[name], line)
                elif name.startswith("grade_"):
                    add("grade", int(name[-1]), line)
                elif name.startswith("uni_") and source.university_id and name == f"uni_{source.university_id}":
                    add("university_id", source.university_id, line)

        have = {c["field"] for c in elig["conditions"]}
        for field, (values, evidence) in found.items():
            if field in have:
                continue
            if field == "enrollment_status":
                values = [v for v in _ENROLLMENT_ORDER if v in values]
            elif field == "grade":
                values = sorted(values)
                if values == [1, 2, 3, 4]:  # 학년 전체 나열은 제한이 아니다 (규칙의 '학년 전체 나열 무시'와 같음)
                    continue
            one = len(values) == 1
            elig["conditions"].append({
                "field": field,
                "operator": "eq" if one else "in",
                "value": values[0] if one else values,
                "evidence": evidence,
                "validation_status": "validated",
            })
        if elig["conditions"]:
            elig["explicitly_unrestricted"], elig["unrestricted_evidence"] = False, None

    # ---------- 기타 자격·우대 조건 ----------

    def _others(self, elig: dict, raw: dict, lines: list[str], tags: list[set[str]]) -> None:
        """모델이 자격·우대로 고른 줄을 미해석 조건에 더한다. 규칙이 이미 낸 문구는 다시 내지 않는다."""
        seen = [_compact(u["evidence"]) for u in elig["unresolved_conditions"]]
        extra = []
        for line, t in zip(lines, tags):
            if not t & {"qual", "pref"}:
                continue
            key = _compact(line)
            if any(key in s or s in key for s in seen if s):
                continue
            extra.append({"evidence": line, "note": MODEL_NOTE})
            seen.append(key)
        if not extra:
            return
        # 규칙 결과와 합쳐 다시 정리: 번호·항목 이름 떼기, 같은 문구 하나로, 우대 사항 표시 (D-015)
        elig["unresolved_conditions"], _ = tidy_unresolved(elig["unresolved_conditions"] + extra, raw["body_text"].splitlines())
        if elig["unresolved_conditions"]:
            elig["extraction_complete"] = False  # 모델도 완전성을 올리지 않고 내리기만 한다
            elig["explicitly_unrestricted"], elig["unrestricted_evidence"] = False, None


def load_if_present(model_dir: Path | None) -> ExtractModelAnalyzer | None:
    """배치용: 가중치 폴더가 있으면 불러오고, 없거나 None이면 None (예전처럼 규칙 + Gemma 추출)."""
    if model_dir is None or not (model_dir / "meta.json").exists():
        return None
    try:
        return ExtractModelAnalyzer.load(model_dir)
    except ImportError as e:  # torch·transformers 미설치 (uv run --group extract 로 실행하지 않음)
        print(f"자체 모델을 쓰지 않음: {e.name} 없음. uv run --group extract 로 실행", file=sys.stderr)
        return None


def model_version(meta: dict) -> str:
    """분석 버전에 붙는 모델 이름. 다시 학습하면 meta.json의 model_version을 올린다 (재분석을 일으킴)."""
    return meta.get("model_version", "extract-v1")


class KoElectraPredictor:
    """KoELECTRA 줄 분류기 추론 (CPU). 학습 코드(data/local/extract_distill/bundle/train.py)와 같은 창 나누기를 쓴다.

    긴 공고는 [CLS] 줄 [SEP] 줄 [SEP] ... 로 max_len 토큰까지 채운 창 여러 개로 나누고, 창 사이에 overlap줄을 겹친다.
    줄 표현은 그 줄 토큰들의 평균이고, 겹친 줄은 창별 확률을 평균한다.
    """

    def __init__(self, model_dir: Path, meta: dict):
        import torch  # 무거운 의존성은 모델을 쓸 때만 불러온다
        from safetensors.torch import load_file
        from transformers import AutoConfig, AutoModel, AutoTokenizer

        self.torch = torch
        self.max_len, self.max_line_tokens, self.overlap = meta["max_len"], meta["max_line_tokens"], meta["overlap"]
        self.tok = AutoTokenizer.from_pretrained(model_dir, local_files_only=True)
        encoder = AutoModel.from_config(AutoConfig.from_pretrained(model_dir, local_files_only=True))
        self.model = _line_tagger(torch, encoder, len(meta["labels"]))
        state = {k: v.float() for k, v in load_file(str(model_dir / "model.safetensors")).items()}
        self.model.load_state_dict(state)
        self.model.eval()
        self.n_labels = len(meta["labels"])

    def _windows(self, lines: list[str]) -> list[tuple[list[int], list[int], list[int]]]:
        tok = self.tok
        ids = [tok(l, add_special_tokens=False)["input_ids"][: self.max_line_tokens] or [tok.unk_token_id] for l in lines]
        windows, start = [], 0
        while start < len(ids):
            inp, lid, members, end = [tok.cls_token_id], [-1], [], start
            while end < len(ids) and len(inp) + len(ids[end]) + 1 <= self.max_len:
                k = len(members)
                inp += ids[end] + [tok.sep_token_id]
                lid += [k] * len(ids[end]) + [-1]
                members.append(end)
                end += 1
            windows.append((inp, lid, members))
            if end >= len(ids):
                break
            start = max(end - self.overlap, start + 1)
        return windows

    def __call__(self, lines: list[str]) -> list[list[float]]:
        torch = self.torch
        sums = [[0.0] * self.n_labels for _ in lines]
        counts = [0] * len(lines)
        with torch.no_grad():
            for inp, lid, members in self._windows(lines):
                ids = torch.tensor([inp])
                att = torch.ones_like(ids)
                out = self.model(ids, att, torch.tensor([lid]), len(members))
                probs = torch.sigmoid(out[0].float())[0]
                for k, li in enumerate(members):
                    for j in range(self.n_labels):
                        sums[li][j] += probs[k, j].item()
                    counts[li] += 1
        return [[v / max(c, 1) for v in row] for row, c in zip(sums, counts)]


def _line_tagger(torch, encoder, n_labels: int):
    """학습 때의 LineTagger와 같은 구조 (가중치 이름이 맞아야 불러온다)."""
    nn = torch.nn

    class LineTagger(nn.Module):
        def __init__(self):
            super().__init__()
            self.encoder = encoder
            h = encoder.config.hidden_size
            self.drop = nn.Dropout(0.1)
            self.line_head = nn.Linear(h, n_labels)
            self.doc_head = nn.Linear(h, 1)

        def forward(self, ids, att, lid, k):
            hid = self.encoder(input_ids=ids, attention_mask=att).last_hidden_state
            slots = torch.arange(k, device=ids.device).view(1, k, 1)
            m = (lid.unsqueeze(1) == slots).to(hid.dtype)
            pooled = (m @ hid) / m.sum(-1, keepdim=True).clamp(min=1)
            return self.line_head(self.drop(pooled)), self.doc_head(self.drop(hid[:, 0])).squeeze(-1)

    return LineTagger()
