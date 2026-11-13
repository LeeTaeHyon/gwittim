"""분류 평가용 통계 함수. 표준 라이브러리만 쓴다 (docs/stage2-work-spec.md W1).

  wilson               비율 하나의 95% 구간 (정확도 30/47 → 0.50~0.76)
  mcnemar_exact        같은 시험 세트에서 두 방법의 정확도 차 검정 (한쪽만 맞힌 건수 b, c)
  bootstrap_ci         공지를 복원 추출해 지표(F1 등)의 95% 구간
  cohen_kappa          두 사람 라벨의 일치도 (우연히 같을 확률을 뺀 일치)
  paired_sample_size   두 방법의 정확도 차를 검출하는 데 필요한 시험 세트 크기
"""
from __future__ import annotations

import math
import random
from collections import Counter
from collections.abc import Callable, Hashable, Sequence
from statistics import NormalDist

Z95 = NormalDist().inv_cdf(0.975)  # 1.96


def wilson(k: int, n: int, z: float = Z95) -> tuple[float, float]:
    """n번 중 k번 맞힘의 Wilson 95% 구간. n이 0이면 아무것도 모르므로 (0, 1)."""
    if n == 0:
        return 0.0, 1.0
    p = k / n
    center = (p + z * z / (2 * n)) / (1 + z * z / n)
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    # 0건·전부 맞음에서 부동소수 오차로 끝이 0·1을 살짝 벗어나지 않게 정확히 고정
    lo = 0.0 if k == 0 else max(0.0, center - half)
    hi = 1.0 if k == n else min(1.0, center + half)
    return lo, hi


def mcnemar_exact(b: int, c: int) -> float:
    """양측 정확 McNemar p값. b: A만 맞힘, c: B만 맞힘. 둘이 같게 맞히거나 틀린 건은 차이에 정보가 없다.

    귀무가설(두 방법이 같음)에서 b는 이항분포 B(b+c, 0.5)를 따른다. 갈린 쌍이 없으면 p = 1.
    """
    n = b + c
    if n == 0:
        return 1.0
    tail = sum(math.comb(n, i) for i in range(min(b, c) + 1)) / 2**n
    return min(1.0, 2 * tail)


def _quantile(sorted_vals: Sequence[float], q: float) -> float:
    """선형 보간 분위수 (numpy.percentile 기본값과 같은 방식)."""
    pos = (len(sorted_vals) - 1) * q
    lo = math.floor(pos)
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (pos - lo)


def bootstrap_ci(
    ids: Sequence[Hashable], fn: Callable[[list], float], seed: int = 0, rounds: int = 5000
) -> tuple[float, float]:
    """ids를 같은 크기로 복원 추출해 fn(뽑은 id 목록)을 rounds번 계산하고 2.5%·97.5% 분위를 돌려준다.

    같은 공지가 여러 번 뽑힐 수 있으므로 fn은 id 목록의 중복을 그대로 세야 한다.
    """
    if not ids:
        raise ValueError("ids가 비어 있음")
    rng = random.Random(seed)
    ids = list(ids)
    vals = sorted(fn(rng.choices(ids, k=len(ids))) for _ in range(rounds))
    return _quantile(vals, 0.025), _quantile(vals, 0.975)


def cohen_kappa(a: Sequence[Hashable], b: Sequence[Hashable]) -> float:
    """두 라벨 목록의 Cohen κ = (관측 일치 − 우연 일치) / (1 − 우연 일치).

    우연 일치가 1이면(두 사람 모두 한 값만 냄) 완전 일치이므로 1로 둔다.
    """
    if len(a) != len(b):
        raise ValueError("두 라벨 목록의 길이가 다름")
    n = len(a)
    if n == 0:
        raise ValueError("라벨이 비어 있음")
    po = sum(x == y for x, y in zip(a, b)) / n
    ca, cb = Counter(a), Counter(b)
    pe = sum(ca[v] * cb[v] for v in ca) / (n * n)
    if pe == 1:
        return 1.0
    return (po - pe) / (1 - pe)


def paired_sample_size(psi: float, delta: float, alpha: float = 0.05, power: float = 0.8) -> int:
    """McNemar 검정으로 정확도 차 delta를 검출하는 데 필요한 쌍의 수 (Connor 1987).

    psi: 두 방법이 서로 다르게 맞히는 비율(b+c)/n, delta: 정확도 차. 양측 alpha, 검정력 power.
    """
    if not (0 < delta and delta * delta < psi <= 1):
        raise ValueError("0 < delta, delta² < psi ≤ 1 이어야 함")
    za = NormalDist().inv_cdf(1 - alpha / 2)
    zb = NormalDist().inv_cdf(power)
    n = (za * math.sqrt(psi) + zb * math.sqrt(psi - delta * delta)) ** 2 / (delta * delta)
    return math.ceil(n)
