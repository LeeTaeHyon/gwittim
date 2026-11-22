import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'agent_data.dart';
import 'common.dart';
import 'components.dart';
import 'credits_screen.dart';
import 'format.dart';
import 'skeleton.dart';
import 'theme.dart';

// 상세 분석 흐름 (docs/agent-privacy-spec.md §5, §11):
// 버튼 → (처음만) 동의 화면 → 질문 화면 → 기다리는 화면 → 리포트.
// 질문 화면까지는 크레딧이 줄지 않는다. 서버가 분석에 성공했을 때만 차감한다.

/// 기다리는 화면의 결과. 나갔으면 null이다(분석은 서버에서 계속된다).
class AgentWaitResult {
  const AgentWaitResult.done(AnalysisResponse this.response) : needConsent = false;
  const AgentWaitResult.needConsent() : response = null, needConsent = true;

  final AnalysisResponse? response;

  /// 서버가 동의 기록이 없다고 해서 동의 화면부터 다시 해야 함
  final bool needConsent;
}

/// 동의 → 질문 → 기다림까지 이어서 연다. 분석을 받으면 응답과 보낸 칩을, 중간에 나가면 null.
Future<({AnalysisResponse response, AnalysisChips chips})?> runAnalysisFlow(
  BuildContext context, {
  required NoticeRepository repository,
  required AgentChipStore store,
  required String noticeId,
  required String? title,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  var askConsent = false;
  while (true) {
    final UserProfile? profile;
    try {
      profile = await repository.getProfile();
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(keepAll(errorMessage(e)))));
      return null;
    }
    if (!context.mounted) return null;
    if (profile == null) {
      // 사용자 정보를 추정해 채우지 않는다. 내 정보를 입력한 뒤에 쓸 수 있다.
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(keepAll('내 정보를 먼저 입력해 주세요.'))));
      return null;
    }
    if (askConsent || !profile.hasAgentConsent) {
      final agreed = await navigator.push<bool>(gwRoute(context, (_) => AgentConsentScreen(repository: repository)));
      if (agreed != true || !context.mounted) return null;
    }
    final chips = await navigator.push<AnalysisChips>(
      gwRoute(context, (_) => AgentQuestionScreen(repository: repository, store: store)),
    );
    if (chips == null || !context.mounted) return null;
    final result = await navigator.push<AgentWaitResult>(
      gwRoute(
        context,
        (_) => AgentWaitScreen(
          repository: repository,
          noticeId: noticeId,
          title: title,
          chips: chips,
          requestId: newRequestId(),
        ),
      ),
    );
    if (result == null || !context.mounted) return null;
    if (result.needConsent) {
      askConsent = true;
      continue;
    }
    return (response: result.response!, chips: chips);
  }
}

/// 두 버튼은 같은 크기(폭 반반, 높이 56). 주 버튼은 cta, 둘째는 chip 면으로 색만 다르다.
class _PairButtons extends StatelessWidget {
  const _PairButtons({
    required this.primary,
    required this.secondary,
    required this.onPrimary,
    required this.onSecondary,
  });

  final String primary;
  final String secondary;
  final VoidCallback? onPrimary;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Row(
      children: [
        Expanded(
          child: FilledButton(onPressed: onPrimary, child: Text(primary)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton(
            onPressed: onSecondary,
            style: FilledButton.styleFrom(backgroundColor: c.chip, foregroundColor: c.onChip),
            child: Text(secondary),
          ),
        ),
      ],
    );
  }
}

bool _still(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) == true;

// ───────────────────────── 동의 화면 ─────────────────────────

/// 'AI에 보내는 정보' (명세 §5.1). 처음 한 번, 문구가 바뀌어 버전이 오르면 다시 보인다.
/// 동의하면 프로필에 동의 기록을 저장하고 true, 동의하지 않으면 false를 돌려준다.
class AgentConsentScreen extends StatefulWidget {
  const AgentConsentScreen({super.key, required this.repository});

  final NoticeRepository repository;

  @override
  State<AgentConsentScreen> createState() => _AgentConsentScreenState();
}

class _AgentConsentScreenState extends State<AgentConsentScreen> {
  late Future<List<(String, String)>> _future = _load();
  bool _saving = false;

  /// 보낼 내 정보의 실제 값. 입력하지 않은 항목은 보내지 않으므로 줄도 없다.
  Future<List<(String, String)>> _load() async {
    final r = widget.repository;
    final p = await r.getProfile();
    if (p == null) return const [];
    Future<String?> name(String dictionary, String? id) async =>
        id == null ? null : (await r.dictionary(dictionary)).where((i) => i.id == id).firstOrNull?.name;
    Future<String?> names(String dictionary, List<String> ids) async {
      final items = await r.dictionary(dictionary);
      final out = [for (final id in ids) ?items.where((i) => i.id == id).firstOrNull?.name];
      return out.isEmpty ? null : out.join(', ');
    }

    const status = {'enrolled': '재학', 'on_leave': '휴학', 'graduated': '졸업'};
    final standing = [
      // 졸업이면 학년은 보이지 않는다 (내 정보 화면과 같음)
      if (p.grade case final g? when p.enrollmentStatus != 'graduated') '$g학년',
      ?status[p.enrollmentStatus],
    ].join(' · ');
    return [
      if (await name('universities', p.universityId) case final v?) ('학교', v),
      if (await name('majors', p.majorId) case final v?) ('학과', v),
      if (standing.isNotEmpty) ('학년·상태', standing),
      if (await names('interests', p.interestIds) case final v?) ('관심 분야', v),
      if (await names('roles', p.targetRoleIds) case final v?) ('희망 직무', v),
    ];
  }

  Future<void> _agree() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.repository.grantAgentConsent();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(keepAll(errorMessage(e)))));
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Scaffold(
      appBar: GwTopBar(onClose: () => Navigator.of(context).pop(false)),
      body: FutureBuilder(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return const SizedBox.shrink();
          if (snapshot.hasError) {
            return MessageView.error(snapshot.error!, onRetry: () => setState(() => _future = _load()));
          }
          final rows = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Semantics(
                header: true,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 14),
                  child: Text(
                    'AI에 보내는 정보',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.6, color: c.ink),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(20)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('내 정보 미리 보기', style: TextStyle(fontSize: 13, color: c.muted)),
                    const SizedBox(height: 10),
                    if (rows.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Text('입력한 정보 없음', style: TextStyle(fontSize: 15, color: c.muted)),
                      ),
                    for (final (i, row) in rows.indexed)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          border: i == rows.length - 1 ? null : Border(bottom: BorderSide(color: c.line)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(row.$1, style: TextStyle(fontSize: 15, color: c.muted)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                row.$2,
                                textAlign: TextAlign.end,
                                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.ink),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 16, 2, 0),
                child: Text(
                  keepAll('이름·이메일·학번 등 직접 식별 정보는 보내지 않습니다.'),
                  style: TextStyle(fontSize: 15, height: 1.65, fontWeight: FontWeight.w700, color: c.ink),
                ),
              ),
              Container(
                margin: const EdgeInsets.only(top: 16),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(color: c.cardSoft, borderRadius: BorderRadius.circular(14)),
                child: Column(
                  children: [
                    const _InfoLine('받는 곳', 'DeepSeek(중국)'),
                    Divider(height: 1, color: c.line),
                    const _InfoLine('목적', '이 공고 맞춤 분석'),
                    Divider(height: 1, color: c.line),
                    const _InfoLine('보관', '보관 기간은 DeepSeek 기준을 따르며, 모델 학습에 쓰일 수 있습니다.'),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 16, 2, 0),
                child: Text(
                  keepAll('동의하지 않아도 기본 공고 분석은 그대로 무료입니다.'),
                  style: TextStyle(fontSize: 15, height: 1.65, color: c.body),
                ),
              ),
              const SizedBox(height: 22),
              _PairButtons(
                primary: '동의하고 계속',
                secondary: '동의하지 않음',
                onPrimary: _saving ? null : _agree,
                onSecondary: _saving ? null : () => Navigator.of(context).pop(false),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  keepAll('내 정보 > 설정에서 언제든 철회할 수 있습니다.'),
                  textAlign: TextAlign.center,
                  style: captionStyle(context),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(label, style: TextStyle(fontSize: 13, color: c.muted)),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(keepAll(value), style: TextStyle(fontSize: 15, height: 1.55, color: c.body)),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── 질문 화면 ─────────────────────────

class _Choices {
  const _Choices(this.experience, this.period, this.regions, this.saved);

  final List<DictionaryItem> experience;
  final List<DictionaryItem> period;
  final List<DictionaryItem> regions;
  final AnalysisChips? saved;
}

/// 질문 세 개 (명세 §2.2, §5.2). 모두 선택이고 건너뛸 수 있다. 나가도 크레딧은 줄지 않는다.
/// [분석하기]·[건너뛰고 분석]으로 닫으면 고른 칩(건너뛰면 빈 값)을 돌려준다.
class AgentQuestionScreen extends StatefulWidget {
  const AgentQuestionScreen({super.key, required this.repository, required this.store});

  final NoticeRepository repository;
  final AgentChipStore store;

  @override
  State<AgentQuestionScreen> createState() => _AgentQuestionScreenState();
}

/// 같은 질문의 다른 칩과 함께 고를 수 없는 칩 ('아직 없음', '상관없음')
const _noneYet = 'none_yet';
const _anyRegion = 'any';

class _AgentQuestionScreenState extends State<AgentQuestionScreen> {
  late Future<_Choices> _future = _load();
  final Set<String> _experience = {};
  String? _period;
  final Set<String> _regions = {};
  bool _remember = false;

  Future<_Choices> _load() async {
    final r = widget.repository;
    final experience = await r.dictionary('experience_chips');
    final period = await r.dictionary('period_chips');
    final regions = await r.dictionary('region_chips');
    AnalysisChips? saved;
    try {
      saved = await widget.store.read();
    } catch (_) {
      // 기기 저장소를 못 읽으면 저장하지 않은 것으로 본다.
    }
    if (saved != null && !_remember && _experience.isEmpty && _period == null && _regions.isEmpty) {
      // 사전에 없는 값은 버린다 (사전이 바뀐 뒤 남은 값)
      final e = {for (final i in experience) i.id};
      final p = {for (final i in period) i.id};
      final g = {for (final i in regions) i.id};
      _experience.addAll(saved.experience.where(e.contains));
      _period = saved.period != null && p.contains(saved.period) ? saved.period : null;
      _regions.addAll(saved.regions.where(g.contains));
      _remember = !saved.isEmpty;
    }
    return _Choices(experience, period, regions, saved);
  }

  /// 여러 개 고르기. [exclusive]는 단독 선택 칩: 고르면 나머지가 꺼지고, 다른 칩을 고르면 꺼진다.
  void _toggle(Set<String> set, String id, String exclusive) {
    setState(() {
      if (!set.remove(id)) {
        if (id == exclusive) {
          set.clear();
        } else {
          set.remove(exclusive);
        }
        set.add(id);
      }
    });
  }

  AnalysisChips get _chips =>
      AnalysisChips(experience: _experience.toList()..sort(), period: _period, regions: _regions.toList()..sort());

  Future<void> _analyze() async {
    final chips = _chips;
    try {
      await widget.store.write(_remember ? chips : null);
    } catch (_) {
      // 저장하지 못해도 이번 분석에는 쓴다.
    }
    if (mounted) Navigator.of(context).pop(chips);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Scaffold(
      appBar: const GwTopBar(),
      body: FutureBuilder(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return const SizedBox.shrink();
          if (snapshot.hasError) {
            return MessageView.error(snapshot.error!, onRetry: () => setState(() => _future = _load()));
          }
          final choices = snapshot.data!;
          return Stack(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 190),
                children: [
                  _Question(
                    title: '해 본 것',
                    hint: '여러 개 선택',
                    why: "해 본 것이 있으면 '맞는 점'에 반영합니다.",
                    items: choices.experience,
                    isSelected: _experience.contains,
                    onTap: (id) => _toggle(_experience, id, _noneYet),
                  ),
                  _Question(
                    title: '가능한 시기',
                    hint: '하나 선택',
                    why: '활동 기간이 맞는지 비교합니다.',
                    items: choices.period,
                    isSelected: (id) => _period == id,
                    onTap: (id) => setState(() => _period = _period == id ? null : id),
                  ),
                  _Question(
                    title: '갈 수 있는 지역',
                    hint: '여러 개 선택',
                    why: '활동 장소가 맞는지 비교합니다.',
                    items: choices.regions,
                    isSelected: _regions.contains,
                    onTap: (id) => _toggle(_regions, id, _anyRegion),
                  ),
                  const SizedBox(height: 24),
                  _RememberSwitch(value: _remember, onChanged: (v) => setState(() => _remember = v)),
                ],
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: const Alignment(0, -0.2),
                      colors: [c.bg.withValues(alpha: 0), c.bg],
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            keepAll('분석이 끝난 뒤에만 1크레딧이 차감됩니다.'),
                            textAlign: TextAlign.center,
                            style: captionStyle(context),
                          ),
                          const SizedBox(height: 10),
                          _PairButtons(
                            primary: '분석하기',
                            secondary: '건너뛰고 분석',
                            onPrimary: _analyze,
                            // 건너뛰면 칩을 보내지 않고, '다음에도 이대로' 저장값도 건드리지 않는다.
                            onSecondary: () => Navigator.of(context).pop(const AnalysisChips()),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Question extends StatelessWidget {
  const _Question({
    required this.title,
    required this.hint,
    required this.why,
    required this.items,
    required this.isSelected,
    required this.onTap,
  });

  final String title;
  final String hint;
  final String why;
  final List<DictionaryItem> items;
  final bool Function(String id) isSelected;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: c.ink),
                ),
                const SizedBox(width: 8),
                Text(hint, style: TextStyle(fontSize: 13, color: c.muted)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 10),
            child: Text(keepAll(why), style: captionStyle(context)),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in items)
                AnswerChip(label: item.name, selected: isSelected(item.id), onTap: () => onTap(item.id)),
            ],
          ),
        ],
      ),
    );
  }
}

/// 고르는 칩 (외부 공고 찾기 화면도 씀): 높이 44, 테두리 1.5, 고르면 cta 면 (체크 아이콘 없음 — 폭이 바뀌어 줄바꿈이 달라지지 않게)
class AnswerChip extends StatelessWidget {
  const AnswerChip({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final shape = StadiumBorder(side: BorderSide(color: selected ? c.cta : c.line, width: 1.5));
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? c.cta : c.card,
        shape: shape,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: selected ? c.onCta : c.body),
            ),
          ),
        ),
      ),
    );
  }
}

class _RememberSwitch extends StatelessWidget {
  const _RememberSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Material(
      color: c.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '다음에도 이대로',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.ink),
                    ),
                    const SizedBox(height: 2),
                    Text(keepAll('선택한 값은 이 기기에만 저장됩니다.'), style: captionStyle(context)),
                  ],
                ),
              ),
              ExcludeSemantics(
                child: Switch(
                  value: value,
                  onChanged: onChanged,
                  activeTrackColor: c.cta,
                  activeThumbColor: c.onCta,
                  inactiveTrackColor: c.line,
                  inactiveThumbColor: c.card,
                  trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── 기다리는 화면 ─────────────────────────

/// 분석을 요청하고 기다린다 (명세 §11.3). 단계 표시는 실제 진행이 아니라 시간 기준이며 마지막 단계에서 멈춘다.
/// 성공하면 [AgentWaitResult.done]으로 닫힌다. 실패하면 이 화면에서 안내하고, 다시 시도는 같은 요청 id를 쓴다
/// (서버가 같은 id로 두 번 차감하지 않는다). 화면을 나가도 서버는 분석을 끝까지 처리해 저장한다.
class AgentWaitScreen extends StatefulWidget {
  const AgentWaitScreen({
    super.key,
    required this.repository,
    required this.noticeId,
    required this.title,
    required this.chips,
    required this.requestId,
  });

  final NoticeRepository repository;
  final String noticeId;
  final String? title;
  final AnalysisChips chips;
  final String requestId;

  @override
  State<AgentWaitScreen> createState() => _AgentWaitScreenState();
}

/// 단계가 바뀌는 시각 (30초 안팎에 맞춤)
const _stepAt = [Duration(seconds: 9), Duration(seconds: 20)];
const _steps = ['공고 읽는 중', '내 정보와 비교 중', '정리 중'];

class _AgentWaitScreenState extends State<AgentWaitScreen> {
  int _step = 0;
  Object? _error;
  final List<Timer> _timers = [];
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _run();
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    super.dispose();
  }

  void _startSteps() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    if (_still(context)) {
      // 애니메이션 줄이기: 움직이지 않고 마지막 단계로 고정
      _step = _steps.length - 1;
      return;
    }
    _step = 0;
    for (final (i, at) in _stepAt.indexed) {
      _timers.add(Timer(at, () => mounted ? setState(() => _step = i + 1) : null));
    }
  }

  /// [retry]이면 실패 안내를 걷고 같은 요청 id로 다시 보낸다.
  Future<void> _run({bool retry = false}) async {
    if (retry) {
      setState(() {
        _error = null;
        _startSteps();
      });
    } else {
      _startSteps();
    }
    try {
      final response = await widget.repository.requestAnalysis(
        noticeId: widget.noticeId,
        requestId: widget.requestId,
        chips: widget.chips,
      );
      if (mounted) Navigator.of(context).pop(AgentWaitResult.done(response));
    } catch (e) {
      for (final t in _timers) {
        t.cancel();
      }
      if (mounted) setState(() => _error = e);
    }
  }

  Widget _failure(Object error) {
    final kind = error is RepositoryException ? error.kind : RepositoryErrorKind.unavailable;
    switch (kind) {
      case RepositoryErrorKind.insufficientCredits:
        return MessageView(
          title: '크레딧 부족',
          detail: '크레딧이 없습니다. 내일 0시에 1개가 충전됩니다.',
          action: (
            label: '크레딧 보기',
            onPressed: () =>
                Navigator.of(context).push(gwRoute(context, (_) => CreditsScreen(repository: widget.repository))),
          ),
        );
      case RepositoryErrorKind.consentRequired:
        return MessageView(
          title: 'AI 전송 동의 필요',
          detail: '동의 기록을 확인하지 못했습니다. 동의 화면에서 다시 동의해 주세요.',
          action: (label: '동의 화면으로', onPressed: () => Navigator.of(context).pop(const AgentWaitResult.needConsent())),
        );
      case RepositoryErrorKind.requestInProgress:
        return MessageView(
          title: '분석 진행 중',
          detail: '같은 분석이 이미 진행 중입니다. 잠시 뒤 다시 확인해 주세요.',
          onRetry: () => _run(retry: true),
        );
      case RepositoryErrorKind.unavailable:
        final reached = error is RepositoryException && error.fromServer;
        return MessageView(
          title: reached ? '분석 실패' : '연결 실패',
          detail: reached
              ? '분석에 실패했습니다. 크레딧은 차감되지 않았습니다. 잠시 후 다시 시도해 주세요.'
              : '인터넷 연결을 확인해 주세요. 같은 요청으로 다시 시도하므로 크레딧이 두 번 차감되지 않습니다.',
          onRetry: () => _run(retry: true),
        );
      default:
        return MessageView.error(error, onRetry: () => _run(retry: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Scaffold(
      appBar: GwTopBar(title: widget.title),
      body: switch (_error) {
        final error? => _failure(error),
        _ => ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          children: [
            Semantics(
              liveRegion: true,
              container: true,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(20)),
                child: Column(
                  children: [
                    for (final (i, label) in _steps.indexed)
                      _StepLine(index: i, label: label, step: _step, last: i == _steps.length - 1),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            const _ReportSkeletons(),
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(child: Icon(Icons.info_rounded, size: 20, color: c.muted)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      keepAll('화면을 나가도 분석은 계속됩니다. 끝나면 이 공고에서 볼 수 있습니다.'),
                      style: TextStyle(fontSize: 14, height: 1.7, color: c.sub),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      },
    );
  }
}

class _StepLine extends StatelessWidget {
  const _StepLine({required this.index, required this.label, required this.step, required this.last});

  final int index;
  final String label;
  final int step;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final done = index < step;
    final now = index == step;
    final change = _still(context) ? Duration.zero : const Duration(milliseconds: 320);
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: change,
            curve: Curves.easeOutCubic,
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: now ? c.cta : (done ? c.chip : c.neutral)),
            child: done
                ? Icon(Icons.check_rounded, size: 17, color: c.onChip)
                : Text(
                    '${index + 1}',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: now ? c.onCta : c.muted),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: now ? FontWeight.w700 : FontWeight.w400,
                color: now ? c.ink : (done ? c.sub : c.muted),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 리포트 칸 네 개 모양의 뼈대. 밝기만 은은하게 바뀌고, 애니메이션 줄이기이면 멈춘다.
class _ReportSkeletons extends StatelessWidget {
  const _ReportSkeletons();

  static const _shapes = [
    [0.92, 0.78, 0.6],
    [0.92, 0.78],
    [0.92, 0.6],
    [0.78, 0.92],
  ];

  @override
  Widget build(BuildContext context) {
    return GwSkeleton(
      child: Column(
        children: [
          for (final lines in _shapes)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: context.gw.card, borderRadius: BorderRadius.circular(20)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const FractionallySizedBox(widthFactor: 0.46, child: SkeletonBox(height: 18, radius: 8)),
                  for (final w in lines) ...[
                    const SizedBox(height: 10),
                    FractionallySizedBox(widthFactor: w, child: const SkeletonBox(height: 14, radius: 8)),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ───────────────────────── 리포트 ─────────────────────────

/// 상세 분석 리포트 (명세 §11.2): 나와 이 공고 → 지원 자격 → 지원 전 할 일 → 필요한 역량. 서버 판정이 미충족이면 지원 자격이 맨 위.
/// 서버가 준 글을 그대로 보이고, 지원 자격을 앱이 다시 판정하지 않는다.
class AnalysisReportScreen extends StatelessWidget {
  const AnalysisReportScreen({
    super.key,
    required this.response,
    this.title,
    this.receivedAt,
    this.skippedExperience = false,
    this.eligibilityStatus,
  });

  final AnalysisResponse response;

  /// 서버가 계산한 지원 자격 판정(met / not_met / needs_check). 추천 목록에서 들어온 공고만 있다.
  /// not_met일 때만 '지원 자격' 칸을 맨 위로 올린다. 리포트 글(LLM 문장)을 보고 순서를 정하지 않는다.
  final String? eligibilityStatus;

  /// 공고 제목. 모르면 null
  final String? title;

  /// 받은 시각(크레딧 내역에서 찾음). 저장본이면 보이고, 모르면 시각 없이 '받은 분석'만 보인다.
  final DateTime? receivedAt;

  /// '해 본 것'을 고르지 않고 분석했을 때만 맨 위에 안내한다 (명세 §5.2)
  final bool skippedExperience;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final r = response.report;
    final eligibilityCard = _ReportCard(title: '지원 자격', text: r.eligibility, style: _BodyStyle.bullets);
    return Scaffold(
      appBar: GwTopBar(title: title),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Text(
                keepAll(title!),
                style: TextStyle(fontSize: 17, height: 1.45, fontWeight: FontWeight.w600, color: c.ink),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 14),
            child: Text(
              response.fromCache
                  ? (receivedAt == null ? '받은 분석' : '받은 분석 · ${shortDateTime(receivedAt!)}')
                  : '내 기준 상세 분석',
              style: captionStyle(context),
            ),
          ),
          if (skippedExperience)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              decoration: BoxDecoration(
                color: c.summary,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(22),
                  topRight: Radius.circular(22),
                  bottomRight: Radius.circular(22),
                  bottomLeft: Radius.circular(6),
                ),
              ),
              child: Text(
                keepAll('해 본 것 정보가 없어 공고의 요구 사항만 정리했습니다.'),
                style: TextStyle(fontSize: 15, height: 1.6, color: c.body),
              ),
            ),
          // 기본 순서: 나와 이 공고 → 지원 자격 → 지원 전 할 일 → 필요한 역량 (명세 §11.2)
          if (eligibilityStatus == 'not_met') eligibilityCard,
          _ReportCard(title: '나와 이 공고', text: r.fit, style: _BodyStyle.bullets),
          if (eligibilityStatus != 'not_met') eligibilityCard,
          _ReportCard(title: '지원 전 할 일', text: r.todo, style: _BodyStyle.todo),
          _ReportCard(title: '필요한 역량', text: r.skills, style: _BodyStyle.chips),
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
            child: Text(keepAll('AI가 공고와 내 정보로 정리한 내용입니다. 합격 가능성과는 관계없습니다.'), style: captionStyle(context)),
          ),
        ],
      ),
    );
  }
}

enum _BodyStyle { bullets, todo, chips }

final _bulletMark = RegExp(r'^[-•·*]\s+');

/// 문장 끝(…다. / …음. / …함.). 한 문단으로 온 예전 리포트를 줄로 나눌 때 쓴다
final _sentenceEnd = RegExp(r'(?<=[다음함임됨]\.)\s+(?=\S)');

/// 이보다 긴 줄은 문장 끝에서 나눈다 (서버 split_long_lines와 같은 기준)
const _longLine = 90;

/// 리포트 글 한 칸을 줄 단위로 나눈다. 앞의 글머리 기호는 떼고, 빈 줄은 버린다.
/// 서버가 나누기 전에 받은 저장본처럼 한 문단이 길면 문장 끝에서 나눈다.
List<String> reportLines(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty)
      for (final part in (line.trim().length > _longLine ? line.trim().split(_sentenceEnd) : [line.trim()]))
        if (part.trim().isNotEmpty) part.trim().replaceFirst(_bulletMark, ''),
];

/// 줄 앞 꼬리표('맞음:', '안 맞음:', '확인 필요:', '판정: …'). 서버 지시문(prompt.py)과 같은 낱말
final _lineTag = RegExp(r'^(맞음|안 맞음|확인 필요|미충족|불충족|충족|판정)\s*[:：]\s*');

/// 공고 자료로 역량을 알 수 없을 때 지침이 쓰는 문장(backend/agent/harness/detail_analysis.md)
const skillsUnknown = '요구 역량을 확인하기 어렵습니다';

/// (꼬리표, 나머지 글). 꼬리표가 없으면 (null, 줄 그대로)
(String?, String) splitLineTag(String line) {
  final m = _lineTag.firstMatch(line);
  if (m == null) return (null, line);
  return (m.group(1), line.substring(m.end));
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.title, required this.text, required this.style});

  final String title;
  final String text;
  final _BodyStyle style;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final lines = reportLines(text);
    final body = TextStyle(fontSize: 15, height: 1.7, color: c.body);
    final Widget content;
    // 역량은 한 줄이어도 칩. '확인하기 어렵습니다' 안내 문장은 일반 문장으로
    if (style == _BodyStyle.chips &&
        lines.isNotEmpty &&
        lines.every((l) => l.length <= 20 && !l.contains(skillsUnknown))) {
      content = Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final l in lines)
            Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: c.chip, borderRadius: BorderRadius.circular(17)),
              child: Text(
                l,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.onChip),
              ),
            ),
        ],
      );
    } else if (lines.length <= 1) {
      content = _TaggedLine(line: lines.firstOrNull ?? '', style: body);
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (style == _BodyStyle.todo)
                    // 눌러서 체크하는 칸이 아니라 할 일을 구분하는 표시다.
                    ExcludeSemantics(
                      child: Container(
                        width: 22,
                        height: 22,
                        margin: const EdgeInsets.only(top: 3, right: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(color: c.faint, width: 1.5),
                        ),
                      ),
                    )
                  else
                    ExcludeSemantics(
                      child: Container(
                        width: 4,
                        height: 4,
                        margin: const EdgeInsets.only(top: 12, left: 4, right: 10),
                        decoration: BoxDecoration(color: c.muted, shape: BoxShape.circle),
                      ),
                    ),
                  Expanded(child: _TaggedLine(line: l, style: body)),
                ],
              ),
            ),
        ],
      );
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: c.ink),
            ),
          ),
          const SizedBox(height: 12),
          content,
        ],
      ),
    );
  }
}

/// 리포트 한 줄. '맞음:' 같은 꼬리표가 있으면 작은 색 꼬리표 + 나머지 글로 보인다.
/// 지원 자격 첫 줄은 '미충족: …'처럼 판정 낱말이 꼬리표가 된다. 예전 저장본의 '판정: …'과 '불충족'도 같은 꼬리표로 보인다(ui-style: 충족·미충족·확인 필요).
class _TaggedLine extends StatelessWidget {
  const _TaggedLine({required this.line, required this.style});

  final String line;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    var (tag, rest) = splitLineTag(line);
    if (tag == null) return Text(keepAll(line), style: style);
    if (tag == '판정') {
      // '판정: 확인 필요' → 꼬리표 '확인 필요', 뒤 글은 남은 말만
      final verdict = rest.trim();
      tag = verdict.startsWith('불충족') || verdict.startsWith('미충족')
          ? '미충족'
          : verdict.startsWith('충족')
          ? '충족'
          : '확인 필요';
      rest = verdict.replaceFirst(RegExp(r'^(불충족|미충족|충족|확인 필요)[.\s]*'), '');
    }
    if (tag == '불충족') tag = '미충족';
    final (bg, fg) = switch (tag) {
      '맞음' || '충족' => (c.chip, c.onChip),
      '안 맞음' || '미충족' => (c.urgentSoft, c.urgent),
      _ => (c.checkSoft, c.check),
    };
    final pill = Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(tag, style: TextStyle(fontSize: 13, height: 1.5, fontWeight: FontWeight.w700, color: fg)),
    );
    if (rest.trim().isEmpty) return Align(alignment: Alignment.centerLeft, child: pill);
    return Text.rich(
      TextSpan(children: [
        WidgetSpan(alignment: PlaceholderAlignment.middle, child: pill),
        TextSpan(text: keepAll(rest.trim())),
      ]),
      style: style,
    );
  }
}

// ───────────────────────── 공고 상세의 버튼 ─────────────────────────

/// 공고 상세의 상세 분석 버튼 (명세 §11.1, §11.4). 세 상태:
/// 크레딧 있음 '내 기준으로 자세히 보기' / 받은 분석 있음 '받은 분석 보기'(무료) / 크레딧 없음(흐리게).
/// 받은 분석은 크레딧과 상관없이 볼 수 있어 받은 분석이 먼저다.
class AnalysisAction extends StatelessWidget {
  const AnalysisAction({
    super.key,
    required this.loaded,
    required this.credits,
    required this.analysis,
    required this.receivedAt,
    required this.onStart,
    required this.onOpenResult,
    required this.onOpenCredits,
  });

  /// 크레딧·받은 분석을 처음 읽는 중이면 false
  final bool loaded;

  /// 읽지 못했으면 null (버튼은 쓸 수 있고, 잔액은 서버가 확인한다)
  final Credits? credits;
  final AnalysisResponse? analysis;
  final DateTime? receivedAt;
  final VoidCallback onStart;
  final VoidCallback onOpenResult;
  final VoidCallback onOpenCredits;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final Widget child;
    if (!loaded) {
      child = const GwSkeleton(child: SkeletonBox(height: 56, radius: 28));
    } else if (analysis != null) {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: onOpenResult,
            style: FilledButton.styleFrom(backgroundColor: c.chip, foregroundColor: c.onChip),
            icon: const Icon(Icons.description_rounded, size: 22),
            label: const Text('받은 분석 보기'),
          ),
          const SizedBox(height: 8),
          Text(
            receivedAt == null ? '무료' : '무료 · ${shortDateTime(receivedAt!)}에 받음',
            textAlign: TextAlign.center,
            style: captionStyle(context),
          ),
        ],
      );
    } else if (credits != null && credits!.balance < 1) {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 눌러도 화면을 넘기지 않는다. 크레딧 페이지로 가는 작은 링크만 둔다.
          Opacity(
            opacity: 0.4,
            child: FilledButton.icon(
              onPressed: null,
              style: FilledButton.styleFrom(disabledBackgroundColor: c.cta, disabledForegroundColor: c.onCta),
              icon: const Icon(Icons.auto_awesome_rounded, size: 22),
              label: const Text('내 기준으로 자세히 보기'),
            ),
          ),
          const SizedBox(height: 8),
          Text(keepAll('크레딧 없음 · 내일 0시 1개 충전'), textAlign: TextAlign.center, style: captionStyle(context)),
          Center(
            child: _LinkButton(label: '크레딧 보기', onPressed: onOpenCredits),
          ),
        ],
      );
    } else {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.auto_awesome_rounded, size: 22),
            label: const Text('내 기준으로 자세히 보기'),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(credits == null ? '1크레딧' : '1크레딧 ·', style: captionStyle(context)),
              if (credits != null)
                _LinkButton(label: '남은 ${credits!.balance}개', onPressed: onOpenCredits, chevron: false),
            ],
          ),
        ],
      );
    }
    return Padding(padding: const EdgeInsets.fromLTRB(24, 32, 24, 0), child: child);
  }
}

/// 글자 링크 (accent). 누르는 영역은 48 이상
class _LinkButton extends StatelessWidget {
  const _LinkButton({required this.label, required this.onPressed, this.chevron = true});

  final String label;
  final VoidCallback onPressed;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: c.accent,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        textStyle: const TextStyle(fontFamily: 'Pretendard', fontSize: 14, fontWeight: FontWeight.w600),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: chevron ? null : const TextStyle(decoration: TextDecoration.underline)),
          if (chevron) const Icon(Icons.chevron_right_rounded, size: 18),
        ],
      ),
    );
  }
}
