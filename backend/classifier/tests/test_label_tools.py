"""라벨 표 만들기 → 채우기 → 일치도 → 합치기를 합성 공지 5건으로 끝까지 돌린다 (docs/stage2-work-spec.md W2)."""
import csv
import hashlib
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "localModel"))

import label_agreement  # noqa: E402
import make_label_sheet  # noqa: E402

NOTICES = [
    {"id": "s01", "room": "명지전문대학 합성방", "title": "[합성] AI 특강", "text": "[합성] AI 특강 안내 본문"},
    {"id": "s02", "room": "명지전문대학 합성방", "title": "[합성] 영어 캠프", "text": "[합성] 영어 캠프 모집"},
    {"id": "s03", "room": "명지전문대학 다른방", "title": "[합성] 강의평가", "text": "[합성] 강의평가 기간"},
    {"id": "s04", "room": "명지전문대학 다른방", "title": "[합성] 영상 공모전", "text": "[합성] 영상 공모전 안내"},
    {"id": "s05", "room": "명지전문대학 합성방", "title": "[합성] 장학금", "text": "[합성] 장학금 신청"},
]
# (관심사, 카테고리, 전체대상) — A와 B는 s02 관심사, s04 카테고리에서 갈린다
A = {"s01": ("ai_data", "education_program", "N"), "s02": ("global_language", "global", "N"),
     "s03": ("없음", "academic", "Y"), "s04": ("media_content", "contest", "N"), "s05": ("없음", "scholarship", "Y")}
B = {**A, "s02": ("global_language education_welfare", "global", "N"), "s04": ("media_content", "event", "N")}


def fill(path, answers):
    with open(path, encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["정답_관심사"], r["정답_카테고리"], r["정답_전체대상"] = answers[r["id"]]
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=make_label_sheet.COLUMNS)
        w.writeheader()
        w.writerows(rows)


def set_consensus(path, values):
    with open(path, encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["합의"] = values[(r["id"], r["항목"])]
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=label_agreement.DISAGREE_COLUMNS)
        w.writeheader()
        w.writerows(rows)


def test_sheet_to_merge(tmp_path, capsys):
    (tmp_path / "notices.jsonl").write_text("".join(json.dumps(n, ensure_ascii=False) + "\n" for n in NOTICES), encoding="utf-8")
    make_label_sheet.main(["--data-dir", str(tmp_path)])

    # 가림: 원문과 빈 정답 칸만 있고 규칙·Gemma 열은 없다
    sheets = {}
    for w in "AB":
        with open(tmp_path / f"label_sheet_{w}.csv", encoding="utf-8-sig") as f:
            reader = csv.DictReader(f)
            assert reader.fieldnames == make_label_sheet.COLUMNS
            sheets[w] = list(reader)
        assert not any(r["정답_관심사"] or r["정답_카테고리"] or r["정답_전체대상"] for r in sheets[w])
    assert {r["id"] for r in sheets["A"]} == {n["id"] for n in NOTICES}
    assert [r["id"] for r in sheets["A"]] != [r["id"] for r in sheets["B"]]  # 작업자마다 순서가 다름
    assert sheets["A"][0]["방"] in ("합성방", "다른방")
    guide = (tmp_path / "label_guide.txt").read_text(encoding="utf-8")
    assert "ai_data" in guide and "other" in guide

    # 이미 표가 있으면 덮어쓰지 않고 멈춘다
    with pytest.raises(SystemExit):
        make_label_sheet.main(["--data-dir", str(tmp_path)])

    # 빈 칸·사전 밖 코드는 행 번호와 함께 오류
    with pytest.raises(SystemExit) as e:
        label_agreement.main(["--data-dir", str(tmp_path)])
    assert "2행" in str(e.value) and "빈 칸" in str(e.value)
    fill(tmp_path / "label_sheet_A.csv", {**A, "s01": ("ai_dataa", "education_program", "N")})
    fill(tmp_path / "label_sheet_B.csv", B)
    with pytest.raises(SystemExit) as e:
        label_agreement.main(["--data-dir", str(tmp_path)])
    assert "ai_dataa" in str(e.value)

    fill(tmp_path / "label_sheet_A.csv", A)
    label_agreement.main(["--data-dir", str(tmp_path)])
    out = capsys.readouterr().out
    assert "종류 κ" in out and "갈린 칸 2개" in out
    with open(tmp_path / "label_disagreements.csv", encoding="utf-8-sig") as f:
        rows = {(r["id"], r["항목"]): r for r in csv.DictReader(f)}
    assert set(rows) == {("s02", "관심사"), ("s04", "카테고리")}
    assert rows[("s02", "관심사")]["B"] == "education_welfare global_language"

    # 합의가 비어 있으면 합치지 않는다
    with pytest.raises(SystemExit):
        label_agreement.main(["--data-dir", str(tmp_path), "--merge"])
    assert not (tmp_path / "labels_human.jsonl").exists()

    set_consensus(tmp_path / "label_disagreements.csv", {("s02", "관심사"): "global_language", ("s04", "카테고리"): "contest"})
    label_agreement.main(["--data-dir", str(tmp_path), "--merge"])
    human_path = tmp_path / "labels_human.jsonl"
    sha = hashlib.sha256(human_path.read_bytes()).hexdigest()
    assert sha in capsys.readouterr().out
    human = {r["id"]: r for r in map(json.loads, human_path.read_text(encoding="utf-8").splitlines())}
    assert len(human) == 5
    assert human["s02"]["interest_ids"] == ["global_language"]
    assert human["s02"]["b"]["interest_ids"] == ["education_welfare", "global_language"]  # 합의 전 답을 남긴다
    assert human["s04"]["category"] == "contest" and human["s04"]["b"]["category"] == "event"
    assert human["s03"] == {"id": "s03", "interest_ids": [], "category": "academic", "for_all_students": True,
                            "a": {"interest_ids": [], "category": "academic", "for_all_students": True},
                            "b": {"interest_ids": [], "category": "academic", "for_all_students": True}}

    # 다시 돌려도 적어 둔 합의는 남는다
    label_agreement.main(["--data-dir", str(tmp_path)])
    with open(tmp_path / "label_disagreements.csv", encoding="utf-8-sig") as f:
        assert all(r["합의"] for r in csv.DictReader(f))
