"""새 알림톡 확인 표(localModel/make_check_sheet.py)를 합성 공지로 검증한다. 모델·Gemma는 가짜로 바꾼다."""
import csv
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "localModel"))

import make_check_sheet as mcs  # noqa: E402

ROOMS = ["명지전문대학 합성A", "명지전문대학 합성B"]


def notice(k):
    if k % 2:  # 규칙이 global_language를 붙이는 공지
        return f"[합성] 영어 회화 프로그램 {k}", f"[합성] 겨울방학 영어 회화 프로그램 {k} 참가자 모집"
    return f"[합성] 강의평가 안내 {k}", f"[합성] 2학기 강의평가 기간 안내 {k}"


def setup(tmp_path, n=40):
    rows, gemma = [], []
    for k in range(n):
        title, text = notice(k)
        i = f"n{k:03d}"
        rows.append({"id": i, "room": ROOMS[k % 2], "sent_at": "2026-11-10T09:00:00+09:00", "title": title, "text": text})
        tags = ["global_language"] if k % 2 else []
        gemma.append({"id": i, "interest_ids": tags, "category": "global" if k % 2 else "academic", "for_all_students": False})
    for name, data in (("new_arrivals.jsonl", rows), ("labels_gemma_new.jsonl", gemma)):
        (tmp_path / name).write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in data), encoding="utf-8")


def fake_classify(title, text):
    tags = ["global_language"] if "영어" in title else []
    unsure = ["경계"] if title.endswith(" 3") else []  # n003만 애매
    return SimpleNamespace(interest_ids=tags, category="global" if tags else "academic", unsure=unsure)


def sheet(tmp_path, name):
    with open(tmp_path / name, encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def write(tmp_path, name, columns, rows):
    with open(tmp_path / name, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=columns)
        w.writeheader()
        w.writerows(rows)


def test_check_sheet_flow(tmp_path, capsys):
    setup(tmp_path)
    r = mcs.build(str(tmp_path), classify=fake_classify)
    test, train = sheet(tmp_path, "check_test.csv"), sheet(tmp_path, "check_train.csv")
    assert r["test"] == 20 and len(train) == 20  # 40건의 30%=12 → 최소 20건
    assert {t["방"] for t in test} == {"합성A", "합성B"}
    # 시험용: 제안이 없고 정답 칸은 비어 있다
    assert "관심사_후보" not in test[0] and not any(t["정답_관심사"] or t["정답_카테고리"] for t in test)
    # 학습용: 셋이 같고 애매하지 않으면 관심사 자동, 카테고리는 항상 빈칸
    auto = [t for t in train if t["자동"] == "관심사"]
    assert all(t["정답_관심사"] for t in auto) and not any(t["정답_카테고리"] for t in train)
    assert all("Gemma" in t["카테고리_후보"] for t in train)
    n003 = [t for t in train if t["id"] == "n003"]
    if n003:  # 애매한 공지는 자동으로 채우지 않는다
        assert n003[0]["자동"] == "" and n003[0]["정답_관심사"] == ""

    # 빈칸이 남으면 합치지 않는다
    with pytest.raises(SystemExit):
        mcs.merge(str(tmp_path))

    for t in test:
        g = "global_language" if "영어" in t["제목"] else "없음"
        t.update(정답_관심사=g, 정답_카테고리="global" if g != "없음" else "academic", 정답_전체대상="N" if g != "없음" else "Y")
    for t in train:
        t["정답_관심사"] = t["정답_관심사"] or "없음"
        t["정답_카테고리"] = "global" if "영어" in t["제목"] else "other"  # 전체대상은 비워서 카테고리로 정함
    write(tmp_path, "check_test.csv", mcs.TEST_COLUMNS, test)
    write(tmp_path, "check_train.csv", mcs.TRAIN_COLUMNS, train)
    mcs.merge(str(tmp_path))
    labels = [json.loads(l) for l in (tmp_path / "labels_new.jsonl").read_text(encoding="utf-8").splitlines()]
    assert len(labels) == 40 and sum(l["split"] == "test" for l in labels) == 20
    tr = {l["id"]: l for l in labels if l["split"] == "train"}
    assert all(l["for_all_students"] == (l["category"] == "other") for l in tr.values())
    assert all(l["source"]["전체대상"] == "카테고리 규칙" for l in tr.values())

    # 공지가 늘어 다시 만들어도 채운 칸은 남고, 학습용이던 공지는 시험용으로 옮기지 않는다
    setup(tmp_path, n=70)
    mcs.build(str(tmp_path), classify=fake_classify)
    test2, train2 = sheet(tmp_path, "check_test.csv"), sheet(tmp_path, "check_train.csv")
    assert len(test2) == 21  # 70건의 30%
    assert {t["id"] for t in test} <= {t["id"] for t in test2}
    assert not {t["id"] for t in train} & {t["id"] for t in test2}
    kept = {t["id"]: t for t in train2}
    assert all(kept[t["id"]]["정답_카테고리"] == t["정답_카테고리"] for t in train)


def test_small_batch_and_for_all_rule(tmp_path):
    # 공지가 적으면 전부 시험용이고 학습용 표는 비어도 합칠 수 있다
    setup(tmp_path, n=4)
    assert mcs.build(str(tmp_path), classify=fake_classify) == {"test": 4, "train": 0, "auto_interest": 0}
    test = sheet(tmp_path, "check_test.csv")
    for t in test:
        t.update(정답_관심사="없음", 정답_카테고리="academic", 정답_전체대상="Y")
    write(tmp_path, "check_test.csv", mcs.TEST_COLUMNS, test)
    mcs.merge(str(tmp_path))

    # 학습용에서 카테고리가 extracurricular·event·academic인데 전체대상이 비면 오류
    setup(tmp_path, n=40)
    mcs.build(str(tmp_path), classify=fake_classify)
    train = sheet(tmp_path, "check_train.csv")
    for t in train:
        t.update(정답_관심사=t["정답_관심사"] or "없음", 정답_카테고리="extracurricular")
    write(tmp_path, "check_train.csv", mcs.TRAIN_COLUMNS, train)
    with pytest.raises(SystemExit) as e:
        mcs.merge(str(tmp_path))
    assert "카테고리가 extracurricular이면 직접 적음" in str(e.value)
