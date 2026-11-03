import 'dart:io';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database/app_database.dart';
import '../core/repositories/system_repository.dart';
import '../core/security/secure_vault.dart';
import '../core/services/app_paths.dart';
import '../core/services/system_ui.dart';
import 'app.dart';
import 'providers.dart';
import 'settings.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

/// Opens the encrypted local database and starts the app. Nothing here
/// touches the network.
Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  await applySystemUiMode(fullScreen: true);
  SystemChrome.setSystemUIOverlayStyle(AppTheme.overlayStyle(true));

  try {
    final paths = await AppPaths.init();
    final vault = SecureVault();
    final key = await vault.databaseKey();
    final db = AppDatabase.open(paths.databaseFile, key: key);
    // Fails here (instead of later) if the key does not match the file.
    await db.customSelect('SELECT 1').get();
    final system = SystemRepository(db);
    final prefs = AppPrefs.fromMap(await system.loadSettings());
    await applySystemUiMode(fullScreen: prefs.fullScreen);
    unawaited(system.autoPurge(days: prefs.trashRetentionDays));

    runApp(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        initialPrefsProvider.overrideWithValue(prefs),
        vaultProvider.overrideWithValue(vault),
      ],
      child: const FamilyTalesApp(),
    ));
  } catch (e, st) {
    debugPrint('Startup failed: $e\n$st');
    runApp(StartupErrorApp(error: e));
  }
}

/// Shown if the database cannot be opened (e.g. the keystore entry was
/// lost). Offers a clean reset; existing files are never touched silently.
class StartupErrorApp extends StatefulWidget {
  const StartupErrorApp({super.key, required this.error});
  final Object error;

  @override
  State<StartupErrorApp> createState() => _StartupErrorAppState();
}

class _StartupErrorAppState extends State<StartupErrorApp> {
  bool _confirm = false;

  Future<void> _reset() async {
    final paths = AppPaths.I;
    final f = paths.databaseFile;
    for (final p in [f.path, '${f.path}-wal', '${f.path}-shm']) {
      try {
        await File(p).delete();
      } catch (_) {}
    }
    await SecureVault().deleteDatabaseKey();
    await bootstrap();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(dark: true, accent: AccentChoice.mint),
      home: Builder(builder: (context) {
        final c = context.ft;
        return Scaffold(
          backgroundColor: c.bg0,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Spacer(),
                  Image.asset('assets/branding/emblem.png', width: 88),
                  const SizedBox(height: 24),
                  Text('We couldn’t open your family data', style: context.tx.headline),
                  const SizedBox(height: 12),
                  Text(
                    'The encrypted database on this device could not be unlocked. '
                    'This can happen if the device keystore was reset. Your data has not been changed.\n\n'
                    'If you have a Family Tales backup (.ftbackup), you can reset the app and restore it.',
                    style: context.tx.body,
                  ),
                  const SizedBox(height: 12),
                  Text('Details: ${widget.error}', style: context.tx.caption, maxLines: 4),
                  const Spacer(),
                  if (_confirm)
                    Text('This permanently deletes the local database on this device.',
                        style: context.tx.label.copyWith(color: c.danger)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: _confirm ? c.danger : c.accent,
                        foregroundColor: c.onAccent,
                        minimumSize: const Size.fromHeight(54),
                        shape: const StadiumBorder(),
                      ),
                      onPressed: () => _confirm ? _reset() : setState(() => _confirm = true),
                      child: Text(_confirm ? 'Delete local data and start fresh' : 'Reset app'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}
