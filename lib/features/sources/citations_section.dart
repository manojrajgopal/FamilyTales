import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/widgets/widgets.dart';
import 'source_widgets.dart';

enum _RowAction { open, edit, remove }

/// Shows the sources cited for an entity (person, event, partnership) with
/// an "Add source" action. [entityType] is 'person' | 'event' | 'partnership'.
///
/// Empty state is a single subtle "No sources yet · Add" row so it never
/// dominates a profile.
class CitationsSection extends ConsumerWidget {
  const CitationsSection({super.key, required this.entityType, required this.entityId});
  final String entityType;
  final String entityId;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final sourceId = await pickOrCreateSource(context, title: 'Cite a source');
    if (sourceId == null || !context.mounted) return;
    final draft = await showCitationForm(context, entityType: entityType);
    if (draft == null || !context.mounted) return;
    try {
      await ref.read(contentRepoProvider).addCitation(
            sourceId: sourceId,
            entityType: entityType,
            entityId: entityId,
            fact: draft.fact,
            detail: draft.detail,
            confidence: draft.confidence,
          );
      if (context.mounted) showFTToast(context, 'Source cited');
    } catch (e) {
      if (context.mounted) showFTToast(context, friendlyError(e), error: true);
    }
  }

  Future<void> _actions(BuildContext context, WidgetRef ref, Citation c, Source s) async {
    final a = await showFTOptions<_RowAction>(
      context,
      title: s.title,
      options: const [
        FTOption(_RowAction.open, 'Open source', icon: AppIcons.arrowUpRight),
        FTOption(_RowAction.edit, 'Edit citation', icon: AppIcons.edit, subtitle: 'Fact, detail and confidence'),
        FTOption(_RowAction.remove, 'Remove citation', icon: AppIcons.trash, danger: true),
      ],
    );
    if (a == null || !context.mounted) return;
    switch (a) {
      case _RowAction.open:
        context.push(Routes.source(s.id));
      case _RowAction.edit:
        await editCitationFlow(context, ref, c);
      case _RowAction.remove:
        await removeCitationFlow(context, ref, c);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = {for (final s in ref.watch(sourcesProvider).value ?? const <Source>[]) s.id: s};
    final cited = [
      for (final c in ref.watch(citationsProvider).value ?? const <Citation>[])
        if (c.entityType == entityType && c.entityId == entityId && sources.containsKey(c.sourceId)) c,
    ]..sort((a, b) => b.confidence.compareTo(a.confidence));
    final c = context.ft;

    if (cited.isEmpty) {
      return FTPill(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
        onTap: () => _add(context, ref),
        semanticLabel: 'No sources yet. Add a source',
        child: Row(
          children: [
            const IconBadge(icon: AppIcons.source, size: 34),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text('No sources yet',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.caption.copyWith(color: c.text2)),
            ),
            ExcludeSemantics(child: FTTextAction('Add', accent: true, onTap: () => _add(context, ref))),
            const SizedBox(width: 8),
          ],
        ),
      );
    }

    return FTCard(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const IconBadge(icon: AppIcons.source, size: 34),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text('Sources · ${cited.length}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.section),
              ),
              FTTextAction('Add source', accent: true, onTap: () => _add(context, ref)),
              const SizedBox(width: Gap.xs),
            ],
          ),
          const SizedBox(height: Gap.xxs),
          for (final cit in cited)
            _CitationRow(
              citation: cit,
              source: sources[cit.sourceId]!,
              onTap: () => context.push(Routes.source(cit.sourceId)),
              onLongPress: () => _actions(context, ref, cit, sources[cit.sourceId]!),
            ),
        ],
      ),
    );
  }
}

class _CitationRow extends StatelessWidget {
  const _CitationRow({required this.citation, required this.source, required this.onTap, required this.onLongPress});
  final Citation citation;
  final Source source;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final summary = citationSummary(citation);
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      scale: 0.985,
      semanticLabel: '${source.title}, $summary, ${confidenceLabel(citation.confidence)}. Long press for options',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
          child: Row(
            children: [
              SizedBox(
                width: 34,
                child: Icon(AppIcons.forSource(source.type), size: 18, color: c.text3),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(source.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                    const SizedBox(height: 2),
                    Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.caption),
                  ],
                ),
              ),
              const SizedBox(width: Gap.sm),
              ConfidenceDots(citation.confidence),
              const SizedBox(width: Gap.xs),
              Icon(AppIcons.forward, size: 16, color: c.text3),
            ],
          ),
        ),
      ),
    );
  }
}
