import 'package:flutter/material.dart';

import '../data/repository.dart';

/// 원문 열기 (url_launcher). 테스트에서는 바꿔 끼운다.
typedef OpenUrl = Future<bool> Function(Uri url);

/// 사용자에게는 상세 오류·스택을 보여주지 않는다 (SPEC §9·§10).
String errorMessage(Object error) {
  if (error is RepositoryException) {
    return switch (error.kind) {
      RepositoryErrorKind.unauthenticated => '다시 로그인해 주세요.',
      RepositoryErrorKind.permissionDenied => '볼 수 있는 권한이 없어요.',
      RepositoryErrorKind.notFound => '공고를 찾을 수 없어요.',
      _ => '잠시 후 다시 시도해 주세요.',
    };
  }
  return '잠시 후 다시 시도해 주세요.';
}

class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.icon, required this.message, this.onRetry});

  final IconData icon;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: onRetry, child: const Text('다시 시도')),
            ],
          ],
        ),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, this.warning = false});

  final String label;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: warning ? scheme.tertiaryContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: warning ? scheme.onTertiaryContainer : scheme.onSecondaryContainer),
      ),
    );
  }
}
