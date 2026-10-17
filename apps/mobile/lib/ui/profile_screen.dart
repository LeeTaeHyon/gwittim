import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'common.dart';

/// 프로필 입력·수정. 성적·소득·주민등록번호·학생증은 받지 않는다 (SPEC §5).
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.repository, required this.onSaved});

  final NoticeRepository repository;

  /// 저장 후 추천을 다시 받도록 알린다.
  final VoidCallback onSaved;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileData {
  const _ProfileData(this.profile, this.majors, this.interests, this.roles);

  final UserProfile? profile;
  final List<DictionaryItem> majors;
  final List<DictionaryItem> interests;
  final List<DictionaryItem> roles;
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<_ProfileData> _future = _load();

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
      await r.dictionary('majors'),
      await r.dictionary('interests'),
      await r.dictionary('roles'),
    );
    final p = data.profile;
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
          universityId: 'mjc', // P0 대상 학교는 명지전문대 하나 (D-005 #6)
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
        final data = snapshot.data!;
        final text = Theme.of(context).textTheme;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('입력한 정보로 지원 조건을 비교하고 공고를 추천해요. 비워 둔 항목은 "확인 필요"로 표시돼요.', style: text.bodySmall),
            const SizedBox(height: 16),
            const InputDecorator(
              decoration: InputDecoration(labelText: '학교', border: OutlineInputBorder()),
              child: Text('명지전문대학'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              key: const Key('major'),
              initialValue: _majorId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '학과', border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem(value: null, child: Text('선택 안 함')),
                for (final m in data.majors) DropdownMenuItem(value: m.id, child: Text(m.name)),
              ],
              onChanged: (v) => setState(() => _majorId = v),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int?>(
                    key: const Key('grade'),
                    initialValue: _grade,
                    decoration: const InputDecoration(labelText: '학년', border: OutlineInputBorder()),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('선택 안 함')),
                      for (final g in [1, 2, 3, 4]) DropdownMenuItem(value: g, child: Text('$g학년')),
                    ],
                    onChanged: (v) => setState(() => _grade = v),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    key: const Key('status'),
                    initialValue: _status,
                    decoration: const InputDecoration(labelText: '재학 상태', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: null, child: Text('선택 안 함')),
                      DropdownMenuItem(value: 'enrolled', child: Text('재학')),
                      DropdownMenuItem(value: 'on_leave', child: Text('휴학')),
                      DropdownMenuItem(value: 'graduated', child: Text('졸업')),
                    ],
                    onChanged: (v) => setState(() => _status = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text('관심 분야', style: text.titleSmall),
            const SizedBox(height: 8),
            _ChipGroup(items: data.interests, selected: _interests, onChanged: (s) => setState(() => _interests = s)),
            const SizedBox(height: 20),
            Text('희망 직무', style: text.titleSmall),
            const SizedBox(height: 8),
            _ChipGroup(items: data.roles, selected: _roles, onChanged: (s) => setState(() => _roles = s)),
            const SizedBox(height: 24),
            FilledButton(onPressed: _saving ? null : _save, child: const Text('프로필 저장')),
          ],
        );
      },
    );
  }
}

class _ChipGroup extends StatelessWidget {
  const _ChipGroup({required this.items, required this.selected, required this.onChanged});

  final List<DictionaryItem> items;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final item in items)
          FilterChip(
            label: Text(item.name),
            selected: selected.contains(item.id),
            onSelected: (on) => onChanged(on ? {...selected, item.id} : ({...selected}..remove(item.id))),
          ),
      ],
    );
  }
}
