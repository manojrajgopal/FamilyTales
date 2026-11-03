import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/services/app_paths.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../gallery/media_tools.dart';
import '../gallery/media_widgets.dart';
import '../members/widgets/person_widgets.dart';
import 'source_widgets.dart';

enum _SourceAction { share, delete }

enum _TargetKind { person, couple, event }

enum _CitationAction { open, edit, remove }

/// One source: details, attached file, and the facts it supports.
class SourceDetailScreen extends ConsumerWidget {
  const SourceDetailScreen({super.key, required this.sourceId});
  final String sourceId;

  Future<void> _addCitation(BuildContext context, WidgetRef ref, Source s) async {
    final kind = await showFTOptions<_TargetKind>(
      context,
      title: 'What does it support?',
      options: const [
        FTOption(_TargetKind.person, 'A person’s facts',
            icon: AppIcons.person, subtitle: 'Name, birth, death or other facts'),
        FTOption(_TargetKind.couple, 'A marriage or partnership', icon: AppIcons.heart),
        FTOption(_TargetKind.event, 'An event', icon: AppIcons.event),
      ],
    );
    if (kind == null || !context.mounted) return;
    final graph = ref.read(familyGraphProvider).value ?? FamilyGraph.empty();
    String entityType;
    String? entityId;
    String? label;
    switch (kind) {
      case _TargetKind.person:
        entityType = 'person';
        entityId = await pickPerson(context, title: 'Evidence about…');
        label = entityId == null ? null : graph[entityId]?.displayName;
      case _TargetKind.couple:
        entityType = 'partnership';
        final pid = await pickPerson(context, title: 'One of the partners');
        if (pid == null || !context.mounted) return;
        final couples = graph.partnershipsOf(pid);
        if (couples.isEmpty) {
          showFTToast(context, '${graph[pid]?.displayName ?? 'This person'} has no partner recorded yet.', error: true);
          return;
        }
        Partnership? chosen = couples.length == 1 ? couples.first : null;
        if (chosen == null) {
          final id = await showFTOptions<String>(
            context,
            title: 'Which partnership?',
            options: [
              for (final c in couples)
                FTOption(
                  c.id,
                  graph[c.personAId == pid ? c.personBId : c.personAId]?.displayName ?? 'Partner',
                  icon: AppIcons.heart,
                  subtitle: c.type.label,
                ),
            ],
          );
          for (final c in couples) {
            if (c.id == id) chosen = c;
          }
        }
        if (chosen == null) return;
        entityId = chosen.id;
        label = '${graph[chosen.personAId]?.shortName} & ${graph[chosen.personBId]?.shortName}';
      case _TargetKind.event:
        entityType = 'event';
        entityId = await pickEvent(context, title: 'Evidence for which event?');
        if (entityId != null) {
          for (final e in ref.read(eventsProvider).value ?? const <FamilyEvent>[]) {
            if (e.id == entityId) label = e.title;
          }
        }
    }
    if (entityId == null || !context.mounted) return;
    final draft = await showCitationForm(context, entityType: entityType, subjectLabel: label);
    if (draft == null || !context.mounted) return;
    try {
      await ref.read(contentRepoProvider).addCitation(
            sourceId: s.id,
            entityType: entityType,
            entityId: entityId,
            fact: draft.fact,
            detail: draft.detail,
            confidence: draft.confidence,
          );
      if (context.mounted) showFTToast(context, 'Citation added');
    } catch (e) {
      if (context.mounted) showFTToast(context, friendlyError(e), error: true);
    }
  }

  Future<void> _citationActions(BuildContext context, WidgetRef ref, Citation c, CitationTarget t) async {
    final a = await showFTOptions<_CitationAction>(
      context,
      title: t.label,
      options: [
        FTOption(_CitationAction.open, t.kind == 'event' ? 'Open event' : 'Open profile', icon: AppIcons.arrowUpRight),
        const FTOption(_CitationAction.edit, 'Edit citation', icon: AppIcons.edit),
        const FTOption(_CitationAction.remove, 'Remove citation', icon: AppIcons.trash, danger: true),
      ],
    );
    if (a == null || !context.mounted) return;
    switch (a) {
      case _CitationAction.open:
        _open(context, t);
      case _CitationAction.edit:
        await editCitationFlow(context, ref, c, subjectLabel: t.label);
      case _CitationAction.remove:
        await removeCitationFlow(context, ref, c, subjectLabel: t.label);
    }
  }

  void _open(BuildContext context, CitationTarget t) {
    final id = t.route;
    if (id == null) return;
    context.push(t.kind == 'event' ? Routes.event(id) : Routes.person(id));
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Source s, int citations) async {
    final ok = await showFTConfirm(
      context,
      title: 'Move source to trash?',
      message: citations == 0
          ? '“${s.title}” moves to the trash. You can restore it from there.'
          : '“${s.title}” moves to the trash. Its $citations ${citations == 1 ? 'citation is' : 'citations are'} hidden until you restore it. People and events are not changed.',
      confirmLabel: 'Move to trash',
      destructive: true,
      icon: AppIcons.trash,
    );
    if (!ok || !context.mounted) return;
    final repo = ref.read(contentRepoProvider);
    final done = await trashWithUndo(
      context,
      ref,
      type: TrashEntity.source,
      id: s.id,
      trash: () => repo.trashSource(s.id),
      message: 'Source moved to trash',
    );
    if (done && context.mounted) context.pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sourcesProvider);
    Source? source;
    for (final s in async.value ?? const <Source>[]) {
      if (s.id == sourceId) source = s;
    }
    if (source == null) {
      return FTPage(
        title: 'Source',
        body: async.isLoading
            ? const LoadingView()
            : (async.hasError
                ? ErrorView(error: async.error!)
                : const EmptyState(
                    icon: AppIcons.source,
                    title: 'Source not found',
                    message: 'It may have been moved to the trash.',
                  )),
      );
    }
    final s = source;
    final graph = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final events = {for (final e in ref.watch(eventsProvider).value ?? const <FamilyEvent>[]) e.id: e};
    final cited = <(Citation, CitationTarget)>[
      for (final c in ref.watch(citationsProvider).value ?? const <Citation>[])
        if (c.sourceId == s.id)
          if (CitationTarget.resolve(c, graph, events) case final t?) (c, t),
    ]..sort((a, b) => a.$2.label.toLowerCase().compareTo(b.$2.label.toLowerCase()));
    final media = s.mediaId == null ? null : ref.watch(mediaByIdProvider)[s.mediaId];
    final pad = context.pagePadding;
    final c = context.ft;
    final date = FuzzyDate.tryParse(s.date)?.format(long: true);
    final notes = s.notes?.trim() ?? '';

    Widget detail(IconData icon, String label, String value) => Padding(
          padding: const EdgeInsets.only(top: Gap.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: c.text3),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: context.tx.caption),
                    Text(value, style: context.tx.bodyStrong.copyWith(fontWeight: FontWeight.w400)),
                  ],
                ),
              ),
            ],
          ),
        );

    return FTPage(
      title: 'Source',
      actions: [
        FTIconButton(
          icon: AppIcons.edit,
          tooltip: 'Edit source',
          onTap: () async {
            final id = await showSourceForm(context, existing: s);
            if (id != null && context.mounted) showFTToast(context, 'Source updated');
          },
        ),
        Builder(
          builder: (bctx) => FTIconButton(
            icon: AppIcons.moreHoriz,
            tooltip: 'More actions',
            onTap: () async {
              final a = await showFTOptions<_SourceAction>(
                context,
                title: s.title,
                options: [
                  if (media != null) const FTOption(_SourceAction.share, 'Share attached file', icon: AppIcons.share),
                  const FTOption(_SourceAction.delete, 'Move to trash', icon: AppIcons.trash, danger: true),
                ],
              );
              if (a == null || !context.mounted) return;
              switch (a) {
                case _SourceAction.share:
                  if (media != null && bctx.mounted) await shareMediaFile(bctx, media);
                case _SourceAction.delete:
                  await _delete(context, ref, s, cited.length);
              }
            },
          ),
        ),
      ],
      body: ListView(
        padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, FTPage.bottomInset(context)),
        children: [
          ContentWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FTCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          IconBadge(icon: AppIcons.forSource(s.type), size: 52, accent: true),
                          const Spacer(),
                          FTTag(cited.isEmpty ? 'Not cited yet' : 'Supports ${cited.length}',
                              accent: cited.isNotEmpty, icon: AppIcons.source),
                        ],
                      ),
                      const SizedBox(height: Gap.md),
                      Text(s.title, style: context.tx.headline),
                      const SizedBox(height: 2),
                      Text(s.type.label, style: context.tx.caption.copyWith(color: c.accent)),
                      if ((s.author ?? '').trim().isNotEmpty) detail(AppIcons.person, 'Author / informant', s.author!.trim()),
                      if ((s.repository ?? '').trim().isNotEmpty)
                        detail(AppIcons.archive, 'Repository / location', s.repository!.trim()),
                      if (date != null) detail(AppIcons.calendarBlank, 'Date', date),
                      if (notes.isNotEmpty) ...[
                        const HairLine(vertical: Gap.md),
                        SelectableText(notes, style: context.tx.body),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: Gap.xl),
                const SectionHeader('Attached copy'),
                if (media != null)
                  FTCard(
                    padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
                    onTap: media.isImage
                        ? () => context.push(Routes.media(media.id), extra: [media.id])
                        : () => shareMediaFile(context, media),
                    semanticLabel: '${media.displayTitle}, ${media.isImage ? 'open' : 'open or share'}',
                    child: Row(
                      children: [
                        SizedBox(width: 56, height: 56, child: MediaThumb(media: media, radius: Radii.sm)),
                        const SizedBox(width: Gap.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(media.displayTitle,
                                  maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                              const SizedBox(height: 2),
                              Text(
                                '${formatBytes(media.sizeBytes)} · ${media.isImage ? 'Tap to view' : 'Tap to open or share'}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: context.tx.caption,
                              ),
                            ],
                          ),
                        ),
                        Builder(
                          builder: (bctx) => FTIconButton(
                            icon: AppIcons.share,
                            tooltip: 'Share file',
                            size: 40,
                            onTap: () => shareMediaFile(bctx, media),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  FTPill(
                    padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
                    child: Row(
                      children: [
                        const IconBadge(icon: AppIcons.document, size: 34),
                        const SizedBox(width: Gap.sm),
                        Expanded(
                          child: Text('No copy attached',
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.caption),
                        ),
                        FTTextAction('Attach',
                            accent: true, onTap: () => showSourceForm(context, existing: s)),
                      ],
                    ),
                  ),
                const SizedBox(height: Gap.xl),
                SectionHeader(
                  cited.isEmpty ? 'Evidence for' : 'Evidence for · ${cited.length}',
                  action: 'Add',
                  onAction: () => _addCitation(context, ref, s),
                ),
                if (cited.isEmpty)
                  EmptyState(
                    icon: AppIcons.link,
                    title: 'Not cited yet',
                    message: 'Link this source to the facts it proves – a birth, a marriage, an event.',
                    actionLabel: 'Add citation',
                    onAction: () => _addCitation(context, ref, s),
                    compact: true,
                  )
                else
                  for (var i = 0; i < cited.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Gap.sm),
                      child: FadeSlideIn(
                        index: i,
                        child: _CitationCard(
                          citation: cited[i].$1,
                          target: cited[i].$2,
                          onTap: () => _open(context, cited[i].$2),
                          onMore: () => _citationActions(context, ref, cited[i].$1, cited[i].$2),
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CitationCard extends StatelessWidget {
  const _CitationCard({required this.citation, required this.target, required this.onTap, required this.onMore});
  final Citation citation;
  final CitationTarget target;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final leading = switch (target.kind) {
      'person' => PersonAvatarFor(target.person!, size: 42),
      'event' => IconBadge(icon: AppIcons.forEvent(target.event!.type), size: 42),
      _ => const IconBadge(icon: AppIcons.heart, size: 42),
    };
    return FTCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
      onTap: onTap,
      onLongPress: onMore,
      semanticLabel: '${target.label}, ${citationSummary(citation)}, ${confidenceLabel(citation.confidence)}',
      child: Row(
        children: [
          leading,
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(target.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                const SizedBox(height: 2),
                Text(citationSummary(citation),
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.caption),
                const SizedBox(height: 6),
                Row(
                  children: [
                    ConfidenceDots(citation.confidence),
                    const SizedBox(width: Gap.xs),
                    Flexible(
                      child: Text(confidenceLabel(citation.confidence),
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.micro),
                    ),
                  ],
                ),
              ],
            ),
          ),
          FTIconButton(icon: AppIcons.moreVert, tooltip: 'Citation options', size: 38, onTap: onMore),
        ],
      ),
    );
  }
}
