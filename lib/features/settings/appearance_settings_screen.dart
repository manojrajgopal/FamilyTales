import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/settings.dart';
import '../../core/widgets/widgets.dart';
import 'settings_logic.dart';
import 'widgets/settings_widgets.dart';

/// Theme, accent colour, text size and motion. Every change applies live.
class AppearanceSettingsScreen extends ConsumerStatefulWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  ConsumerState<AppearanceSettingsScreen> createState() => _AppearanceSettingsScreenState();
}

class _AppearanceSettingsScreenState extends ConsumerState<AppearanceSettingsScreen> {
  static const _minScale = 0.85;
  static const _maxScale = 1.3;

  /// Slider value while dragging; persisted when the drag ends so the
  /// database is not written on every frame.
  double? _dragScale;

  Future<void> _update(AppPrefs Function(AppPrefs p) change) async {
    try {
      await ref.read(settingsProvider.notifier).update(change);
    } catch (e) {
      if (mounted) showFTToast(context, 'Couldn’t save that setting. ${friendlyError(e)}', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(settingsProvider);
    final scale = (_dragScale ?? prefs.textScale).clamp(_minScale, _maxScale);
    final c = context.ft;

    return FTPage(
      title: 'Appearance',
      body: SettingsBody(
        children: [
          SettingsGroup(
            title: 'Theme',
            divided: false,
            children: [
              _ThemePreview(
                mode: prefs.themeMode,
                accent: prefs.accent,
                onSelect: (m) => _update((p) => p.copyWith(themeMode: m)),
              ),
              FTSegmented<ThemeMode>(
                values: const [ThemeMode.system, ThemeMode.light, ThemeMode.dark],
                selected: prefs.themeMode,
                labelOf: themeModeLabel,
                onChanged: (m) => _update((p) => p.copyWith(themeMode: m)),
              ),
              Text(
                switch (prefs.themeMode) {
                  ThemeMode.dark => 'Graphite surfaces, easy on the eyes at night.',
                  ThemeMode.light => 'Bright, paper-like surfaces for daylight.',
                  ThemeMode.system =>
                    'Follows your device (currently ${MediaQuery.platformBrightnessOf(context) == Brightness.dark ? 'dark' : 'light'}).',
                },
                style: context.tx.caption,
              ),
            ],
          ),
          SettingsGroup(
            title: 'Accent colour',
            divided: false,
            children: [
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.md,
                children: [
                  for (final a in AccentChoice.values)
                    _AccentSwatch(
                      choice: a,
                      selected: a == prefs.accent,
                      onTap: () => _update((p) => p.copyWith(accent: a)),
                    ),
                ],
              ),
              Text('Used sparingly for selections and primary actions.',
                  style: context.tx.caption),
            ],
          ),
          SettingsGroup(
            title: 'Text size',
            divided: false,
            trailing: scale == 1.0
                ? null
                : FTTextAction('Reset', accent: true, onTap: () {
                    setState(() => _dragScale = null);
                    _update((p) => p.copyWith(textScale: 1.0));
                  }),
            children: [
              Row(
                children: [
                  ExcludeSemantics(child: Icon(AppIcons.textSize, size: 16, color: c.text3)),
                  Expanded(
                    child: Slider(
                      value: scale,
                      min: _minScale,
                      max: _maxScale,
                      divisions: 9,
                      label: '${(scale * 100).round()}%',
                      semanticFormatterCallback: (v) => 'Text size ${(v * 100).round()} percent',
                      onChanged: (v) => setState(() => _dragScale = v),
                      onChangeEnd: (v) async {
                        await _update((p) => p.copyWith(textScale: v));
                        if (mounted) setState(() => _dragScale = null);
                      },
                    ),
                  ),
                  ExcludeSemantics(child: Icon(AppIcons.textSize, size: 26, color: c.text3)),
                ],
              ),
              _TextSample(scale: scale, savedScale: prefs.textScale),
            ],
          ),
          SettingsGroup(
            title: 'Screen & motion',
            children: [
              FTSwitchRow(
                icon: AppIcons.fit,
                title: 'Full screen',
                subtitle: 'Hides the status and navigation bars. Swipe from an edge to show them.',
                value: prefs.fullScreen,
                onChanged: (v) => _update((p) => p.copyWith(fullScreen: v)),
              ),
              FTSwitchRow(
                icon: AppIcons.sparkle,
                title: 'Reduce motion',
                subtitle: 'Turns off entrance animations and screen transitions',
                value: prefs.reduceMotion,
                onChanged: (v) => _update((p) => p.copyWith(reduceMotion: v)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Live text sample rendered at the slider's scale (on top of the system
/// accessibility size), independent of the currently saved value.
class _TextSample extends StatelessWidget {
  const _TextSample({required this.scale, required this.savedScale});
  final double scale;
  final double savedScale;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final mq = MediaQuery.of(context);
    final current = mq.textScaler.scale(14) / 14;
    final system = savedScale <= 0 ? current : current / savedScale;
    final preview = (system * scale).clamp(0.85, 1.6);
    return Semantics(
      label: 'Sample text at ${(scale * 100).round()} percent',
      child: Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: c.isDark ? Colors.white.withValues(alpha: 0.035) : c.surfaceHigh,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: c.border),
        ),
        child: MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(preview)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Rosa Almeida', style: context.tx.title),
              const SizedBox(height: 2),
              Text('Born 12 March 1932 · Porto', style: context.tx.caption),
              const SizedBox(height: Gap.xs),
              Text(
                'She kept every letter her brothers sent from sea and read them '
                'aloud to the grandchildren each winter.',
                style: context.tx.body,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two miniature screens (light and dark) drawn with the real palette.
/// The active one is outlined; tapping one selects that theme.
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.mode, required this.accent, required this.onSelect});
  final ThemeMode mode;
  final AccentChoice accent;
  final ValueChanged<ThemeMode> onSelect;

  @override
  Widget build(BuildContext context) {
    final platformDark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final effectiveDark = switch (mode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => platformDark,
    };
    return Row(
      children: [
        Expanded(
          child: _MiniScreen(
            colors: FTColors.light(accent),
            label: 'Light',
            selected: !effectiveDark,
            auto: mode == ThemeMode.system && !platformDark,
            onTap: () => onSelect(ThemeMode.light),
          ),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: _MiniScreen(
            colors: FTColors.dark(accent),
            label: 'Dark',
            selected: effectiveDark,
            auto: mode == ThemeMode.system && platformDark,
            onTap: () => onSelect(ThemeMode.dark),
          ),
        ),
      ],
    );
  }
}

class _MiniScreen extends StatelessWidget {
  const _MiniScreen({
    required this.colors,
    required this.label,
    required this.selected,
    required this.auto,
    required this.onTap,
  });

  final FTColors colors;
  final String label;
  final bool selected;
  final bool auto;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final app = context.ft;
    final k = colors;
    Widget bar(double widthFactor, double height, Color color) => FractionallySizedBox(
          widthFactor: widthFactor,
          alignment: Alignment.centerLeft,
          child: Container(
            height: height,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(height)),
          ),
        );
    Widget dot(double size, Gradient g) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: g,
            border: Border.all(color: k.border),
          ),
        );

    final screen = AnimatedContainer(
      duration: context.reduceMotion ? Duration.zero : Motion.medium,
      height: 172,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.md),
        gradient: RadialGradient(
          center: const Alignment(-0.7, -1.1),
          radius: 1.3,
          colors: [k.glow, k.bg0],
        ),
        border: Border.all(
          color: selected ? app.accent : app.border,
          width: selected ? 1.8 : 1,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: app.accent.withValues(alpha: 0.22),
                  blurRadius: 18,
                  spreadRadius: -4,
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              dot(16, k.chipGradient),
              const SizedBox(width: 8),
              Expanded(child: Center(child: bar(0.6, 6, k.text.withValues(alpha: 0.7)))),
              const SizedBox(width: 8),
              dot(16, k.chipGradient),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: k.cardGradient,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: k.border),
              boxShadow: [
                BoxShadow(
                  color: k.shadow.withValues(alpha: k.isDark ? 0.6 : 0.12),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    dot(18, k.chipGradient),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          bar(0.8, 5, k.text.withValues(alpha: 0.85)),
                          const SizedBox(height: 4),
                          bar(0.5, 4, k.text3.withValues(alpha: 0.8)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  width: 38,
                  height: 12,
                  decoration: BoxDecoration(
                    gradient: k.accentGradient,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          Container(
            height: 20,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              gradient: k.cardGradient,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: k.border),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Container(
                  width: 28,
                  height: 12,
                  decoration: BoxDecoration(
                    gradient: k.accentGradient,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                for (var i = 0; i < 3; i++)
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: k.text3.withValues(alpha: 0.8),
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    return Pressable(
      onTap: onTap,
      semanticLabel: '$label theme${selected ? ', selected' : ''}',
      child: Column(
        children: [
          ExcludeSemantics(child: screen),
          const SizedBox(height: Gap.xs),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (selected) ...[
                Icon(AppIcons.checkCircle, size: 16, color: app.accent),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  auto ? '$label · Auto' : label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.tx.label.copyWith(color: selected ? app.text : app.text3),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Circular accent swatch with a ring when selected.
class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({required this.choice, required this.selected, required this.onTap});
  final AccentChoice choice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final ring = c.isDark ? choice.primary : choice.onLight;
    return Semantics(
      selected: selected,
      child: Tooltip(
        message: '${choice.label} accent',
        excludeFromSemantics: true,
        child: Pressable(
          onTap: onTap,
          semanticLabel: '${choice.label} accent',
          scale: 0.92,
          child: SizedBox(
            width: 64,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: context.reduceMotion ? Duration.zero : Motion.fast,
                  width: 56,
                  height: 56,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? ring : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [choice.highlight, choice.primary, choice.secondary],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: choice.primary.withValues(alpha: selected ? 0.40 : 0.18),
                          blurRadius: selected ? 16 : 10,
                          spreadRadius: -2,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: selected
                        ? const Icon(AppIcons.check, size: 20, color: Color(0xFF0B0C0F))
                        : null,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  choice.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: context.tx.caption.copyWith(
                    color: selected ? c.text : c.text3,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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
