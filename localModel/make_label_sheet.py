"""사람 정답 라벨 표 만들기: 두 작업자가 원문만 보고 따로 매긴다 (docs/stage2-work-spec.md W2).

review_set.csv는 규칙·Gemma의 답과 근거를 정답 칸 옆에 보여 줘서 정답이 Gemma 쪽으로 끌릴 수 있었다.
이 표에는 원문만 넣고 규칙·Gemma 답은 한 글자도 넣지 않는다. 행 순서도 작업자마다 다르게 섞는다(방 순서 아님).

입력 (--data-dir, 기본 kakaoTalk_data/processed, git 제외)
  notices.jsonl       알림톡 공지 287건
출력 (같은 폴더)
  label_sheet_A.csv   작업자 A (씨앗 1로 섞음)
  label_sheet_B.csv   작업자 B (씨앗 2로 섞음)
  label_guide.txt     허용 코드 목록과 적는 법
  표를 채운 뒤 label_agreement.py로 일치도를 보고 합친다.

이미 표가 있으면 채운 내용을 지우지 않도록 아무것도 쓰지 않고 멈춘다 (덮어쓰기 옵션 없음).

사용 (표준 라이브러리만)
  python make_label_sheet.py
"""
import argparse
import csv
import json
import os
import random
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(BASE, "kakaoTalk_data", "processed")
DICT_DIR = os.path.join(os.path.dirname(BASE), "contracts", "dictionaries")

COLUMNS = ["id", "방", "제목", "본문", "정답_관심사", "정답_카테고리", "정답_전체대상", "메모"]
SEEDS = {"A": 1, "B": 2}
NONE = "없음"  # 관심 분야와 상관없는 공지


def sheet_path(data_dir, worker):
    return os.path.join(data_dir, f"label_sheet_{worker}.csv")


def load_dict(name):
    with open(os.path.join(DICT_DIR, f"{name}.json"), encoding="utf-8") as f:
        return [(i["id"], i["name_ko"]) for i in json.load(f)["items"]]


def guide_text():
    lines = [
        "알림톡 사람 정답 라벨 안내",
        "",
        "원문(제목·본문)만 보고 매긴다. 다른 작업자의 표, labels_gemma.jsonl, review_set.csv는 보지 않는다.",
        "",
        "정답_관심사: 이 공지에 특히 관심을 가질 학생의 진로·관심 분야 코드. 여러 개면 공백으로 띄운다.",
        f"  분야와 상관없는 학교생활 안내면 '{NONE}' 하나만 적는다. 빈 칸은 오류로 본다.",
    ]
    lines += [f"  {i}  {n}" for i, n in load_dict("interests")]
    lines += ["", "정답_카테고리: 공지 종류 코드 하나."]
    lines += [f"  {i}  {n}" for i, n in load_dict("categories")]
    lines += [
        "",
        "정답_전체대상: 분야와 관계없이 모든 학생이 비슷하게 알아야 하는 공지면 Y, 특정 분야·대상 학생에게 더 맞으면 N.",
        "",
        "메모: 판단이 애매했던 이유 등 자유롭게. 비워도 된다.",
        "",
        "꼬리표 정의 보충 (κ가 0.6에 못 미친 항목을 다시 매기기 전에 여기에 적는다):",
        "",
    ]
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description="사람 정답 라벨 표(A·B) 만들기")
    ap.add_argument("--data-dir", default=DATA)
    args = ap.parse_args(argv)

    existing = [sheet_path(args.data_dir, w) for w in SEEDS if os.path.exists(sheet_path(args.data_dir, w))]
    if existing:
        sys.exit("이미 라벨 표가 있어 멈춤 (채운 내용을 덮어쓰지 않음): " + ", ".join(existing))

    with open(os.path.join(args.data_dir, "notices.jsonl"), encoding="utf-8") as f:
        notices = list({n["id"]: n for n in map(json.loads, f)}.values())
    rows = [{
        "id": n["id"],
        "방": n["room"].removeprefix("명지전문대학").strip(),
        "제목": n["title"],
        "본문": n["text"],
    } for n in notices]

    for worker, seed in SEEDS.items():
        shuffled = rows[:]
        random.Random(seed).shuffle(shuffled)
        with open(sheet_path(args.data_dir, worker), "w", encoding="utf-8-sig", newline="") as f:
            w = csv.DictWriter(f, fieldnames=COLUMNS, restval="")
            w.writeheader()
            w.writerows(shuffled)
    with open(os.path.join(args.data_dir, "label_guide.txt"), "w", encoding="utf-8") as f:
        f.write(guide_text())
    print(f"공지 {len(rows)}건 → label_sheet_A.csv, label_sheet_B.csv, label_guide.txt ({args.data_dir})")


if __name__ == "__main__":
    main()
