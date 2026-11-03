import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/app_shell.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/widgets/widgets.dart';

/// The "More" tab: every secondary feature, grouped as premium tiles.
class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tree = ref.watch(activeTreeProvider);
    final pad = context.pagePadding;
    final groups = <(String, List<(IconData, String, String)>)>[
      ('Explore', [
        (AppIcons.calendar, 'Calendar', Routes.calendar),
        (AppIcons.event, 'Events', Routes.events),
        (AppIcons.photos, 'Gallery', Routes.gallery),
        (AppIcons.story, 'Stories', Routes.stories),
        (AppIcons.search, 'Search', Routes.search),
        (AppIcons.path, 'Relationship finder', Routes.relationshipFinder),
      ]),
      ('Family history', [
        (AppIcons.branch, 'Branches', Routes.branches),
        (AppIcons.stats, 'Insights', Routes.insights),
        (AppIcons.source, 'Sources', Routes.sources),
        (AppIcons.duplicate, 'Duplicates', Routes.duplicates),
        (AppIcons.fields, 'Custom fields', Routes.customFields),
        (AppIcons.tree, 'Family trees', Routes.trees),
      ]),
      ('Your data', [
        (AppIcons.backup, 'Backup & restore', Routes.backup),
        (AppIcons.export, 'Export', Routes.export),
        (AppIcons.download, 'Import GEDCOM', Routes.gedcomImport),
        (AppIcons.storage, 'Storage', Routes.storage),
        (AppIcons.trash, 'Trash', Routes.trash),
        (AppIcons.settings, 'Settings', Routes.settings),
      ]),
    ];
    return FTPage(
      showBack: false,
      body: ListView(
        padding: EdgeInsets.fromLTRB(pad, 4, pad, AppShell.contentInset(context)),
        children: [
          ContentWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('More', style: context.tx.headline),
                          Text(tree?.name ?? 'Family Tales', style: context.tx.caption),
                        ],
                      ),
                    ),
                    FTIconButton(icon: AppIcons.settings, tooltip: 'Settings', onTap: () => context.push(Routes.settings)),
                  ],
                ),
                const SizedBox(height: Gap.lg),
                FadeSlideIn(
                  child: FTCard(
                    onTap: () => context.push(Routes.backup),
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: [
                        const IconBadge(icon: AppIcons.shield, accent: true, size: 48),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Private & offline', style: context.tx.section),
                              const SizedBox(height: 2),
                              Text(_backupLine(ref), style: context.tx.caption),
                            ],
                          ),
                        ),
                        Icon(AppIcons.forward, color: context.ft.text3, size: 18),
                      ],
                    ),
                  ),
                ),
                for (var gi = 0; gi < groups.length; gi++) ...[
                  const SizedBox(height: Gap.xl),
                  SectionHeader(groups[gi].$1),
                  LayoutBuilder(builder: (context, cons) {
                    final cols = cons.maxWidth >= 640 ? 4 : 3;
                    final w = (cons.maxWidth - (cols - 1) * 10) / cols;
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (var i = 0; i < groups[gi].$2.length; i++)
                          FadeSlideIn(
                            index: gi * 2 + i ~/ 3,
                            child: FTCard(
                              width: w,
                              height: w * 0.84 < 100 ? 100 : w * 0.84,
                              radius: 22,
                              padding: const EdgeInsets.all(12),
                              onTap: () => context.push(groups[gi].$2[i].$3),
                              semanticLabel: groups[gi].$2[i].$2,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  IconBadge(icon: groups[gi].$2[i].$1, size: 38),
                                  const Spacer(),
                                  Text(
                                    groups[gi].$2[i].$2,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.tx.label.copyWith(fontSize: 12.5, height: 1.2),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                  }),
                ],
                const SizedBox(height: Gap.xl),
                Center(child: FTTextAction('About Family Tales', onTap: () => context.push(Routes.about))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _backupLine(WidgetRef ref) {
    final last = ref.watch(settingsProvider.select((s) => s.lastBackupAt));
    if (last == null) return 'Everything stays on this device. No backup yet – create one to keep your history safe.';
    final days = DateTime.now().difference(last).inDays;
    return 'Last backup ${days == 0 ? 'today' : '$days ${days == 1 ? 'day' : 'days'} ago'} · stored only where you choose.';
  }
}
