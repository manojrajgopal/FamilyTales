import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/security/app_lock.dart';
import '../features/calendar/reminder_sync.dart';
import 'providers.dart';
import 'router.dart';
import 'theme/app_theme.dart';

class FamilyTalesApp extends ConsumerWidget {
  const FamilyTalesApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(settingsProvider);
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Family Tales',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      themeMode: prefs.themeMode,
      theme: AppTheme.build(dark: false, accent: prefs.accent),
      darkTheme: AppTheme.build(dark: true, accent: prefs.accent),
      themeAnimationDuration: const Duration(milliseconds: 250),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en', 'US'), Locale('en', 'GB'), Locale('en', 'IN')],
      builder: (context, child) {
        // Apply the user's text-size and motion preferences on top of the
        // system accessibility settings (clamped so layouts stay intact).
        final mq = MediaQuery.of(context);
        final systemScale = mq.textScaler.scale(14) / 14;
        final scale = (systemScale * prefs.textScale).clamp(0.85, 1.6);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: mq.disableAnimations || prefs.reduceMotion,
          ),
          child: AppLifecycleGuard(
            child: ReminderSync(child: child ?? const SizedBox.shrink()),
          ),
        );
      },
    );
  }
}
