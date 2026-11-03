import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import 'source_widgets.dart';

/// Evidence library: sources grouped by type, searchable, with citation
/// counts.
class SourcesScreen extends ConsumerStatefulWidget {
  const SourcesScreen({super.key});

  @override
  ConsumerState<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends ConsumerState<SourcesScreen> {
  final _search = TextEditingController();
  String _q = '';
  SourceType? _type;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final id = await showSourceForm(context);
    if (id != null && mounted) {
      showFTToast(context, 'Source added');
      context.push(Routes.source(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(sourcesProvider);
    final pad = context.pagePadding;
    final hasAny = async.value?.isNotEmpty ?? false;
    return FTPage(
      title: 'Sources',
      actions: [FTIconButton(icon: AppIcons.add, tooltip: 'Add source', accent: true, onTap: _add)],
      headerBottom: hasAny
          ? Padding(
              padding: EdgeInsets.fromLTRB(pad, Gap.xxs, pad, Gap.sm),
              child: ContentWidth(
                child: FTSearchField(
                  controller: _search,
                  hint: 'Search title, author, archive',
                  onChanged: (v) => setState(() => _q = v),
                ),
              ),
            )
          : null,
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e),
        data: (sources) {
          if (sources.isEmpty) {
            return EmptyState(
              icon: AppIcons.source,
              title: 'No sources yet',
              message:
                  'Record the evidence behind your family history – certificates, letters, census records and oral histories.',
              actionLabel: 'Add source',
              onAction: _add,
            );
          }
          final graph = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
          final events = {for (final e in ref.watch(eventsProvider).value ?? const <FamilyEvent>[]) e.id: e};
          final counts = <String, int>{};
          for (final c in ref.watch(citationsProvider).value ?? const <Citation>[]) {
            if (CitationTarget.resolve(c, graph, events) != null) {
              counts[c.sourceId] = (counts[c.sourceId] ?? 0) + 1;
            }
          }
          final q = _q.trim().toLowerCase();
          final usedTypes = [
            for (final t in SourceType.values)
              if (sources.any((s) => s.type == t)) t,
          ];
          final filtered = [
            for (final s in sources)
              if ((_type == null || s.type == _type) &&
                  (q.isEmpty ||
                      '${s.title} ${s.author ?? ''} ${s.repository ?? ''} ${s.notes ?? ''} ${s.type.label}'
                          .toLowerCase()
                          .contains(q)))
                s,
          ];
          // Flatten into type headers + rows, grouped in enum order.
          final rows = <Object>[];
          for (final t in SourceType.values) {
            final group = [for (final s in filtered) if (s.type == t) s];
            if (group.isEmpty) continue;
            rows.add(t);
            rows.addAll(group);
          }
          return ListView.builder(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, FTPage.bottomInset(context)),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            itemCount: 1 + (rows.isEmpty ? 1 : rows.length),
            itemBuilder: (context, i) {
              if (i == 0) {
                if (usedTypes.length < 2) return const SizedBox(height: Gap.xs);
                return Padding(
                  padding: const EdgeInsets.only(bottom: Gap.sm),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    child: Row(
                      children: [
                        FTChip(label: 'All', selected: _type == null, onTap: () => setState(() => _type = null)),
                        for (final t in usedTypes) ...[
                          const SizedBox(width: Gap.xs),
                          FTChip(
                            label: t.label,
                            icon: AppIcons.forSource(t),
                            selected: _type == t,
                            onTap: () => setState(() => _type = _type == t ? null : t),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }
              if (rows.isEmpty) {
                return const EmptyState(
                  icon: AppIcons.search,
                  title: 'No matching sources',
                  message: 'Try another search or type.',
                  compact: true,
                );
              }
              final row = rows[i - 1];
              if (row is SourceType) {
                return ContentWidth(
                  child: Padding(
                    padding: EdgeInsets.only(top: i == 1 ? Gap.xs : Gap.lg, bottom: Gap.xs),
                    child: Row(
                      children: [
                        Icon(AppIcons.forSource(row), size: 16, color: context.ft.accent),
                        const SizedBox(width: Gap.xs),
                        Expanded(child: SectionHeader(row.label)),
                      ],
                    ),
                  ),
                );
              }
              final s = row as Source;
              return ContentWidth(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: Gap.sm),
                  child: FadeSlideIn(
                    index: i,
                    child: SourceCard(
                      source: s,
                      citations: counts[s.id] ?? 0,
                      onTap: () => context.push(Routes.source(s.id)),
                      onLongPress: () => showSourceForm(context, existing: s),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Source row card: type badge, title, author · date · archive, citation
/// count.
class SourceCard extends StatelessWidget {
  const SourceCard({super.key, required this.source, required this.citations, this.onTap, this.onLongPress});
  final Source source;
  final int citations;
  final VoidCallback? onTap;

  /// Long-press opens the edit form.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final sub = sourceSubtitle(source);
    final c = context.ft;
    return FTCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: '${source.title}, $sub, cited $citations times',
      child: Row(
        children: [
          IconBadge(icon: AppIcons.forSource(source.type), size: 44),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(source.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                const SizedBox(height: 2),
                Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.caption),
              ],
            ),
          ),
          const SizedBox(width: Gap.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              FTTag(citations == 0 ? 'Not cited' : '$citations cited', accent: citations > 0),
              if (source.mediaId != null) ...[
                const SizedBox(height: 6),
                Icon(AppIcons.link, size: 15, color: c.text3, semanticLabel: 'Has attachment'),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
