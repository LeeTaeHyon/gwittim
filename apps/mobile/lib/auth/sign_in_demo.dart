import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/theme.dart';

/// 로그인 화면의 기능 소개 장면. 세 장면이 7초씩 돌아간다.
/// 1 소식 말풍선(D-010 예시) → 2 지원 전 체크리스트 → 3 관심 분야를 고르면 바뀌는 추천 순서.
/// 말풍선은 꼬리 쪽에서 톡 튀어나오고, 체크리스트·추천 카드는 아래에서 올라온다.
/// 장면은 크기·투명도만 바꾸고 자리는 가장 큰 장면만큼 늘 차지해서 아래 버튼이 움직이지 않는다.
/// 장면을 누르면 다음 장면으로 넘어간다. 애니메이션 줄이기 설정이면 움직이지 않고, 누를 때만 넘어간다.
/// 문구는 앱에 실제로 있는 기능만 쓰고 알림은 약속하지 않는다(푸시 알림은 P0 제외).
class SignInDemo extends StatefulWidget {
  const SignInDemo({super.key});

  @override
  State<SignInDemo> createState() => _SignInDemoState();
}

/// 장면 하나의 길이와 장면 수(ms)
const _scene = 7000;
const _scenes = 3;

/// 장면이 흐려지기 시작하는 때
const _fadeOut = 6200;

/// 살짝 넘쳤다 돌아오는 등장 곡선 (시작 인트로의 말풍선과 같은 느낌)
const _pop = Cubic(0.34, 1.4, 0.64, 1);

/// start부터 length 동안 0→1
double _span(double ms, double start, double length) => ((ms - start) / length).clamp(0.0, 1.0);

class _SignInDemoState extends State<SignInDemo> with SingleTickerProviderStateMixin {
  late final _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _scene * _scenes),
  );

  /// 애니메이션 줄이기 설정에서 보이는 장면
  int _stillScene = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) {
      _loop.stop();
    } else if (!_loop.isAnimating) {
      _loop.repeat();
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  int get _current => (_loop.value * _scenes).floor().clamp(0, _scenes - 1);

  void _next(bool still) {
    if (still) {
      setState(() => _stillScene = (_stillScene + 1) % _scenes);
      return;
    }
    _loop.value = ((_current + 1) % _scenes) / _scenes;
    _loop.repeat();
  }

  Widget _sceneAt(int k, double ms) => switch (k) {
    0 => _BubbleScene(ms: ms),
    1 => _ChecklistScene(ms: ms),
    _ => _RankingScene(ms: ms),
  };

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) == true;
    return AnimatedBuilder(
      animation: _loop,
      builder: (context, _) {
        final scene = still ? _stillScene : _current;
        final ms = still ? _fadeOut.toDouble() : _loop.value * _scene * _scenes - scene * _scene;
        final out = still ? 0.0 : Curves.easeInCubic.transform(_span(ms, _fadeOut.toDouble(), 500));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              onTapHint: '다음 소개 보기',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _next(still),
                child: Stack(
                  children: [
                    // 다른 장면은 자리만 차지한다 (가장 큰 장면에 맞춤)
                    for (var k = 0; k < _scenes; k++)
                      if (k != scene)
                        Visibility(
                          visible: false,
                          maintainSize: true,
                          maintainAnimation: true,
                          maintainState: true,
                          child: _sceneAt(k, _fadeOut.toDouble()),
                        ),
                    Opacity(
                      key: ValueKey('scene-$scene'),
                      opacity: 1 - out,
                      alwaysIncludeSemantics: true,
                      child: Transform.translate(offset: Offset(0, -10 * out), child: _sceneAt(scene, ms)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

const _bubbleRadius = BorderRadius.only(
  topLeft: Radius.circular(20),
  topRight: Radius.circular(20),
  bottomRight: Radius.circular(20),
  bottomLeft: Radius.circular(6),
);

/// 말풍선이 꼬리 쪽에서 톡 튀어나온다.
Widget _popIn(double p, Widget child) => Opacity(
  opacity: Curves.easeOut.transform((p * 2).clamp(0.0, 1.0)),
  alwaysIncludeSemantics: true,
  child: Transform.scale(scale: 0.6 + 0.4 * _pop.transform(p), alignment: Alignment.bottomLeft, child: child),
);

/// 카드가 아래에서 올라오며 나타난다.
Widget _riseIn(double p, Widget child) => Opacity(
  opacity: Curves.easeOut.transform(p),
  alwaysIncludeSemantics: true,
  child: Transform.translate(offset: Offset(0, 24 * (1 - Curves.easeOutCubic.transform(p))), child: child),
);

TextStyle _kicker(Color color) => TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color);

/// 장면 1: 앱이 알려 주는 소식의 예시. 말풍선마다 '…' 입력 중 표시가 잠깐 보인 뒤 0.9초 간격으로 도착한다.
class _BubbleScene extends StatelessWidget {
  const _BubbleScene({required this.ms});

  final double ms;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final bubbles = [
      _ExampleBubble(kicker: '마감 임박', kickerColor: c.urgent, text: '장학생 선발 공고 · D-6'),
      _ExampleBubble(kicker: '맞춤 공고', kickerColor: c.accent, text: '관심 분야와 관련된 공고 ', marked: '3개'),
      _ExampleBubble(kicker: '저장한 공고', kickerColor: c.accent, text: '발표회 마감 3일 연장'),
    ];
    const indents = [0.0, 32.0, 12.0];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < bubbles.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          Padding(
            padding: EdgeInsets.only(left: indents[i]),
            child: _slot(bubbles[i], ms - (300 + 900 * i)),
          ),
        ],
      ],
    );
  }

  /// t: 이 말풍선의 입력 중 표시가 시작된 뒤 지난 ms
  Widget _slot(Widget bubble, double t) {
    final typing = t < 0 || t >= 600 ? 0.0 : (t / 150).clamp(0.0, 1.0) * ((600 - t) / 150).clamp(0.0, 1.0);
    return Stack(
      alignment: Alignment.bottomLeft,
      children: [
        _popIn(_span(t, 600, 450), bubble),
        if (typing > 0)
          Opacity(
            opacity: typing,
            child: _TypingBubble(t: t),
          ),
      ],
    );
  }
}

/// 말풍선이 오기 전의 '…' 입력 중 표시. 점 세 개가 차례로 밝아진다.
class _TypingBubble extends StatelessWidget {
  const _TypingBubble({required this.t});

  final double t;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return ExcludeSemantics(
      child: Container(
        key: const ValueKey('typing'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: c.loginCard, borderRadius: _bubbleRadius),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.muted.withValues(
                    alpha: 0.35 + 0.65 * (1 - (((t / 400 - i * 0.2) % 1) - 0.3).abs() / 0.7).clamp(0.0, 1.0),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ExampleBubble extends StatelessWidget {
  const _ExampleBubble({required this.kicker, required this.kickerColor, required this.text, this.marked});

  final String kicker;
  final Color kickerColor;
  final String text;

  /// 라임 바탕으로 강조할 끝 낱말
  final String? marked;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(color: c.loginCard, borderRadius: _bubbleRadius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(kicker, style: _kicker(kickerColor)),
            const SizedBox(height: 3),
            // 화면 높이 계산(IntrinsicHeight) 안에 있어서 형광펜 위젯 대신 글자 바탕색을 쓴다.
            Text.rich(
              TextSpan(
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.ink),
                children: [
                  TextSpan(text: text),
                  if (marked != null)
                    TextSpan(
                      text: ' $marked ',
                      style: TextStyle(backgroundColor: c.lime, color: c.limeInk),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 장면 카드 (말풍선 모양)
class _SceneCard extends StatelessWidget {
  const _SceneCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
    decoration: BoxDecoration(color: context.gw.loginCard, borderRadius: _bubbleRadius),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
  );
}

/// 작은 이름표 ('학과' 등)
Widget _tag(GwColors c, String text) => Container(
  height: 20,
  padding: const EdgeInsets.symmetric(horizontal: 7),
  decoration: BoxDecoration(color: c.neutral, borderRadius: BorderRadius.circular(10)),
  child: Center(
    widthFactor: 1,
    child: Text(
      text,
      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c.sub),
    ),
  ),
);

/// 장면 2: 공고 리포트의 지원 전 체크리스트. 카드가 아래에서 올라온 뒤 빈 칸에 차례로 체크가 찍히고,
/// 성적 조건은 받지 않으므로 '직접 확인'으로 남는다 (D-009).
class _ChecklistScene extends StatelessWidget {
  const _ChecklistScene({required this.ms});

  final double ms;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    const rows = [('학과', '컴퓨터공학과', true), ('학년', '2학년', true), ('평점', '공지에서 직접 확인', false)];
    return _riseIn(
      _span(ms, 200, 500),
      _SceneCard(
        children: [
          Text('지원 전 체크리스트', style: _kicker(c.accent)),
          const SizedBox(height: 3),
          Text(
            '컴퓨터공학과 프로젝트 발표회',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.ink),
          ),
          const SizedBox(height: 8),
          for (final (i, (field, label, met)) in rows.indexed)
            _checkRow(c, i, field, label, met, _span(ms, 1100.0 + 600 * i, 350)),
          const SizedBox(height: 6),
          Opacity(
            opacity: _span(ms, 2900, 400),
            alwaysIncludeSemantics: true,
            child: Text('2개 충족 · 1개 직접 확인', style: TextStyle(fontSize: 12.5, color: c.muted)),
          ),
        ],
      ),
    );
  }

  /// t: 이 줄에 체크가 찍히는 진행도. 0이면 빈 칸이다.
  Widget _checkRow(GwColors c, int i, String field, String label, bool met, double t) {
    final on = t > 0;
    final mark = Transform.scale(
      scale: 0.4 + 0.6 * _pop.transform(t),
      child: met
          ? Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(color: c.point, borderRadius: BorderRadius.circular(6)),
              child: Icon(Icons.check_rounded, size: 15, color: c.pointTick),
            )
          : Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: c.checkBox,
                border: Border.all(color: c.checkLine, width: 2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(Icons.question_mark_rounded, size: 13, color: c.check),
            ),
    );
    final empty = Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        border: Border.all(color: c.line, width: 2),
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            key: ValueKey('box-$i-${on ? 'on' : 'off'}'),
            width: 22,
            height: 22,
            child: Stack(
              children: [
                empty,
                if (on) Opacity(opacity: Curves.easeOut.transform(t), child: mark),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _tag(c, field),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: met ? c.body : Color.lerp(c.body, c.check, t),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 장면 3: 관심 분야 칩을 누르면 관련 공고가 추천 순서 맨 위로 올라온다 (관심 분야는 추천 순서를 정하는 이유 중 하나).
class _RankingScene extends StatelessWidget {
  const _RankingScene({required this.ms});

  final double ms;

  static const _rowHeight = 28.0;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    // 칩을 누르는 동안 살짝 줄었다가 고른 모양으로 바뀐다.
    final press = math.sin(math.pi * _span(ms, 900, 300));
    final picked = ms >= 1100;
    final move = Curves.easeInOutCubic.transform(_span(ms, 1600, 600));
    // (제목, 처음 순서, 바뀐 순서, 관심 분야 관련)
    const rows = [('교내 디자인 공모전', 0, 1, false), ('창업 아이디어 경진대회', 1, 2, false), ('AI 해커톤 참가자 모집', 2, 0, true)];
    return _riseIn(
      _span(ms, 200, 500),
      _SceneCard(
        children: [
          Text('맞춤 추천', style: _kicker(c.accent)),
          const SizedBox(height: 3),
          Text(
            '관심 분야에 맞춘 공고 추천',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.ink),
          ),
          const SizedBox(height: 10),
          Row(
            spacing: 6,
            children: [_chip(c, '디자인', false, 0.0), _chip(c, 'AI·데이터', picked, press), _chip(c, '창업', false, 0)],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: _rowHeight * rows.length,
            child: Stack(
              children: [
                for (final (title, before, after, related) in rows)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: _rowHeight * (before + (after - before) * move),
                    height: _rowHeight,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 18,
                          child: Text(
                            '${(move < 0.5 ? before : after) + 1}',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.muted),
                          ),
                        ),
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.body),
                          ),
                        ),
                        if (related) ...[
                          const SizedBox(width: 8),
                          Opacity(
                            opacity: _span(ms, 2200, 300),
                            alwaysIncludeSemantics: true,
                            child: Text(
                              ' 관심 분야 ',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: c.limeInk,
                                backgroundColor: c.lime,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(GwColors c, String label, bool on, double press) => Transform.scale(
    scale: 1 - 0.08 * press,
    child: Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: on ? c.cta : c.neutral, borderRadius: BorderRadius.circular(14)),
      child: Center(
        widthFactor: 1,
        child: Text(
          label,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: on ? c.onCta : c.sub),
        ),
      ),
    ),
  );
}
