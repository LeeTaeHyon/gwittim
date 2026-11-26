import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/repository.dart';
import '../data/shared_notices.dart';
import '../share/share_inbox.dart';
import '../share/share_prepare.dart';
import '../share/share_services.dart';
import 'common.dart';
import 'components.dart';
import 'format.dart';
import 'report_screen.dart';
import 'skeleton.dart';
import 'theme.dart';

// 카카오톡 공고 넘기기 (D-058, docs/kakao-manual-share-spec.md §6):
// 받기(공유·붙여넣기) → (이미지면 글자 인식) → 확인 화면(수정·가림 미리보기) → (처음만) 동의 → 보내기 → 결과 화면.
// 원본 이미지는 기기 안에서 글자 인식만 하고 버린다. 서버에는 가린 글만 보낸다.

/// 공유로 받은 것(없으면 붙여넣기)을 확인 화면으로 연다. 저장소가 넘기기를 지원하지 않으면 안내만 한다.
Future<void> runShareFlow(
  BuildContext context, {
  required NoticeRepository repository,
  required OpenUrl openUrl,
  required ShareServices share,
  SharedPayload? payload,
  DateTime? today,
}) async {
  if (sharedApiOf(repository) == null) {
    final messenger = ScaffoldMessenger.of(context);
    if (payload is SharedImage) await deleteShareFile(payload.path);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(keepAll('이 실행에서는 카카오톡 공고 넘기기를 쓸 수 없습니다.'))),
      );
    return;
  }
  await Navigator.of(context).push(
    gwRoute(
      context,
      (_) => ShareConfirmScreen(
        repository: repository,
        openUrl: openUrl,
        share: share,
        initialText: payload is SharedText ? payload.text : '',
        imagePath: payload is SharedImage ? payload.path : null,
        input: switch (payload) {
          SharedText() => ShareInput.text,
          SharedImage() => ShareInput.imageOcr,
          null => ShareInput.paste,
        },
        today: today,
      ),
    ),
  );
}

/// 확인 화면: 입력칸(수정 가능) + 보낼 때 가려지는 부분 미리 표시 + 보내기.
class ShareConfirmScreen extends StatefulWidget {
  const ShareConfirmScreen({
    super.key,
    required this.repository,
    required this.openUrl,
    required this.share,
    required this.input,
    this.initialText = '',
    this.imagePath,
    this.today,
  });

  final NoticeRepository repository;
  final OpenUrl openUrl;
  final ShareServices share;
  final ShareInput input;
  final String initialText;

  /// 캡처 이미지 경로. 있으면 글자 인식 뒤 파일을 지운다.
  final String? imagePath;
  final DateTime? today;

  @override
  State<ShareConfirmScreen> createState() => _ShareConfirmScreenState();
}

class _ShareConfirmScreenState extends State<ShareConfirmScreen> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );
  bool _recognizing = false;
  bool _recognizeFailed = false;
  bool _sending = false;

  /// 글자 인식이 처음 낸 글. 사용자가 고쳤는지 비교한다.
  String? _recognized;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() => _notice = null));
    final path = widget.imagePath;
    if (path != null) {
      _recognizing = true;
      _recognize(path);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _recognize(String path) async {
    try {
      final text = await widget.share.ocr.recognize(path);
      if (!mounted) return;
      setState(() {
        _recognized = text.trim();
        _controller.value = TextEditingValue(text: _recognized!);
        _recognizing = false;
        _notice = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _recognizing = false;
          _recognizeFailed = true;
        });
      }
    } finally {
      await deleteShareFile(path); // 이미지는 인식이 끝나면 버린다
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      if (mounted) setState(() => _notice = '복사한 글이 없습니다.');
      return;
    }
    _controller.text = text;
  }

  bool get _ocrEdited =>
      _recognized != null && _controller.text.trim() != _recognized;

  Future<void> _send(SharePrep prep) async {
    if (_sending) return;
    final api = sharedApiOf(widget.repository);
    if (api == null) return;
    final navigator = Navigator.of(context);
    setState(() => _sending = true);
    try {
      // 처음 한 번 동의. 거부하면 보내지 않는다
      if (await widget.share.consent.readVersion() != shareConsentVersion) {
        if (!mounted) return;
        final agreed = await navigator.push<bool>(
          gwRoute(context, (_) => const ShareConsentScreen()),
        );
        if (agreed != true) return;
        await widget.share.consent.writeVersion(shareConsentVersion);
      }
      final result = await api.submitShared(
        text: prep.masked,
        input: widget.input,
        ocrEdited: widget.input == ShareInput.imageOcr ? _ocrEdited : null,
      );
      if (!mounted) return;
      final item = result.item;
      if (item == null) {
        setState(() => _notice = '개인 알림이라 분류하지 않습니다.');
        return;
      }
      await navigator.pushReplacement(
        gwRoute(
          context,
          (_) => ReportScreen(
            repository: widget.repository,
            noticeId: item.notice.summary.noticeId,
            openUrl: widget.openUrl,
            today: widget.today,
            shared: item,
          ),
        ),
      );
    } catch (e) {
      if (e is RepositoryException &&
          e.kind == RepositoryErrorKind.consentRequired) {
        await widget.share.consent.clear(); // 문구 버전이 달라졌다. 다음에 다시 묻는다
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(keepAll(errorMessage(e)))));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    final prep = prepareShare(_controller.text);
    final empty = _controller.text.trim().isEmpty;
    final ocr = widget.input == ShareInput.imageOcr;
    final String? problem = empty || _recognizing
        ? null
        : prep.isPersonal
        ? '개인 알림이라 분류하지 않습니다.'
        : prep.tooShort
        ? '글이 너무 짧습니다. $shareTextMin자 이상이어야 합니다.'
        : prep.tooLong
        ? '글이 너무 깁니다. $shareTextMax자 이하로 줄여 주세요.'
        : _notice;
    return Scaffold(
      appBar: GwTopBar(onClose: () => Navigator.of(context).pop()),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Semantics(
            header: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 14),
              child: Text(
                '넘길 공고 확인',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.6,
                  color: c.ink,
                ),
              ),
            ),
          ),
          if (ocr)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: c.checkSoft,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                keepAll('인식한 글자가 틀릴 수 있습니다. 확인 뒤 보내십시오.'),
                style: TextStyle(
                  fontSize: 14,
                  height: 1.55,
                  fontWeight: FontWeight.w600,
                  color: c.check,
                ),
              ),
            ),
          if (_recognizing)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 36),
              child: Column(
                children: [
                  const GwLoadingLogo(),
                  const SizedBox(height: 14),
                  Text('글자 인식 중', style: TextStyle(fontSize: 15, color: c.sub)),
                ],
              ),
            )
          else ...[
            if (_recognizeFailed)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  keepAll('글자를 인식하지 못했습니다. 글을 직접 입력하거나 붙여넣어 주세요.'),
                  style: TextStyle(fontSize: 14, height: 1.55, color: c.urgent),
                ),
              ),
            TextField(
              key: const ValueKey('share-input'),
              controller: _controller,
              minLines: 6,
              maxLines: 14,
              keyboardType: TextInputType.multiline,
              style: TextStyle(fontSize: 15, height: 1.6, color: c.body),
              decoration: InputDecoration(
                hintText: widget.input == ShareInput.paste
                    ? '카카오톡에서 복사한 공고 글을 붙여넣어 주세요.'
                    : null,
                filled: true,
                fillColor: c.card,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: c.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: c.line),
                ),
              ),
            ),
            if (widget.input == ShareInput.paste)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SoftButton(
                    label: '복사한 글 붙여넣기',
                    icon: null,
                    onPressed: _paste,
                  ),
                ),
              ),
            if (!empty) ...[
              const SizedBox(height: 18),
              Semantics(
                header: true,
                child: Text(
                  '보낼 글 미리 보기',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: c.ink,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                prep.maskedCount == 0
                    ? '가려진 개인정보가 없습니다.'
                    : '학번·휴대폰·교수 이름·받는 사람 이름 ${prep.maskedCount}곳을 가렸습니다.',
                key: const ValueKey('share-mask-count'),
                style: captionStyle(context),
              ),
              const SizedBox(height: 8),
              Container(
                key: const ValueKey('share-preview'),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: c.cardSoft,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text.rich(
                  _previewSpan(prep.masked, c),
                  style: TextStyle(fontSize: 14, height: 1.6, color: c.body),
                ),
              ),
            ],
            if (problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  keepAll(problem),
                  key: const ValueKey('share-problem'),
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.55,
                    fontWeight: FontWeight.w600,
                    color: c.urgent,
                  ),
                ),
              ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: _sending || empty || !prep.sendable
                  ? null
                  : () => _send(prep),
              child: Text(_sending ? '분석 중' : '보내기'),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                keepAll('가린 글만 서버로 보냅니다. 원본 이미지는 보내지 않습니다.'),
                textAlign: TextAlign.center,
                style: captionStyle(context),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 가린 자리(<학번> 등)를 형광펜으로 보인다.
  TextSpan _previewSpan(String masked, GwColors c) {
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in maskTokens.allMatches(masked)) {
      if (m.start > last) {
        spans.add(TextSpan(text: masked.substring(last, m.start)));
      }
      spans.add(
        TextSpan(
          text: m.group(0),
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: c.ink,
            backgroundColor: c.marker,
          ),
        ),
      );
      last = m.end;
    }
    if (last < masked.length) spans.add(TextSpan(text: masked.substring(last)));
    return TextSpan(children: spans);
  }
}

/// 첫 전달 때 한 번 보이는 동의 화면. 동의하면 true, 아니면 false (보내지 않음).
class ShareConsentScreen extends StatelessWidget {
  const ShareConsentScreen({super.key});

  static const lines = [
    ('저장', '가린 글이 내 계정에 저장됩니다. 다른 사용자에게는 보이지 않습니다.'),
    ('쓰임', '분류 모델을 개선하는 데 쓰입니다.'),
    ('이미지', '원본 이미지는 보내지 않습니다. 기기 안에서 글자만 읽고 버립니다.'),
    ('삭제', '저장함의 카톡 공고에서 언제든 지울 수 있고, 탈퇴하면 모두 지워집니다.'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Scaffold(
      appBar: GwTopBar(onClose: () => Navigator.of(context).pop(false)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Semantics(
            header: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 14),
              child: Text(
                '카톡 공고 넘기기 안내',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.6,
                  color: c.ink,
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: c.cardSoft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                for (final (i, l) in lines.indexed) ...[
                  if (i > 0) Divider(height: 1, color: c.line),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 52,
                          child: Text(
                            l.$1,
                            style: TextStyle(fontSize: 13, color: c.muted),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            keepAll(l.$2),
                            style: TextStyle(
                              fontSize: 15,
                              height: 1.55,
                              color: c.body,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 16, 2, 0),
            child: Text(
              keepAll('동의하지 않으면 카톡 공고를 넘길 수 없습니다. 다른 기능에는 영향이 없습니다.'),
              style: TextStyle(fontSize: 15, height: 1.65, color: c.body),
            ),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('동의하고 보내기'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  style: FilledButton.styleFrom(
                    backgroundColor: c.chip,
                    foregroundColor: c.onChip,
                  ),
                  child: const Text('동의하지 않음'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 저장 탭 위쪽: '카톡 공고 넘기기' 진입(붙여넣기 + 공유 방법 안내 한 줄)과 '카톡에서 넘긴 공고' 묶음(삭제).
class SharedNoticesSection extends StatelessWidget {
  const SharedNoticesSection({
    super.key,
    required this.items,
    required this.onPaste,
    required this.onOpen,
    required this.onDelete,
  });

  final List<SharedNoticeItem> items;
  final VoidCallback onPaste;
  final void Function(SharedNoticeItem) onOpen;
  final void Function(SharedNoticeItem) onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.gw;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TipBubble(
            title: '카톡 공고 넘기기',
            detail: '카카오톡 메시지를 길게 눌러 공유에서 귀띔을 고르거나, 복사한 글을 붙여넣습니다.',
            onTap: onPaste,
          ),
        ),
        if (items.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    '카톡에서 넘긴 공고',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: c.muted,
                    ),
                  ),
                ),
                for (final item in items)
                  InkWell(
                    key: ValueKey('shared-${item.id}'),
                    onTap: () => onOpen(item),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  keepTitle(item.notice.summary.title),
                                  style: TextStyle(
                                    fontSize: 16,
                                    height: 1.45,
                                    fontWeight: FontWeight.w600,
                                    color: c.body,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _meta(item),
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.5,
                                    color: c.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            key: ValueKey('shared-delete-${item.id}'),
                            tooltip: '삭제',
                            onPressed: () => onDelete(item),
                            icon: Icon(
                              Icons.delete_outline_rounded,
                              size: 22,
                              color: c.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  String _meta(SharedNoticeItem item) {
    final d = item.notice.summary.applicationDeadline;
    final event = sharedEventDay(item.notice);
    final at = item.createdAt.toLocal();
    final head = d != null
        ? '${shortDate(d)} 마감'
        : isPastSharedEvent(item.notice)
        ? '지난 행사'
        : event != null
        ? eventDayText(event)
        : '마감일 없음';
    return '$head · ${at.month}월 ${at.day}일 넘김';
  }
}

/// 공유로 받은 것이 있으면 저장 탭으로 보내고 확인 화면을 연다. 앱이 켜진 동안 계속 듣는다.
class ShareReceiver extends StatefulWidget {
  const ShareReceiver({
    super.key,
    required this.share,
    required this.repository,
    required this.openUrl,
    required this.onReceive,
    this.onDone,
    required this.child,
    this.today,
  });

  final ShareServices? share;
  final NoticeRepository repository;
  final OpenUrl openUrl;

  /// 확인 화면을 열기 전에 불린다(저장 탭으로 이동)
  final VoidCallback onReceive;

  /// 확인·결과 화면을 모두 닫은 뒤 불린다(저장 탭이 넘긴 공고를 다시 받는다)
  final VoidCallback? onDone;
  final DateTime? today;
  final Widget child;

  @override
  State<ShareReceiver> createState() => _ShareReceiverState();
}

class _ShareReceiverState extends State<ShareReceiver> {
  @override
  void initState() {
    super.initState();
    widget.share?.inbox.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    widget.share?.inbox.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final share = widget.share;
    if (share == null || !mounted) return;
    final payload = share.inbox.consume();
    if (payload == null) return;
    widget.onReceive();
    unawaited(
      runShareFlow(
        context,
        repository: widget.repository,
        openUrl: widget.openUrl,
        share: share,
        payload: payload,
        today: widget.today,
      ).whenComplete(() => widget.onDone?.call()),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
