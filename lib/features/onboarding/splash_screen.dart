import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/widgets/widgets.dart';

/// Brand splash: the emblem glows in, then routes to onboarding or home.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (context.reduceMotion) {
        _c.value = 1;
      } else {
        await _c.forward();
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
      final done = ref.read(settingsProvider).onboardingDone;
      context.go(done ? Routes.home : Routes.welcome);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Scaffold(
      backgroundColor: c.bg0,
      body: FTBackground(
        child: Center(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = Curves.easeOutCubic.transform(_c.value);
              final text = Curves.easeOut.transform(((_c.value - 0.45) / 0.55).clamp(0, 1));
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Transform.scale(
                    scale: 0.86 + 0.14 * t,
                    child: Opacity(
                      opacity: t,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: c.accent.withValues(alpha: 0.18 * t),
                              blurRadius: 60,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                        child: Image.asset('assets/branding/emblem.png', width: 168, height: 168),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Opacity(
                    opacity: text,
                    child: Transform.translate(
                      offset: Offset(0, 10 * (1 - text)),
                      child: Column(
                        children: [
                          Text('Family Tales', style: context.tx.headline),
                          const SizedBox(height: 6),
                          Text('Your family. Your story. Your roots.', style: context.tx.caption),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
