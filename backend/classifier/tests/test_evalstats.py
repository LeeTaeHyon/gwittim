"""tools/evalstats.py 통계 함수를 합성 값으로 확인한다 (docs/stage2-work-spec.md W1)."""
import pytest

from tools.evalstats import bootstrap_ci, cohen_kappa, mcnemar_exact, paired_sample_size, wilson


def test_wilson():
    assert wilson(30, 47) == pytest.approx((0.495, 0.760), abs=1e-3)
    lo, hi = wilson(0, 10)
    assert lo == 0 and 0 < hi < 1
    lo, hi = wilson(10, 10)  # 전부 맞음
    assert hi == pytest.approx(1) and 0 < lo < 1
    assert wilson(0, 0) == (0.0, 1.0)


def test_mcnemar_exact():
    assert mcnemar_exact(5, 3) == pytest.approx(0.727, abs=1e-3)
    assert mcnemar_exact(17, 6) == pytest.approx(0.035, abs=1e-3)
    assert mcnemar_exact(6, 17) == mcnemar_exact(17, 6)
    assert mcnemar_exact(0, 0) == 1
    assert mcnemar_exact(4, 4) == 1  # 양측 합이 1을 넘지 않는다
    assert mcnemar_exact(10, 0) == pytest.approx(2 / 2**10)


def test_cohen_kappa():
    labels = ["a", "b", "c", "a"]
    assert cohen_kappa(labels, labels) == 1
    assert cohen_kappa(["x"] * 4, ["x"] * 4) == 1  # 둘 다 한 값만 내고 모두 같음
    assert cohen_kappa(["x"] * 4, ["x", "y", "x", "y"]) == 0  # 한쪽이 한 값만 냄
    # 손계산 2×2: 둘 다 Y 4, A만 Y 1, B만 Y 1, 둘 다 N 4 → 관측 0.8, 우연 0.5·0.5+0.5·0.5 = 0.5 → κ 0.6
    a = ["Y"] * 4 + ["Y"] + ["N"] + ["N"] * 4
    b = ["Y"] * 4 + ["N"] + ["Y"] + ["N"] * 4
    assert cohen_kappa(a, b) == pytest.approx(0.6)
    with pytest.raises(ValueError):
        cohen_kappa(["a"], ["a", "b"])


def test_paired_sample_size():
    assert paired_sample_size(0.17, 0.10) == 132
    assert paired_sample_size(0.17, 0.15) == 57
    with pytest.raises(ValueError):
        paired_sample_size(0.01, 0.2)


def test_bootstrap_ci():
    ids = list(range(20))
    assert bootstrap_ci(ids, lambda s: 0.5, rounds=50) == (0.5, 0.5)
    mean = lambda s: sum(s) / len(s)
    lo, hi = bootstrap_ci(ids, mean, rounds=500)
    assert lo < mean(ids) < hi
    assert bootstrap_ci(ids, mean, rounds=500) == (lo, hi)  # 씨앗이 같으면 같은 구간
    assert bootstrap_ci([7], mean, rounds=10) == (7, 7)  # 한 건뿐
    with pytest.raises(ValueError):
        bootstrap_ci([], mean)


def test_stratified_folds():
    from collections import Counter

    from tools.evalstats import stratified_folds

    ids = [f"n{k:02d}" for k in range(40)]
    room = {i: "AB"[k % 2] for k, i in enumerate(ids)}
    cat = {i: "xyz"[k % 3] for k, i in enumerate(ids)}
    folds = stratified_folds(ids, lambda i: (room[i], cat[i]), k=5, seed=0)
    assert set(folds) == set(ids) and set(folds.values()) == set(range(5))
    assert max(Counter(folds.values()).values()) - min(Counter(folds.values()).values()) <= 1
    for s in {(room[i], cat[i]) for i in ids}:  # 층마다 겹에 고르게
        sizes = Counter(folds[i] for i in ids if (room[i], cat[i]) == s)
        assert max(sizes.values()) - min(sizes.values(), default=0) <= 1
    assert folds == stratified_folds(ids, lambda i: (room[i], cat[i]), k=5, seed=0)
    assert folds != stratified_folds(ids, lambda i: (room[i], cat[i]), k=5, seed=1)

    # 같은 묶음은 같은 겹
    grouped = stratified_folds(ids, lambda i: room[i], k=5, seed=3, group=lambda i: i[:2] if i < "n10" else i)
    assert len({grouped[i] for i in ids if i < "n10"}) == 1
    with pytest.raises(ValueError):
        stratified_folds(ids, lambda i: 0, k=1)
