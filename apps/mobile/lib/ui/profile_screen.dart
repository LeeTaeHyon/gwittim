import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'app_info.dart';
import 'common.dart';
import 'components.dart';
import 'format.dart';
import 'logo.dart';
import 'skeleton.dart';
import 'theme.dart';

/// 내 정보 (D-010, 2026-10-25 팀장 결정 Q5 B·Q6 A): 요약 카드 → 안내 → 설정(화면·계정·앱 정보).
/// 고치기는 학적 → 관심 분야 → 희망 직무 세 단계 화면에서 하고, 마지막 단계의 '저장하기'로 저장한다.
/// 성적·소득·주민등록번호·학번·학생증은 받지 않는다 (SPEC §5).
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.repository,
    required this.themeController,
    required this.onSaved,
    this.onSignOut,
  });

  final NoticeRepository repository;
  final ThemeController themeController;

  /// 저장 후 추천을 다시 받도록 알린다.
  final VoidCallback onSaved;

  /// 로그인 모드일 때만 있다. 없으면 계정 칸을 보이지 않는다.
  final Future<void> Function()? onSignOut;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileData {
  const _ProfileData(this.profile, this.universities, this.majors, this.interests, this.roles, this.majorInterests);

  final UserProfile? profile;
  final List<DictionaryItem> universities;
  final List<DictionaryItem> majors;
  final List<DictionaryItem> interests;
  final List<DictionaryItem> roles;

  /// 학과 → 졸업생이 많이 가는 관심 분야 (D-020)
  final Map<String, List<String>> majorInterests;

  _ProfileData withProfile(UserProfile p) => _ProfileData(p, universities, majors, interests, roles, majorInterests);
}

/// P0 대상 학교는 명지전문대 하나 (D-005 #6). 저장된 학교가 없을 때만 쓴다.
const _p0University = 'mjc';

const _statusNames = {'enrolled': '재학', 'on_leave': '휴학', 'graduated': '졸업'};

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<_ProfileData> _future = _load();

  /// 저장한 뒤 다시 받지 않고 바꿔 끼운 내용
  _ProfileData? _data;

  Future<_ProfileData> _load() async {
    final r = widget.repository;
    final data = _ProfileData(
      await r.getProfile(),
      await r.dictionary('universities'),
      await r.dictionary('majors'),
      await r.dictionary('interests'),
      await r.dictionary('roles'),
      await r.majorInterests(),
    );
    _data = data;
    return data;
  }

  Future<void> _edit(_ProfileData data) async {
    final saved = await Navigator.of(context).push<UserProfile>(
      gwRoute(
        context,
        (_) => ProfileEditScreen._(
          repository: widget.repository,
          profile: data.profile,
          universities: data.universities,
          majors: data.majors,
          interests: data.interests,
          roles: data.roles,
          majorInterests: data.majorInterests,
        ),
      ),
    );
    if (saved == null || !mounted) return;
    setState(() => _data = data.withProfile(saved));
    widget.onSaved();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('프로필이 저장되었습니다.')));
  }

  /// 프로필·저장 데이터 삭제는 아직 서버 인터페이스가 없다 (D-010 한계). 화면 버튼만 둔다.
  void _withdraw() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('탈퇴 기능은 준비 중입니다.')));
  }

  /// Flutter 기본 라이선스 화면. 패키지 라이선스와 Pretendard(registerAppLicenses)가 나온다.
  void _openLicenses() {
    Navigator.of(context).push(
      gwRoute(
        context,
        (_) => const LicensePage(
          applicationName: '귀띔',
          applicationVersion: appVersion,
          applicationIcon: Padding(padding: EdgeInsets.all(12), child: GwLogo(height: 40)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const GwTopBar(title: '내 정보'),
      body: FutureBuilder(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const ProfileSkeleton();
          }
          if (snapshot.hasError) {
            return MessageView.error(
              snapshot.error!,
              onRetry: () => setState(() {
                _future = _load();
              }),
            );
          }
          return _body(_data ?? snapshot.data!);
        },
      ),
    );
  }

  Widget _body(_ProfileData data) {
    final c = context.gw;
    final caption = captionStyle(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        const ScreenHeader('내 정보'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _SummaryCard(data: data, onEdit: () => _edit(data)),
        ),
        const SizedBox(height: 12),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: TipBubble(title: '입력한 정보는 추천에만 사용', detail: '지원 조건 비교와 추천 순서에만 사용하며, 성적·학번은 받지 않습니다.'),
        ),
        const SizedBox(height: 32),
        const Padding(padding: EdgeInsets.symmetric(horizontal: 24), child: SectionTitle('설정')),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GwCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _FieldLabel('화면'),
                const SizedBox(height: 10),
                ValueListenableBuilder(
                  valueListenable: widget.themeController,
                  builder: (context, mode, _) => _Segments<ThemeMode>(
                    options: const [(ThemeMode.system, '시스템 설정'), (ThemeMode.light, '라이트'), (ThemeMode.dark, '다크')],
                    selected: mode,
                    // 테마가 바뀌면 앱 전체가 다시 그려지므로, 바탕이 다 미끄러진 뒤에 바꾼다.
                    changeAfterSlide: true,
                    onChanged: (m) => widget.themeController.select(m ?? ThemeMode.system),
                  ),
                ),
                const SizedBox(height: 8),
                Text(keepAll('시스템 설정을 선택하면 기기 화면 모드를 따릅니다.'), style: caption),
                if (widget.onSignOut case final signOut?) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Divider(height: 1, color: c.line),
                  ),
                  const _FieldLabel('계정'),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(color: c.cardSoft, borderRadius: BorderRadius.circular(18)),
                    child: Row(
                      children: [
                        Icon(Icons.account_circle_rounded, size: 32, color: c.muted),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Google 계정으로 로그인됨',
                                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.body),
                              ),
                              const SizedBox(height: 2),
                              Text('다른 사람은 내 프로필을 볼 수 없습니다', style: TextStyle(fontSize: 13, color: c.muted)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _RoundButton(
                          label: '로그아웃',
                          background: c.chip,
                          foreground: c.onChip,
                          onPressed: signOut,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _RoundButton(
                          label: '탈퇴하기',
                          background: c.urgentSoft,
                          foreground: c.urgent,
                          onPressed: _withdraw,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(keepAll('탈퇴하면 프로필과 저장한 공고가 삭제됩니다. 공고 자체는 그대로 남습니다.'), style: caption),
                ],
                Padding(
                  padding: const EdgeInsets.only(top: 20, bottom: 4),
                  child: Divider(height: 1, color: c.line),
                ),
                const _InfoRow(label: '버전', value: appVersion),
                Divider(height: 1, color: c.line),
                _InfoRow(label: '오픈소스 라이선스', onTap: _openLicenses),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 맨 위 요약 카드: 학적 한 줄, 관심 분야 2개·희망 직무 1개(넘으면 +N), 고치기 버튼.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.data, required this.onEdit});

  final _ProfileData data;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final p = data.profile;
    String? name(List<DictionaryItem> items, String? id) => items.where((i) => i.id == id).firstOrNull?.name;
    final empty =
        p == null ||
        (p.majorId == null &&
            p.grade == null &&
            p.enrollmentStatus == null &&
            p.interestIds.isEmpty &&
            p.targetRoleIds.isEmpty);
    final school = [
      ?name(data.universities, p?.universityId),
      ?name(data.majors, p?.majorId),
      // 졸업이면 학년은 보이지 않는다(저장된 값은 그대로 둔다).
      if (p?.grade case final g? when p?.enrollmentStatus != 'graduated') '$g학년',
    ].join(' ');
    final line = [if (school.isNotEmpty) school, ?_statusNames[p?.enrollmentStatus]].join(' · ');
    return GwCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            empty ? '입력한 정보 없음' : line,
            style: TextStyle(fontSize: 17, height: 1.45, fontWeight: FontWeight.w700, color: c.ink),
          ),
          const SizedBox(height: 4),
          Text(
            keepAll(empty ? '학적과 관심 분야를 입력하면 맞춤 추천을 받을 수 있습니다.' : '추천과 지원 조건 비교에 쓰는 정보입니다.'),
            style: TextStyle(fontSize: 14, height: 1.5, color: c.sub),
          ),
          if (!empty) ...[
            const SizedBox(height: 14),
            _SummaryRow(label: '관심 분야', names: [for (final id in p.interestIds) ?name(data.interests, id)], show: 2),
            const SizedBox(height: 8),
            _SummaryRow(label: '희망 직무', names: [for (final id in p.targetRoleIds) ?name(data.roles, id)], show: 1),
          ],
          const SizedBox(height: 16),
          SoftButton(label: empty ? '입력하기' : '고치기', onPressed: onEdit),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.names, required this.show});

  final String label;
  final List<String> names;

  /// 칩으로 보일 개수. 나머지는 +N
  final int show;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(label, style: TextStyle(fontSize: 13, color: c.muted)),
          ),
        ),
        Expanded(
          child: names.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text('선택 안 함', style: TextStyle(fontSize: 14, color: c.muted)),
                )
              : Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final n in names.take(show)) Pill(n),
                    if (names.length > show) Pill('+${names.length - show}', tone: PillTone.neutral),
                  ],
                ),
        ),
      ],
    );
  }
}

/// 프로필 고치기: 학적 → 관심 분야 → 희망 직무. 위에 진행 점, 아래에 '다음'·'저장하기' 고정 버튼.
/// 저장에 성공하면 저장한 프로필을 돌려주며 닫히고, 실패하면 알리고 입력은 남긴다.
class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen._({
    required this.repository,
    required this.profile,
    required this.universities,
    required this.majors,
    required this.interests,
    required this.roles,
    required this.majorInterests,
  });

  final NoticeRepository repository;
  final UserProfile? profile;
  final List<DictionaryItem> universities;
  final List<DictionaryItem> majors;
  final List<DictionaryItem> interests;
  final List<DictionaryItem> roles;
  final Map<String, List<String>> majorInterests;

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

const _steps = ['학적', '관심 분야', '희망 직무'];

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  late String? _universityId = widget.profile?.universityId ?? _p0University;
  late String? _majorId = widget.profile?.majorId;
  late int? _grade = widget.profile?.grade;
  late String? _status = widget.profile?.enrollmentStatus;
  late Set<String> _interests = {...?widget.profile?.interestIds};
  late Set<String> _roles = {...?widget.profile?.targetRoleIds};
  int _step = 0;

  /// 단계가 바뀐 방향 (다음이면 1)
  int _direction = 1;
  bool _saving = false;

  void _go(int step) => setState(() {
    _direction = step > _step ? 1 : -1;
    _step = step;
  });

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final profile = UserProfile(
      universityId: _universityId,
      majorId: _majorId,
      grade: _grade,
      enrollmentStatus: _status,
      interestIds: _interests.toList()..sort(),
      targetRoleIds: _roles.toList()..sort(),
    );
    try {
      await widget.repository.updateProfile(profile);
      if (mounted) Navigator.of(context).pop(profile);
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(errorMessage(e))));
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pick({
    required String title,
    required List<DictionaryItem> items,
    required String? selected,
    required bool allowNone,
    required ValueChanged<String?> onPicked,
  }) async {
    // 화면 가운데 팝업. 살짝 작은 크기에서 커지며 나타난다.
    final still = MediaQuery.maybeDisableAnimationsOf(context) == true;
    final picked = await showGeneralDialog<({String? id})>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '닫기',
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: still ? Duration.zero : const Duration(milliseconds: 260),
      pageBuilder: (_, _, _) => _PickerDialog(title: title, items: items, selected: selected, allowNone: allowNone),
      transitionBuilder: (_, animation, _, child) {
        final curved = animation.drive(CurveTween(curve: Curves.easeOutCubic));
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(scale: curved.drive(Tween(begin: 0.94, end: 1.0)), child: child),
        );
      },
    );
    if (picked != null && mounted) setState(() => onPicked(picked.id));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final still = MediaQuery.maybeDisableAnimationsOf(context) == true;
    final last = _step == _steps.length - 1;
    // 뒤로 가기는 앞 단계로, 첫 단계에서는 저장하지 않고 닫는다.
    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _go(_step - 1);
      },
      // 학년·재학 칸의 neutral 바탕이 보이도록 카드 바탕 위에 둔다.
      child: Scaffold(
        backgroundColor: c.card,
        appBar: GwTopBar(title: _steps[_step]),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
              child: _StepDots(step: _step, count: _steps.length),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: still ? Duration.zero : const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  final entering = child.key == ValueKey(_step);
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: animation.drive(
                        Tween(begin: Offset((entering ? _direction : -_direction) * 0.12, 0), end: Offset.zero),
                      ),
                      child: child,
                    ),
                  );
                },
                child: KeyedSubtree(key: ValueKey(_step), child: _page(c)),
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: FilledButton(
              onPressed: _saving ? null : (last ? _save : () => _go(_step + 1)),
              child: Text(last ? '저장하기' : '다음'),
            ),
          ),
        ),
      ),
    );
  }

  Widget _page(GwColors c) {
    final caption = captionStyle(context);
    final names = {
      for (final i in [...widget.universities, ...widget.majors]) i.id: i.name,
    };
    final majors = [
      for (final m in widget.majors)
        if (_universityId == null || m.id.startsWith('$_universityId.')) m,
    ];
    final (title, detail, body) = switch (_step) {
      0 => (
        '학적',
        '미입력 항목은 지원 조건에 "확인 필요"로 표시됩니다. 선택한 칸을 다시 누르면 선택이 해제됩니다.',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PickRow(
              label: '학교',
              value: names[_universityId],
              onTap: () => _pick(
                title: '학교',
                items: widget.universities,
                selected: _universityId,
                allowNone: false,
                onPicked: (id) {
                  if (id != _universityId) _majorId = null;
                  _universityId = id;
                },
              ),
            ),
            _PickRow(
              label: '학과',
              value: names[_majorId],
              onTap: () => _pick(
                title: '학과',
                items: majors,
                selected: _majorId,
                allowNone: true,
                onPicked: (id) => _majorId = id,
              ),
            ),
            const SizedBox(height: 18),
            const _FieldLabel('학년'),
            const SizedBox(height: 8),
            _Segments<int>(
              options: const [(1, '1학년'), (2, '2학년'), (3, '3학년'), (4, '4학년')],
              selected: _grade,
              allowEmpty: true,
              onChanged: (g) => setState(() => _grade = g),
            ),
            const SizedBox(height: 18),
            const _FieldLabel('재학 상태'),
            const SizedBox(height: 8),
            _Segments<String>(
              options: const [('enrolled', '재학'), ('on_leave', '휴학'), ('graduated', '졸업')],
              selected: _status,
              allowEmpty: true,
              onChanged: (s) => setState(() => _status = s),
            ),
          ],
        ),
      ),
      1 => ('관심 분야', '선택한 분야와 관련된 공고가 먼저 표시됩니다.', _interestBody(names[_majorId])),
      _ => (
        '희망 직무',
        '선택한 직무와 관련된 공고가 먼저 표시됩니다.',
        _ChoiceChips(items: widget.roles, selected: _roles, onChanged: (s) => setState(() => _roles = s)),
      ),
    };
    final count = switch (_step) {
      1 => _interests.length,
      2 => _roles.length,
      _ => null,
    };
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.6, color: c.ink),
                ),
              ),
            ),
            if (count != null) Text('$count개 선택', style: caption),
          ],
        ),
        const SizedBox(height: 6),
        Text(keepAll(detail), style: caption),
        const SizedBox(height: 16),
        body,
      ],
    );
  }

  /// 관심 분야 단계. 학과를 골랐으면 졸업생이 많이 가는 분야를 먼저 보여 준다 (D-020).
  /// 미리 고르지 않는다. 학생이 눌러야 프로필에 들어간다.
  Widget _interestBody(String? majorName) {
    void onChanged(Set<String> s) => setState(() => _interests = s);
    final all = _ChoiceChips(items: widget.interests, selected: _interests, onChanged: onChanged);
    final ids = widget.majorInterests[_majorId] ?? const <String>[];
    final suggested = [for (final id in ids) ...widget.interests.where((i) => i.id == id)];
    if (majorName == null || suggested.isEmpty) return all;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TipBubble(
          title: '$majorName 졸업생이 많이 가는 분야',
          detail: '커리어넷 학과정보의 졸업생 진로 통계(2020 조사) 기준입니다. 누른 분야만 저장됩니다.',
        ),
        const SizedBox(height: 12),
        _ChoiceChips(items: suggested, selected: _interests, onChanged: onChanged),
        const SizedBox(height: 28),
        const _FieldLabel('전체 분야'),
        const SizedBox(height: 8),
        all,
      ],
    );
  }
}

/// 단계 진행 표시. 지금 단계는 길쭉한 점으로 보인다.
class _StepDots extends StatelessWidget {
  const _StepDots({required this.step, required this.count});

  final int step;
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final still = MediaQuery.maybeDisableAnimationsOf(context) == true;
    return Semantics(
      label: '${step + 1}/$count단계',
      child: ExcludeSemantics(
        child: Row(
          children: [
            for (var i = 0; i < count; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              AnimatedContainer(
                duration: still ? Duration.zero : const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                width: i == step ? 20 : 8,
                height: 8,
                decoration: BoxDecoration(color: i <= step ? c.cta : c.line, borderRadius: BorderRadius.circular(4)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: context.gw.sub),
    );
  }
}

/// 설정 > 앱 정보 줄. 값만 보이거나(버전), 누르면 다른 화면을 연다(라이선스).
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, this.value, this.onTap});

  final String label;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: c.body),
            ),
          ),
          if (value case final v?) Text(v, style: TextStyle(fontSize: 15, color: c.muted)),
          if (onTap != null) Icon(Icons.chevron_right_rounded, size: 20, color: c.muted),
        ],
      ),
    );
    if (onTap == null) return MergeSemantics(child: row);
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(12), child: row);
  }
}

/// 학교·학과 줄. 누르면 가운데 선택 팝업이 열린다.
class _PickRow extends StatelessWidget {
  const _PickRow({required this.label, required this.value, required this.onTap});

  final String label;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 54,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.line)),
        ),
        child: Row(
          children: [
            Text(label, style: TextStyle(fontSize: 15, color: c.muted)),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                value ?? '선택 안 함',
                textAlign: TextAlign.end,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: value == null ? FontWeight.w400 : FontWeight.w600,
                  color: value == null ? c.muted : c.body,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, size: 20, color: c.muted),
          ],
        ),
      ),
    );
  }
}

/// 학교·학과를 고르는 가운데 팝업. 고른 줄은 칩 색 면과 체크로 보이고, 항목이 많으면 이름으로 찾을 수 있다.
class _PickerDialog extends StatefulWidget {
  const _PickerDialog({required this.title, required this.items, required this.selected, required this.allowNone});

  final String title;
  final List<DictionaryItem> items;
  final String? selected;
  final bool allowNone;

  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  late String? _current = widget.selected;
  var _query = '';
  final _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 고른 항목이 목록 아래로 가려져 있을 때만 보이는 곳까지 내려 둔다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _selectedKey.currentContext;
      if (target != null && target.mounted) {
        Scrollable.ensureVisible(target, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      }
    });
  }

  /// 고른 표시를 바꾼 채로 닫아서, 닫히는 동안 새로 고른 줄이 보인다.
  void _choose(String? id) {
    setState(() => _current = id);
    Navigator.of(context).pop((id: id));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final query = _query.trim();
    final shown = [
      if (widget.allowNone && query.isEmpty) const DictionaryItem('', '선택 안 함'),
      for (final item in widget.items)
        if (query.isEmpty || item.name.contains(query)) item,
    ];
    // Dialog가 키보드만큼 위로 올려 준다.
    return Dialog(
      backgroundColor: c.card,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 10, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.title} 선택',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.6, color: c.ink),
                    ),
                  ),
                  IconButton(
                    tooltip: '닫기',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded, color: c.muted),
                  ),
                ],
              ),
            ),
            if (widget.items.length > 8)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: TextField(
                  onChanged: (text) => setState(() => _query = text),
                  style: TextStyle(fontSize: 15, color: c.ink),
                  decoration: InputDecoration(
                    hintText: '${widget.title} 이름으로 찾기',
                    hintStyle: TextStyle(fontSize: 15, color: c.muted),
                    prefixIcon: Icon(Icons.search_rounded, size: 20, color: c.muted),
                    filled: true,
                    fillColor: c.neutral,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  ),
                ),
              ),
            Flexible(
              // 찾는 동안 목록 길이가 바뀌면 창 높이도 부드럽게 따라간다.
              child: AnimatedSize(
                duration: MediaQuery.maybeDisableAnimationsOf(context) == true
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: shown.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 36),
                        child: Text(
                          '일치하는 ${widget.title}가 없습니다',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 15, color: c.muted),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
                        children: [for (final item in shown) _option(c, item)],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _option(GwColors c, DictionaryItem item) {
    final id = item.id.isEmpty ? null : item.id;
    final on = id == _current;
    final radius = BorderRadius.circular(14);
    return Padding(
      key: on ? _selectedKey : null,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: on ? c.chip : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: () => _choose(id),
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    item.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                      color: on ? c.onChip : (id == null ? c.muted : c.body),
                    ),
                  ),
                ),
                if (on)
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(color: c.point, shape: BoxShape.circle),
                    child: Icon(Icons.check_rounded, size: 15, color: c.pointTick),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 하나만 고르는 칸. allowEmpty면 고른 칸을 다시 눌러 비울 수 있다.
/// 고른 칸의 바탕은 하나뿐이고, 다른 칸을 고르면 그쪽으로 양옆으로 미끄러진다. 비우면 그 자리에서 흐려진다
/// (애니메이션 줄이기 설정이면 바로 바뀜).
class _Segments<T> extends StatefulWidget {
  const _Segments({
    required this.options,
    required this.selected,
    required this.onChanged,
    this.allowEmpty = false,
    this.changeAfterSlide = false,
  });

  final List<(T, String)> options;
  final T? selected;
  final bool allowEmpty;
  final ValueChanged<T?> onChanged;

  /// 바탕이 다 미끄러진 뒤에 onChanged를 부른다 (테마처럼 바꾸는 데 무거운 값)
  final bool changeAfterSlide;

  @override
  State<_Segments<T>> createState() => _SegmentsState<T>();
}

class _SegmentsState<T> extends State<_Segments<T>> {
  /// 비웠을 때 바탕이 흐려지며 머무는 자리
  late int _last = _index.clamp(0, widget.options.length - 1);

  /// changeAfterSlide일 때 미끄러지는 동안 먼저 보이는 값
  ({T? value})? _pending;

  T? get _shown => _pending == null ? widget.selected : _pending!.value;

  int get _index => widget.options.indexWhere((o) => o.$1 == _shown);

  @override
  void didUpdateWidget(_Segments<T> old) {
    super.didUpdateWidget(old);
    if (_pending != null && widget.selected == _pending!.value) _pending = null;
    if (_index >= 0) _last = _index;
  }

  void _tap(T value, bool still) {
    final next = value == _shown && widget.allowEmpty ? null : value;
    if (!widget.changeAfterSlide || still || next == _shown) {
      widget.onChanged(next);
      return;
    }
    setState(() {
      _pending = (value: next);
      if (_index >= 0) _last = _index;
    });
  }

  void _slid() {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    widget.onChanged(pending.value);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final still = MediaQuery.maybeDisableAnimationsOf(context) == true;
    final move = still ? Duration.zero : const Duration(milliseconds: 320);
    const gap = 4.0;
    final on = _index >= 0;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: c.neutral, borderRadius: BorderRadius.circular(16)),
      child: LayoutBuilder(
        builder: (context, box) {
          final n = widget.options.length;
          final width = (box.maxWidth - gap * (n - 1)) / n;
          return Stack(
            children: [
              AnimatedPositioned(
                key: const ValueKey('segment-thumb'),
                duration: move,
                curve: Curves.easeOutCubic,
                left: _last * (width + gap),
                onEnd: _slid,
                top: 0,
                bottom: 0,
                width: width,
                child: AnimatedOpacity(
                  opacity: on ? 1 : 0,
                  duration: move,
                  curve: Curves.easeOutCubic,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: c.cta, borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              Row(
                children: [
                  // 칸 너비를 바탕과 똑같이 둬야 바탕이 칸에 딱 맞는다.
                  for (final (i, (value, label)) in widget.options.indexed) ...[
                    if (i > 0) const SizedBox(width: gap),
                    SizedBox(
                      width: width,
                      child: Semantics(
                        button: true,
                        selected: value == _shown,
                        inMutuallyExclusiveGroup: true,
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _tap(value, still),
                            child: SizedBox(
                              height: 44,
                              child: Center(
                                child: AnimatedDefaultTextStyle(
                                  duration: move,
                                  curve: Curves.easeOutCubic,
                                  style: TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w700,
                                    color: value == _shown ? c.onCta : c.sub,
                                  ),
                                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 공통 사전의 칩 여러 개 고르기
class _ChoiceChips extends StatelessWidget {
  const _ChoiceChips({required this.items, required this.selected, required this.onChanged});

  final List<DictionaryItem> items;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in items)
          Builder(
            builder: (context) {
              final on = selected.contains(item.id);
              return Semantics(
                button: true,
                selected: on,
                child: Material(
                  color: on ? c.cta : c.card,
                  shape: StadiumBorder(side: BorderSide(color: on ? c.cta : c.line, width: 1.5)),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: () => onChanged(on ? ({...selected}..remove(item.id)) : {...selected, item.id}),
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (on) ...[Icon(Icons.check_rounded, size: 16, color: c.onCta), const SizedBox(width: 5)],
                          Text(
                            item.name,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: on ? c.onCta : c.body),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.label,
    required this.background,
    required this.foreground,
    required this.onPressed,
  });

  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        minimumSize: const Size(0, 48),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontFamily: 'Pretendard', fontSize: 15, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}
