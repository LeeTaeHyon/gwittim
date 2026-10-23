import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'common.dart';
import 'components.dart';
import 'theme.dart';

/// 프로필 입력·수정 (D-010): 학적 → 관심 분야 → 희망 직무 → 저장하기 → 화면 → 계정.
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
  const _ProfileData(this.profile, this.universities, this.majors, this.interests, this.roles);

  final UserProfile? profile;
  final List<DictionaryItem> universities;
  final List<DictionaryItem> majors;
  final List<DictionaryItem> interests;
  final List<DictionaryItem> roles;
}

/// P0 대상 학교는 명지전문대 하나 (D-005 #6). 저장된 학교가 없을 때만 쓴다.
const _p0University = 'mjc';

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<_ProfileData> _future = _load();

  String? _universityId;
  String? _majorId;
  int? _grade;
  String? _status;
  Set<String> _interests = {};
  Set<String> _roles = {};
  bool _saving = false;

  Future<_ProfileData> _load() async {
    final r = widget.repository;
    final data = _ProfileData(
      await r.getProfile(),
      await r.dictionary('universities'),
      await r.dictionary('majors'),
      await r.dictionary('interests'),
      await r.dictionary('roles'),
    );
    final p = data.profile;
    _universityId = p?.universityId ?? _p0University;
    _majorId = p?.majorId;
    _grade = p?.grade;
    _status = p?.enrollmentStatus;
    _interests = {...?p?.interestIds};
    _roles = {...?p?.targetRoleIds};
    return data;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.repository.updateProfile(
        UserProfile(
          universityId: _universityId,
          majorId: _majorId,
          grade: _grade,
          enrollmentStatus: _status,
          interestIds: _interests.toList()..sort(),
          targetRoleIds: _roles.toList()..sort(),
        ),
      );
      widget.onSaved();
      messenger.showSnackBar(const SnackBar(content: Text('프로필을 저장했어요.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(e))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 프로필·저장 데이터 삭제는 아직 서버 인터페이스가 없다 (D-010 한계). 화면 버튼만 둔다.
  void _withdraw() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('탈퇴는 아직 준비 중이에요.')));
  }

  Future<void> _pick({
    required String title,
    required List<DictionaryItem> items,
    required String? selected,
    required bool allowNone,
    required ValueChanged<String?> onPicked,
  }) async {
    final picked = await showModalBottomSheet<({String? id})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PickerSheet(title: title, items: items, selected: selected, allowNone: allowNone),
    );
    if (picked != null && mounted) setState(() => onPicked(picked.id));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return MessageView(
            icon: Icons.cloud_off,
            message: errorMessage(snapshot.error!),
            onRetry: () => setState(() {
              _future = _load();
            }),
          );
        }
        return _body(snapshot.data!);
      },
    );
  }

  Widget _body(_ProfileData data) {
    final c = context.gw;
    final caption = captionStyle(context);
    final names = {for (final i in [...data.universities, ...data.majors]) i.id: i.name};
    final majors = [
      for (final m in data.majors)
        if (_universityId == null || m.id.startsWith('$_universityId.')) m,
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const ScreenHeader('내 프로필'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: TipBubble(title: '입력한 정보는 추천에만 써요', detail: '지원 조건 비교와 추천 순서에만 쓰고, 성적·학번은 받지 않아요.'),
        ),
        Container(
          margin: const EdgeInsets.only(top: 16),
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 32),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionTitle('학적'),
              const SizedBox(height: 10),
              _PickRow(
                label: '학교',
                value: names[_universityId],
                onTap: () => _pick(
                  title: '학교',
                  items: data.universities,
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
              _FieldLabel('학년'),
              const SizedBox(height: 8),
              _Segments<int>(
                options: const [(1, '1학년'), (2, '2학년'), (3, '3학년'), (4, '4학년')],
                selected: _grade,
                allowEmpty: true,
                onChanged: (g) => setState(() => _grade = g),
              ),
              const SizedBox(height: 18),
              _FieldLabel('재학 상태'),
              const SizedBox(height: 8),
              _Segments<String>(
                options: const [('enrolled', '재학'), ('on_leave', '휴학'), ('graduated', '졸업')],
                selected: _status,
                allowEmpty: true,
                onChanged: (s) => setState(() => _status = s),
              ),
              const SizedBox(height: 8),
              Text('비워 둔 항목은 지원 조건을 "확인 필요"로 보여 드려요. 고른 칸을 다시 누르면 비울 수 있어요.', style: caption),
              const SizedBox(height: 36),
              SectionTitle('관심 분야', trailing: Text('${_interests.length}개 선택', style: caption)),
              const SizedBox(height: 6),
              Text('고른 분야와 관련된 공고를 먼저 보여 드려요.', style: caption),
              const SizedBox(height: 12),
              _ChoiceChips(
                items: data.interests,
                selected: _interests,
                onChanged: (s) => setState(() => _interests = s),
              ),
              const SizedBox(height: 36),
              SectionTitle('희망 직무', trailing: Text('${_roles.length}개 선택', style: caption)),
              const SizedBox(height: 12),
              _ChoiceChips(items: data.roles, selected: _roles, onChanged: (s) => setState(() => _roles = s)),
              const SizedBox(height: 28),
              FilledButton(onPressed: _saving ? null : _save, child: const Text('저장하기')),
              const SizedBox(height: 44),
              const SectionTitle('화면'),
              const SizedBox(height: 12),
              ValueListenableBuilder(
                valueListenable: widget.themeController,
                builder: (context, mode, _) => _Segments<ThemeMode>(
                  options: const [(ThemeMode.system, '시스템 설정'), (ThemeMode.light, '라이트'), (ThemeMode.dark, '다크')],
                  selected: mode,
                  onChanged: (m) => widget.themeController.select(m ?? ThemeMode.system),
                ),
              ),
              const SizedBox(height: 8),
              Text('시스템 설정을 고르면 기기 화면 모드를 따라가요.', style: caption),
              if (widget.onSignOut case final signOut?) ...[
                const SizedBox(height: 40),
                const SectionTitle('계정'),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: c.cardSoft, borderRadius: BorderRadius.circular(18)),
                  child: Row(
                    children: [
                      Icon(Icons.account_circle_outlined, size: 32, color: c.muted),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Google 계정으로 로그인했어요',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.body),
                            ),
                            const SizedBox(height: 2),
                            Text('다른 사람은 내 프로필을 볼 수 없어요', style: TextStyle(fontSize: 13, color: c.muted)),
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
                      child: _RoundButton(label: '로그아웃', background: c.chip, foreground: c.onChip, onPressed: signOut),
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
                Text('탈퇴하면 프로필과 저장한 공고가 지워져요. 공고 자체는 그대로 남아요.', style: caption),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: context.gw.sub));
  }
}

/// 학교·학과 줄. 누르면 아래에서 고르는 창이 열린다.
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
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
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
            Icon(Icons.chevron_right, size: 20, color: c.muted),
          ],
        ),
      ),
    );
  }
}

class _PickerSheet extends StatelessWidget {
  const _PickerSheet({required this.title, required this.items, required this.selected, required this.allowNone});

  final String title;
  final List<DictionaryItem> items;
  final String? selected;
  final bool allowNone;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final options = [if (allowNone) const DictionaryItem('', '선택 안 함'), ...items];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(title, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: c.ink)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final o in options)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                      title: Text(
                        o.name,
                        style: TextStyle(fontSize: 16, color: o.id.isEmpty ? c.muted : c.body),
                      ),
                      selected: (o.id.isEmpty ? null : o.id) == selected,
                      trailing: (o.id.isEmpty ? null : o.id) == selected ? Icon(Icons.check, color: c.accent) : null,
                      onTap: () => Navigator.of(context).pop((id: o.id.isEmpty ? null : o.id)),
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

/// 하나만 고르는 칸. allowEmpty면 고른 칸을 다시 눌러 비울 수 있다.
class _Segments<T> extends StatelessWidget {
  const _Segments({required this.options, required this.selected, required this.onChanged, this.allowEmpty = false});

  final List<(T, String)> options;
  final T? selected;
  final bool allowEmpty;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: c.neutral, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          for (final (i, (value, label)) in options.indexed)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
                child: Semantics(
                  button: true,
                  selected: value == selected,
                  inMutuallyExclusiveGroup: true,
                  child: Material(
                    color: value == selected ? c.cta : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => onChanged(value == selected && allowEmpty ? null : value),
                      child: SizedBox(
                        height: 44,
                        child: Center(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              color: value == selected ? c.onCta : c.sub,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
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
                          if (on) ...[Icon(Icons.check, size: 16, color: c.onCta), const SizedBox(width: 5)],
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
  const _RoundButton({required this.label, required this.background, required this.foreground, required this.onPressed});

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
