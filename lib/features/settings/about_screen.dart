import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/widgets.dart';
import 'app_info.dart';
import 'widgets/settings_widgets.dart';

/// Open-source licenses grouped by package (collected once per visit).
final _licensesProvider =
    FutureProvider.autoDispose<List<PackageLicenses>>((ref) => collectLicenses());

/// Brand, version, data & privacy explanation, credits, licenses and terms.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppLicenses.ensureRegistered();
    final licenses = ref.watch(_licensesProvider);

    return FTPage(
      title: 'About',
      body: SettingsBody(
        children: [
          const _Hero(),
          const InfoCard(
            icon: AppIcons.database,
            title: 'How your data is stored',
            child: BulletPoints([
              'Your family tree is kept in a SQLite database on this device, encrypted at '
                  'rest with a key held in the device keystore.',
              'Photos and documents are copied into the app’s private storage, which other '
                  'apps can’t read.',
              'Nothing is uploaded anywhere. There is no account, no server and no cloud sync.',
              'Backups and exports are files you create and share yourself – encrypted '
                  'backups need your password to open.',
            ]),
          ),
          const InfoCard(
            icon: AppIcons.shield,
            title: 'Privacy',
            message: 'Family Tales has no analytics, advertising or tracking, and it never '
                'connects to the internet. The only time data leaves this device is when '
                'you export, back up or share it. You can lock the app with a PIN or '
                'biometrics and erase all local data at any time from Storage.',
          ),
          InfoCard(
            icon: AppIcons.heart,
            title: 'Credits',
            message: 'Family Tales is built with care on top of excellent open-source work:',
            child: const _Credits(),
          ),
          SettingsGroup(
            title: 'Open-source licenses',
            children: [
              FTListRow(
                icon: AppIcons.scroll,
                title: 'View licenses',
                subtitle: licenses.when(
                  data: (l) => '${plural(l.length, 'package')} and bundled assets',
                  loading: () => 'Collecting licenses…',
                  error: (_, _) => 'Tap to try again',
                ),
                trailing: licenses.isLoading ? const RowSpinner() : null,
                onTap: () {
                  final list = licenses.value;
                  if (list == null) {
                    ref.invalidate(_licensesProvider);
                    return;
                  }
                  _showLicenses(context, list);
                },
              ),
            ],
          ),
          const InfoCard(
            icon: AppIcons.scales,
            title: 'Terms of use',
            child: BulletPoints([
              'Family Tales is provided “as is”, without warranties of any kind.',
              'You own everything you add – your people, stories, photos and documents.',
              'Because your data lives only on your device, keeping backups is your '
                  'responsibility. We recommend backing up regularly.',
              'Please respect the privacy of living relatives when you share exports.',
            ], icon: AppIcons.arrowRight),
          ),
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(
              '${AppInfo.copyright} · Made for families everywhere',
              textAlign: TextAlign.center,
              style: context.tx.caption,
            ),
          ),
        ],
      ),
    );
  }

  static void _showLicenses(BuildContext context, List<PackageLicenses> list) {
    showFTSheet<void>(
      context,
      title: 'Open-source licenses',
      scrollable: false,
      builder: (ctx) => _LicenseList(licenses: list),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final size = (MediaQuery.sizeOf(context).width * 0.34).clamp(104.0, 148.0);
    return Column(
      children: [
        const SizedBox(height: Gap.md),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.24),
            boxShadow: [
              BoxShadow(
                color: c.accent.withValues(alpha: 0.18),
                blurRadius: 48,
                spreadRadius: 2,
              ),
              ...c.cardShadow,
            ],
          ),
          child: Image.asset(
            'assets/branding/logo_full.png',
            width: size,
            height: size,
            semanticLabel: 'Family Tales logo',
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(AppInfo.name, style: context.tx.display, textAlign: TextAlign.center),
        const SizedBox(height: Gap.xxs),
        Text(AppInfo.tagline, style: context.tx.body, textAlign: TextAlign.center),
        const SizedBox(height: Gap.sm),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: Gap.xs,
          runSpacing: Gap.xs,
          children: const [
            FTTag(AppInfo.versionLabel, accent: true),
            FTTag('Offline', icon: AppIcons.lock),
            FTTag('No account needed', icon: AppIcons.person),
          ],
        ),
      ],
    );
  }
}

class _Credits extends StatelessWidget {
  const _Credits();

  static const _items = [
    ('Flutter', 'UI toolkit by Google (BSD-3-Clause)'),
    ('Inter', 'Typeface by Rasmus Andersson (SIL Open Font License 1.1)'),
    ('Phosphor Icons', 'Icon set by Helena Zhang and Tobias Fried (MIT)'),
    ('drift & SQLite', 'Local database (MIT / public domain)'),
    ('SQLite3 Multiple Ciphers', 'Database encryption (MIT)'),
    ('Riverpod', 'State management by Remi Rousselet (MIT)'),
    ('go_router', 'Navigation (BSD-3-Clause)'),
    ('cryptography', 'PIN hashing and backup encryption (Apache-2.0)'),
    ('pdf & printing', 'Printable charts and books (Apache-2.0)'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (name, what) in _items)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.xs),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: name, style: context.tx.bodyStrong.copyWith(fontSize: 14)),
                  TextSpan(text: ' – $what', style: context.tx.body),
                ],
              ),
            ),
          ),
        Text('Full license texts are listed below.', style: context.tx.caption),
      ],
    );
  }
}

/// Searchable list of packages; tapping one opens its license text.
class _LicenseList extends StatefulWidget {
  const _LicenseList({required this.licenses});
  final List<PackageLicenses> licenses;

  @override
  State<_LicenseList> createState() => _LicenseListState();
}

class _LicenseListState extends State<_LicenseList> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final q = _q.trim().toLowerCase();
    final list = q.isEmpty
        ? widget.licenses
        : widget.licenses.where((l) => l.package.toLowerCase().contains(q)).toList();
    return SizedBox(
      height: (mq.size.height - mq.viewInsets.bottom) * 0.72,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.xl, Gap.sm),
            child: FTSearchField(
              hint: 'Search packages',
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? const EmptyState(icon: AppIcons.search, title: 'No matching packages', compact: true)
                : ListView.separated(
                    padding: EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, mq.padding.bottom + Gap.md),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const HairLine(vertical: 0),
                    itemBuilder: (context, i) {
                      final l = list[i];
                      return FTListRow(
                        title: l.package,
                        subtitle: l.texts.length == 1 ? '1 license' : '${l.texts.length} licenses',
                        onTap: () => showFTSheet<void>(
                          context,
                          title: l.package,
                          builder: (_) => _LicenseText(texts: l.texts),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _LicenseText extends StatelessWidget {
  const _LicenseText({required this.texts});
  final List<String> texts;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < texts.length; i++) ...[
          if (i > 0) const HairLine(vertical: Gap.md),
          Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: c.isDark ? Colors.white.withValues(alpha: 0.03) : c.surfaceHigh,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: c.border),
            ),
            child: SelectableText(
              texts[i],
              style: context.tx.caption.copyWith(color: c.text2, height: 1.5),
            ),
          ),
        ],
      ],
    );
  }
}
