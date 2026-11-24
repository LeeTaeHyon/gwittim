import 'package:flutter/material.dart';

import 'components.dart';
import 'skeleton.dart';
import 'theme.dart';

class NoticePoster extends StatelessWidget {
  const NoticePoster({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(20);
    void open() =>
        Navigator.of(context)
            .push(gwRoute(context, (_) => _PosterViewer(url: url)));
    return Image.network(
      url,
      fit: BoxFit.contain,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
      frameBuilder: (context, image, frame, _) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        child: frame == null
            ? const GwSkeleton(child: SkeletonBox(height: 228, radius: 20))
            : Semantics(
                button: true,
                label: '포스터 크게 보기',
                onTap: open,
                excludeSemantics: true,
                child: Material(
                  color: context.gw.card,
                  borderRadius: radius,
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      Column(
                        children: [
                          Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 180),
                              child: image,
                            ),
                          ),
                          Container(
                            constraints: const BoxConstraints(minHeight: 48),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.zoom_in_rounded,
                                  size: 18,
                                  color: context.gw.sub,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '포스터 크게 보기',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: context.gw.sub,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      Positioned.fill(
                        child: Material(
                          type: MaterialType.transparency,
                          child: InkWell(onTap: open, borderRadius: radius),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _PosterViewer extends StatelessWidget {
  const _PosterViewer({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.gw.posterBackdrop,
    body: SafeArea(
      child: Stack(
        fit: StackFit.expand,
        children: [
          InteractiveViewer(
            maxScale: 5,
            child: Image.network(
              url,
              fit: BoxFit.contain,
              excludeFromSemantics: true,
              errorBuilder: (context, _, _) => Center(
                child: Text(
                  '포스터를 불러오지 못했습니다.',
                  style: TextStyle(color: context.gw.loginInk),
                ),
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 8,
            child: IconButton.filled(
              tooltip: '닫기',
              style: IconButton.styleFrom(
                backgroundColor: context.gw.posterBackdrop,
                foregroundColor: context.gw.loginInk,
              ),
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
        ],
      ),
    ),
  );
}
