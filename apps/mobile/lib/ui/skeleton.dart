import 'package:flutter/material.dart';

import 'logo.dart';
import 'theme.dart';

/// 불러오는 동안 화면 모양을 닮은 회색 면(스켈레톤). 1.2초 주기로 밝기만 은은하게 바뀌고,
/// 애니메이션 줄이기 설정이면 멈춰 있다. 화면 읽기에는 '불러오는 중'으로 읽힌다.
class GwSkeleton extends StatefulWidget {
  const GwSkeleton({super.key, required this.child});

  final Widget child;

  @override
  State<GwSkeleton> createState() => _GwSkeletonState();
}

class _GwSkeletonState extends State<GwSkeleton> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) {
      _pulse.stop();
      _pulse.value = 0;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '불러오는 중',
      liveRegion: true,
      child: ExcludeSemantics(
        child: FadeTransition(
          opacity: _pulse.drive(Tween(begin: 1.0, end: 0.55).chain(CurveTween(curve: Curves.easeInOut))),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 스켈레톤 안의 회색 면 하나 (neutral)
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.width, required this.height, this.radius = 6});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(color: context.gw.neutral, borderRadius: BorderRadius.circular(radius)),
  );
}

/// 화면 바탕 위의 카드 자리. 라이트의 neutral은 바탕색과 같아서, 카드 면 위에 회색 면을 올린다.
class _CardShape extends StatelessWidget {
  const _CardShape({required this.children, this.bubble = false});

  final List<Widget> children;
  final bool bubble;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(color: context.gw.card, borderRadius: bubble ? Gw.bubble : BorderRadius.circular(20)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
  );
}

Widget _headerShape() => const SizedBox(
  height: 64,
  child: Padding(
    padding: EdgeInsets.symmetric(horizontal: 24),
    child: Align(alignment: Alignment.centerLeft, child: SkeletonBox(width: 120, height: 22)),
  ),
);

Widget _noticeShape() => const _CardShape(
  children: [
    SkeletonBox(width: 56, height: 13),
    SizedBox(height: 10),
    SkeletonBox(height: 18),
    SizedBox(height: 6),
    FractionallySizedBox(widthFactor: 0.6, child: SkeletonBox(height: 18)),
    SizedBox(height: 10),
    SkeletonBox(width: 140, height: 14),
  ],
);

/// 공고 목록(공고 탭)
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key, this.header = false});

  final bool header;

  @override
  Widget build(BuildContext context) => GwSkeleton(
    child: ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        if (header) Transform.translate(offset: const Offset(-16, 0), child: _headerShape()),
        for (var i = 0; i < 4; i++) ...[_noticeShape(), const SizedBox(height: 10)],
      ],
    ),
  );
}

/// 홈: 머리 → 오늘의 귀띔 → 다가오는 마감 → 나에게 맞는 공고
class HomeSkeleton extends StatelessWidget {
  const HomeSkeleton({super.key});

  @override
  Widget build(BuildContext context) => GwSkeleton(
    child: ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const Row(
          children: [
            SkeletonBox(width: 45, height: 28, radius: 10),
            SizedBox(width: 8),
            SkeletonBox(width: 80, height: 14),
          ],
        ),
        const SizedBox(height: 16),
        const _CardShape(
          bubble: true,
          children: [
            SkeletonBox(width: 70, height: 14),
            SizedBox(height: 10),
            SkeletonBox(width: 190, height: 24),
            SizedBox(height: 18),
            Row(
              children: [
                Expanded(child: SkeletonBox(height: 48, radius: 14)),
                SizedBox(width: 8),
                Expanded(child: SkeletonBox(height: 48, radius: 14)),
                SizedBox(width: 8),
                Expanded(child: SkeletonBox(height: 48, radius: 14)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 28),
        const SkeletonBox(width: 110, height: 20),
        const SizedBox(height: 12),
        _CardShape(
          children: [
            for (var i = 0; i < 3; i++)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SkeletonBox(width: 44, height: 44, radius: 22),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [SkeletonBox(height: 15), SizedBox(height: 6), SkeletonBox(width: 120, height: 12)],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 28),
        const SkeletonBox(width: 130, height: 20),
        const SizedBox(height: 12),
        _noticeShape(),
      ],
    ),
  );
}

/// 저장함: 머리 → 아래쪽 큰 판 안의 줄
class SavedSkeleton extends StatelessWidget {
  const SavedSkeleton({super.key});

  @override
  Widget build(BuildContext context) => GwSkeleton(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _headerShape(),
        Expanded(
          child: Container(
            margin: const EdgeInsets.only(top: 16),
            padding: const EdgeInsets.fromLTRB(20, 26, 20, 0),
            decoration: BoxDecoration(
              color: context.gw.card,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SkeletonBox(width: 70, height: 13),
                for (var i = 0; i < 4; i++)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBox(width: 34, height: 34, radius: 10),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SkeletonBox(height: 16),
                              SizedBox(height: 8),
                              SkeletonBox(width: 130, height: 12),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// 공고 리포트 (카드 바탕 위): 칩 → 제목 → 요약 말풍선 → 체크리스트
class ReportSkeleton extends StatelessWidget {
  const ReportSkeleton({super.key});

  @override
  Widget build(BuildContext context) => GwSkeleton(
    child: SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SkeletonBox(width: 64, height: 26, radius: 13),
          const SizedBox(height: 14),
          const SkeletonBox(height: 26),
          const SizedBox(height: 8),
          const FractionallySizedBox(widthFactor: 0.7, child: SkeletonBox(height: 26)),
          const SizedBox(height: 12),
          const SkeletonBox(width: 150, height: 14),
          const SizedBox(height: 22),
          const SkeletonBox(height: 120, radius: 22),
          const SizedBox(height: 36),
          const SkeletonBox(width: 150, height: 20),
          const SizedBox(height: 14),
          for (var i = 0; i < 3; i++)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  SkeletonBox(width: 24, height: 24, radius: 7),
                  SizedBox(width: 12),
                  Expanded(child: SkeletonBox(height: 16)),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

/// 내 정보: 머리 → 요약 카드 → 설정
class ProfileSkeleton extends StatelessWidget {
  const ProfileSkeleton({super.key});

  @override
  Widget build(BuildContext context) => GwSkeleton(
    child: ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Transform.translate(offset: const Offset(-16, 0), child: _headerShape()),
        const _CardShape(
          children: [
            SkeletonBox(width: 200, height: 20),
            SizedBox(height: 10),
            SkeletonBox(width: 120, height: 14),
            SizedBox(height: 16),
            Row(
              children: [
                SkeletonBox(width: 80, height: 26, radius: 13),
                SizedBox(width: 6),
                SkeletonBox(width: 64, height: 26, radius: 13),
              ],
            ),
          ],
        ),
        const SizedBox(height: 28),
        const _CardShape(children: [SkeletonBox(width: 60, height: 18), SizedBox(height: 14), SkeletonBox(height: 44)]),
      ],
    ),
  );
}

/// 앱 시작·로그인 대기: 로고 크기 그대로, 말풍선 안에서 점 세 개가 차례로 깜빡인다.
class GwLoadingLogo extends StatefulWidget {
  const GwLoadingLogo({super.key, this.height = 56});

  final double height;

  @override
  State<GwLoadingLogo> createState() => _GwLoadingLogoState();
}

class _GwLoadingLogoState extends State<GwLoadingLogo> with SingleTickerProviderStateMixin {
  late final _dots = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) {
      _dots.stop();
    } else if (!_dots.isAnimating) {
      _dots.repeat();
    }
  }

  @override
  void dispose() {
    _dots.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final still = MediaQuery.maybeDisableAnimationsOf(context) == true;
    return Semantics(
      label: '불러오는 중',
      liveRegion: true,
      child: GwBubbleMark(height: widget.height, color: c.lime, dotColor: c.limeInk, dots: still ? null : _dots),
    );
  }
}
