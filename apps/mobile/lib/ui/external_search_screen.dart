import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'agent_data.dart';
import 'agent_flow.dart';
import 'common.dart';
import 'components.dart';
import 'credits_screen.dart';
import 'format.dart';
import 'skeleton.dart';
import 'theme.dart';

// 외부 공고 찾기 (D-047, docs/agent-privacy-spec.md §2.3·§12.1):
// 조건(모두 선택) → (처음만) 동의 화면 → 웹에서 찾는 중 → 결과 카드.
// 결과가 있을 때만 크레딧 2개가 차감된다. 결과는 서버에도 앱에도 저장하지 않고, 화면을 닫으면 사라진다.

/// 외부 공고 찾기에서 고를 수 있는 공고 분류 (사전 순서 그대로 보인다)
const _externalCategories = {
  'contest',
  'internship',
  'education_program',
  'extracurricular',
  'global',
  'startup',
  'volunteer',
  'job',
  'scholarship',
};

/// 같은 질문의 다른 칩과 함께 고를 수 없는 칩 ('상관없음')
const _anyRegion = 'any';

/// 관심 분야는 최대 5개 (external_search_request.schema.json)
const _maxInterests = 5;

enum _Phase { form, waiting, result, error }

class _Choices {
  const _Choices({required this.categories, required this.interests, required this.period, required this.regions});

  final List<DictionaryItem> categories;
  final List<DictionaryItem> interests;
  final List<DictionaryItem> period;
  final List<DictionaryItem> regions;
}

class ExternalSearchScreen extends StatefulWidget {
  const ExternalSearchScreen({super.key, required this.repository, required this.openUrl});

  final NoticeRepository repository;
  final OpenUrl openUrl;

  @override
  State<ExternalSearchScreen> createState() => _ExternalSearchScreenState();
}

class _ExternalSearchScreenState extends State<ExternalSearchScreen> {
  late Future<_Choices> _future = _load();
  final _query = TextEditingController();

  String? _category;
  final Set<String> _interests = {};
  String? _period;
  final Set<String> _regions = {};
  bool _defaultsApplied = false;

  _Phase _phase = _Phase.form;
  ExternalSearchResult? _result;
  Object? _error;

  /// 지금 요청의 id. 재시도 때만 그대로 쓰고, 찾기를 새로 누르면 새로 만든다.
  String? _requestId;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<_Choices> _load() async {
    final r = widget.repository;
    // 학교 밖에서 학생이 직접 지원하는 기회만. 학사 안내·행사·행정 공지·기타는 교내 공지용 분류라 뺀다
    final categories = [for (final i in await r.dictionary('categories')) if (_externalCategories.contains(i.id)) i];
    final interests = await r.dictionary('interests');
    final period = await r.dictionary('period_chips');
    final regions = await r.dictionary('region_chips');
    if (!_defaultsApplied) {
      _defaultsApplied = true;
      try {
        // 관심 분야는 내 정보에 입력한 값을 처음 칩으로 보인다. 지우거나 바꿀 수 있고, 입력하지 않았으면 비어 있다.
        final profile = await r.getProfile();
        final known = {for (final i in interests) i.id};
        _interests.addAll([for (final id in profile?.interestIds ?? const <String>[]) if (known.contains(id)) id].take(_maxInterests));
      } catch (_) {
        // 프로필을 읽지 못하면 고른 것 없이 시작한다.
      }
    }
    return _Choices(categories: categories, interests: interests, period: period, regions: regions);
  }

  void _toggleInterest(String id) {
    setState(() {
      if (_interests.remove(id)) return;
      if (_interests.length >= _maxInterests) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(keepAll('관심 분야는 최대 $_maxInterests개까지 고를 수 있습니다.'))));
        return;
      }
      _interests.add(id);
    });
  }

  void _toggleRegion(String id) {
    setState(() {
      if (!_regions.remove(id)) {
        if (id == _anyRegion) {
          _regions.clear();
        } else {
          _regions.remove(_anyRegion);
        }
        _regions.add(id);
      }
    });
  }

  /// 찾기 버튼: 동의를 확인하고, 새 요청 id로 보낸다.
  Future<void> _start() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final UserProfile? profile;
    try {
      profile = await widget.repository.getProfile();
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(keepAll(errorMessage(e)))));
      return;
    }
    if (!mounted) return;
    if (profile == null) {
      // 사용자 정보를 추정해 채우지 않는다. 내 정보를 입력한 뒤에 쓸 수 있다.
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(keepAll('내 정보를 먼저 입력해 주세요.'))));
      return;
    }
    if (!profile.hasAgentConsent) {
      final agreed = await navigator.push<bool>(
        gwRoute(context, (_) => AgentConsentScreen(repository: widget.repository)),
      );
      if (agreed != true || !mounted) return;
    }
    _requestId = newRequestId();
    await _run();
  }

  Future<void> _run() async {
    final id = _requestId!;
    setState(() {
      _phase = _Phase.waiting;
      _error = null;
    });
    try {
      final result = await widget.repository.requestExternalSearch(
        requestId: id,
        category: _category,
        interests: _interests.toList()..sort(),
        period: _period,
        regions: _regions.toList()..sort(),
        query: _query.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _phase = _Phase.result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _phase = _Phase.error;
      });
    }
  }

  void _backToForm() => setState(() {
    _phase = _Phase.form;
    _result = null;
    _error = null;
  });

  Future<void> _open(ExternalSearchItem item) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(item.url);
    var opened = false;
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      try {
        opened = await widget.openUrl(uri);
      } catch (_) {
        opened = false;
      }
    }
    if (opened) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(keepAll('원문을 열지 못했습니다.'))));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const GwTopBar(title: '학교 밖 기회 찾기'),
      body: switch (_phase) {
        _Phase.form => _form(),
        _Phase.waiting => _waiting(),
        _Phase.result => _resultView(_result!),
        _Phase.error => _failure(_error!),
      },
    );
  }

  Widget _header(BuildContext context) {
    final c = context.gw;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              '학교 밖 기회 찾기',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.6, color: c.ink),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            keepAll('AI가 웹에서 학생 조건에 맞는 공모전·대외활동을 찾습니다.'),
            style: TextStyle(fontSize: 15, height: 1.6, color: c.sub),
          ),
        ],
      ),
    );
  }

  // ───────────── 조건 ─────────────

  Widget _form() {
    final c = context.gw;
    return FutureBuilder(
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
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 150),
              children: [
                _header(context),
                _Group(
                  title: '공고 분류',
                  hint: '하나 선택',
                  items: choices.categories,
                  isSelected: (id) => _category == id,
                  onTap: (id) => setState(() => _category = _category == id ? null : id),
                ),
                _Group(
                  title: '관심 분야',
                  hint: '최대 $_maxInterests개',
                  items: choices.interests,
                  isSelected: _interests.contains,
                  onTap: _toggleInterest,
                ),
                _Group(
                  title: '가능한 시기',
                  hint: '하나 선택',
                  items: choices.period,
                  isSelected: (id) => _period == id,
                  onTap: (id) => setState(() => _period = _period == id ? null : id),
                ),
                _Group(
                  title: '갈 수 있는 지역',
                  hint: '여러 개 선택',
                  items: choices.regions,
                  isSelected: _regions.contains,
                  onTap: _toggleRegion,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 26, 4, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          '한 줄로 직접 적기',
                          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: c.ink),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('선택', style: TextStyle(fontSize: 13, color: c.muted)),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _query,
                  maxLength: externalQueryMax,
                  textInputAction: TextInputAction.done,
                  style: TextStyle(fontSize: 15, color: c.ink),
                  decoration: InputDecoration(
                    hintText: '예: 데이터 분석 공모전',
                    hintStyle: TextStyle(fontSize: 15, color: c.muted),
                    counterStyle: TextStyle(fontSize: 13, color: c.muted),
                    filled: true,
                    fillColor: c.card,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
                  child: Text(
                    keepAll('적은 문장은 AI(DeepSeek)에 보내집니다. 이름·연락처 같은 개인정보는 적지 마십시오.'),
                    style: captionStyle(context),
                  ),
                ),
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
                          keepAll('결과가 있을 때만 크레딧이 차감됩니다.'),
                          textAlign: TextAlign.center,
                          style: captionStyle(context),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(onPressed: _start, child: const Text('찾기 · 크레딧 2개')),
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
    );
  }

  // ───────────── 기다림 ─────────────

  Widget _waiting() {
    final c = context.gw;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
      children: [
        _header(context),
        const SizedBox(height: 18),
        Semantics(
          liveRegion: true,
          container: true,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(20)),
            child: Text(
              '웹에서 찾는 중입니다',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.ink),
            ),
          ),
        ),
        const SizedBox(height: 12),
        GwSkeleton(
          child: Column(
            children: [
              for (var i = 0; i < 3; i++)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(20)),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FractionallySizedBox(widthFactor: 0.7, child: SkeletonBox(height: 18, radius: 8)),
                      SizedBox(height: 10),
                      FractionallySizedBox(widthFactor: 0.4, child: SkeletonBox(height: 14, radius: 8)),
                      SizedBox(height: 10),
                      FractionallySizedBox(widthFactor: 0.9, child: SkeletonBox(height: 14, radius: 8)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            keepAll('보통 몇 초에서 10초 정도 걸립니다.'),
            style: captionStyle(context),
          ),
        ),
      ],
    );
  }

  // ───────────── 결과 ─────────────

  Widget _resultView(ExternalSearchResult result) {
    if (result.items.isEmpty) {
      final excluded = result.excludedNotMet > 0 ? ' 원문을 읽어 보니 지원 자격이 맞지 않는 ${result.excludedNotMet}건은 뺐습니다.' : '';
      return _withBack(
        MessageView(title: '결과 없음', detail: '조건에 맞는 공고를 찾지 못했습니다.$excluded 크레딧은 차감되지 않았습니다.'),
      );
    }
    final c = context.gw;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        _header(context),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 14),
          child: Text(
            keepAll(
              'AI가 웹에서 찾고 원문을 읽어, 응모 대상을 귀띔 규칙으로 판정했습니다. 지원 전에 원문을 확인하십시오.'
              '${result.excludedNotMet > 0 ? ' 지원 자격이 맞지 않는 ${result.excludedNotMet}건은 뺐습니다.' : ''}',
            ),
            style: TextStyle(fontSize: 14, height: 1.6, color: c.sub),
          ),
        ),
        for (final item in result.items) ...[
          _ResultCard(item: item, onTap: () => _open(item)),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 10),
        Center(child: SoftButton(label: '조건 바꿔 다시 찾기', icon: null, onPressed: _backToForm)),
      ],
    );
  }

  /// 빈 결과·오류 화면 아래에 조건으로 돌아가는 버튼을 붙인다.
  Widget _withBack(Widget view) {
    return Column(
      children: [
        Expanded(child: view),
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: TextButton(onPressed: _backToForm, child: const Text('조건 바꾸기')),
        ),
      ],
    );
  }

  Widget _failure(Object error) {
    final kind = error is RepositoryException ? error.kind : RepositoryErrorKind.unavailable;
    switch (kind) {
      case RepositoryErrorKind.insufficientCredits:
        return _withBack(
          MessageView(
            title: '크레딧 부족',
            detail: '크레딧이 부족합니다. 외부 공고 찾기는 2개가 필요합니다.',
            action: (
              label: '크레딧 보기',
              onPressed: () =>
                  Navigator.of(context).push(gwRoute(context, (_) => CreditsScreen(repository: widget.repository))),
            ),
          ),
        );
      case RepositoryErrorKind.consentRequired:
        return _withBack(
          const MessageView(title: 'AI 전송 동의 필요', detail: '동의 기록을 확인하지 못했습니다. 다시 찾으면 동의 화면이 열립니다.'),
        );
      case RepositoryErrorKind.requestInProgress:
        return _withBack(
          MessageView(
            title: '검색 진행 중',
            detail: '같은 검색이 이미 진행 중입니다. 잠시 뒤 다시 확인해 주세요.',
            onRetry: _run,
          ),
        );
      default:
        final reached = error is RepositoryException && error.fromServer;
        // 서버에 닿았는지 모르면 차감 여부를 단정하지 않는다. 같은 요청 id로 다시 보내므로 두 번 차감되지 않는다.
        return _withBack(
          MessageView(
            title: '찾지 못함',
            detail: reached
                ? '지금은 찾을 수 없습니다. 크레딧은 차감되지 않았습니다.'
                : '지금은 찾을 수 없습니다. 인터넷 연결을 확인해 주세요. 같은 요청으로 다시 시도하므로 크레딧이 두 번 차감되지 않습니다.',
            onRetry: _run,
          ),
        );
    }
  }
}

/// 조건 한 묶음: 제목 + 힌트 + 고르는 칩
class _Group extends StatelessWidget {
  const _Group({
    required this.title,
    required this.hint,
    required this.items,
    required this.isSelected,
    required this.onTap,
  });

  final String title;
  final String hint;
  final List<DictionaryItem> items;
  final bool Function(String id) isSelected;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 26, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 좁은 폭·큰 글자에서 한 줄에 안 들어가면 안내('여러 개 선택')가 통째로 아랫줄로 간다.
          Semantics(
            header: true,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: keepAll(title),
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: c.ink),
                  ),
                  TextSpan(
                    text: '  ${keepTogether(hint)}',
                    style: TextStyle(fontSize: 13, color: c.muted),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          AnswerChipWrap(
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

/// 결과 한 건. 누르면 원문을 연다.
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.item, required this.onTap});

  final ExternalSearchItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return GwCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  keepAll(item.title),
                  style: TextStyle(fontSize: 17, height: 1.45, fontWeight: FontWeight.w700, color: c.ink),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Icon(Icons.open_in_new_rounded, size: 18, color: c.muted, semanticLabel: '원문 열기'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 판정 꼬리표: 원문을 읽었으면 충족·확인 필요, 못 읽었으면 '원문 미확인', 검색 출처에도 없으면 '출처 확인 안 됨'
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (item.verdict == 'met') const Pill('충족', tone: PillTone.chip),
              if (item.verdict == 'needs_check') const Pill('확인 필요', tone: PillTone.check),
              if (!item.read && item.verified) const Pill('원문 미확인', tone: PillTone.neutral),
              if (!item.verified) const Pill('출처 확인 안 됨', tone: PillTone.check),
              Pill(item.deadline == null ? '마감 원문 확인' : '마감 ${item.deadline}', tone: PillTone.neutral),
            ],
          ),
          if (item.target != null) ...[
            const SizedBox(height: 10),
            Text(
              keepAll('응모 대상 · ${item.target}'),
              style: TextStyle(fontSize: 14, height: 1.55, fontWeight: FontWeight.w600, color: c.sub),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            [if (item.organizer != null) '주최 · ${item.organizer}', '출처 · ${item.sourceName}'].join('   '),
            style: TextStyle(fontSize: 13, color: c.muted),
          ),
          const SizedBox(height: 10),
          Text(keepAll(item.reason), style: TextStyle(fontSize: 15, height: 1.65, color: c.body)),
        ],
      ),
    );
  }
}
