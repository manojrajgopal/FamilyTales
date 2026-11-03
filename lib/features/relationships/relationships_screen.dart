import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../members/relation_planner.dart';
import '../members/widgets/person_widgets.dart';

/// Edit the explicit connections of one person: parents (with type),
/// partners (type, status, dates) and children. Everything else is derived.
class RelationshipsScreen extends ConsumerWidget {
  const RelationshipsScreen({super.key, required this.personId});
  final String personId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = ref.watch(familyGraphProvider).value;
    if (g == null) return const FTPage(title: 'Relationships', body: LoadingView());
    final p = g[personId];
    if (p == null) {
      return const FTPage(title: 'Relationships', body: EmptyState(icon: AppIcons.person, title: 'Person not found'));
    }
    final pad = context.pagePadding;
    return FTPage(
      title: 'Relationships',
      body: ListView(
        padding: EdgeInsets.fromLTRB(pad, Gap.sm, pad, FTPage.bottomInset(context)),
        children: [
          ContentWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FTCard(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      PersonAvatarFor(p, size: 56, ring: true),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(p.displayName, style: context.tx.section),
                            const SizedBox(height: 4),
                            Text(
                              'Siblings, grandparents, cousins and in-laws are worked out automatically from these connections.',
                              style: context.tx.caption,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Gap.xl),
                _ParentsSection(person: p, graph: g),
                const SizedBox(height: Gap.xl),
                _PartnersSection(person: p, graph: g),
                const SizedBox(height: Gap.xl),
                _ChildrenSection(person: p, graph: g),
                const SizedBox(height: Gap.xl),
                FTButton.secondary(
                  label: 'How is ${p.shortName} related to…',
                  icon: AppIcons.path,
                  expand: true,
                  onTap: () => context.push(Uri(path: Routes.relationshipFinder, queryParameters: {'a': p.id}).toString()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _undoable(BuildContext context, WidgetRef ref, Future<String> Function() remove, String message) async {
  // Read before awaiting: the screen may be closed before Undo is tapped.
  final system = ref.read(systemRepoProvider);
  try {
    final rec = await remove();
    if (!context.mounted) return;
    showFTToast(context, message, actionLabel: 'Undo', onAction: () async {
      try {
        await system.restore(rec);
      } catch (_) {}
    });
  } catch (e) {
    if (context.mounted) showFTToast(context, friendlyError(e), error: true);
  }
}

Future<void> _linkExisting(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required Set<String> exclude,
  required Future<void> Function(String id) link,
}) async {
  final id = await pickPerson(context, title: title, exclude: exclude);
  if (id == null) return;
  try {
    await link(id);
    if (context.mounted) showFTToast(context, 'Relationship added');
  } catch (e) {
    if (context.mounted) showFTToast(context, friendlyError(e), error: true);
  }
}

Future<ParentType?> _pickParentType(BuildContext context, {ParentType? current}) => showFTOptions<ParentType>(
      context,
      title: 'Type of relationship',
      options: [
        for (final t in ParentType.values)
          FTOption(t, t.label, selected: t == current, subtitle: switch (t) {
            ParentType.biological => 'Birth parent',
            ParentType.adoptive => 'Legal parent through adoption',
            ParentType.step => 'Partner of a parent',
            ParentType.foster => 'Foster care',
            ParentType.guardian => 'Legal guardian',
            ParentType.unknown => 'Not sure',
          }),
      ],
    );

class _ParentsSection extends ConsumerWidget {
  const _ParentsSection({required this.person, required this.graph});
  final Person person;
  final FamilyGraph graph;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = graph;
    final repo = ref.read(familyRepoProvider);
    final links = g.parentLinksOf(person.id);
    return _Group(
      title: 'Parents',
      empty: 'No parents recorded. A person can have any number of parents of different types.',
      onAddNew: () => context.push(Routes.newPerson(relation: RelationKind.parent.name, anchorId: person.id)),
      onLink: () async {
        final type = await _pickParentType(context);
        if (type == null || !context.mounted) return;
        await _linkExisting(context, ref,
            title: 'Choose parent',
            exclude: {person.id, ...g.parentIds(person.id), ...g.descendants(person.id)},
            link: (id) => repo.addParent(childId: person.id, parentId: id, type: type));
      },
      children: [
        for (final l in links)
          if (g[l.parentId] != null)
            _RelRow(
              person: g[l.parentId]!,
              detail: l.type.label,
              onEdit: () async {
                final t = await _pickParentType(context, current: l.type);
                if (t == null) return;
                try {
                  if (t == ParentType.biological &&
                      g.parentLinksOf(person.id).where((x) => x.type == ParentType.biological && x.id != l.id).length >= 2) {
                    throw Exception('${person.shortName} already has two biological parents.');
                  }
                  await repo.updateParentLink(l.id, type: t);
                } catch (e) {
                  if (context.mounted) showFTToast(context, friendlyError(e), error: true);
                }
              },
              onRemove: () => _undoable(context, ref, () => repo.removeParentLink(l.id),
                  '${g[l.parentId]!.shortName} is no longer linked as a parent'),
            ),
      ],
    );
  }
}

class _ChildrenSection extends ConsumerWidget {
  const _ChildrenSection({required this.person, required this.graph});
  final Person person;
  final FamilyGraph graph;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = graph;
    final repo = ref.read(familyRepoProvider);
    return _Group(
      title: 'Children',
      empty: 'No children recorded.',
      onAddNew: () => context.push(Routes.newPerson(relation: RelationKind.child.name, anchorId: person.id)),
      onLink: () async {
        final type = await _pickParentType(context);
        if (type == null || !context.mounted) return;
        await _linkExisting(context, ref,
            title: 'Choose child',
            exclude: {person.id, ...g.childIds(person.id), ...g.ancestors(person.id)},
            link: (id) => repo.addParent(childId: id, parentId: person.id, type: type));
      },
      children: [
        for (final l in g.childLinksOf(person.id))
          if (g[l.childId] != null)
            _RelRow(
              person: g[l.childId]!,
              detail: l.type == ParentType.biological ? 'Child' : '${l.type.label} child',
              onEdit: () async {
                final t = await _pickParentType(context, current: l.type);
                if (t == null) return;
                try {
                  await repo.updateParentLink(l.id, type: t);
                } catch (e) {
                  if (context.mounted) showFTToast(context, friendlyError(e), error: true);
                }
              },
              onRemove: () => _undoable(context, ref, () => repo.removeParentLink(l.id),
                  '${g[l.childId]!.shortName} is no longer linked as a child'),
            ),
      ],
    );
  }
}

class _PartnersSection extends ConsumerWidget {
  const _PartnersSection({required this.person, required this.graph});
  final Person person;
  final FamilyGraph graph;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = graph;
    final repo = ref.read(familyRepoProvider);
    return _Group(
      title: 'Partners & marriages',
      empty: 'No partners recorded. Multiple marriages and past relationships are supported.',
      onAddNew: () => context.push(Routes.newPerson(relation: RelationKind.spouse.name, anchorId: person.id)),
      onLink: () => _linkExisting(context, ref,
          title: 'Choose partner',
          exclude: {person.id, ...g.ancestors(person.id), ...g.descendants(person.id)},
          link: (id) => repo.addPartnership(a: person.id, b: id)),
      children: [
        for (final s in g.partnershipsOf(person.id))
          if (g[s.personAId == person.id ? s.personBId : s.personAId] != null)
            _RelRow(
              person: g[s.personAId == person.id ? s.personBId : s.personAId]!,
              detail: [
                s.type.label,
                s.status.label,
                if (FuzzyDate.tryParse(s.startDate) != null) FuzzyDate.tryParse(s.startDate)!.format(),
              ].join(' · '),
              onEdit: () => showFTSheet<void>(
                context,
                title: 'Edit relationship',
                builder: (_) => _PartnershipEditor(partnership: s),
              ),
              onRemove: () => _undoable(context, ref, () => repo.removePartnership(s.id), 'Partnership removed'),
            ),
      ],
    );
  }
}

class _PartnershipEditor extends ConsumerStatefulWidget {
  const _PartnershipEditor({required this.partnership});
  final Partnership partnership;

  @override
  ConsumerState<_PartnershipEditor> createState() => _PartnershipEditorState();
}

class _PartnershipEditorState extends ConsumerState<_PartnershipEditor> {
  late PartnerType _type = widget.partnership.type;
  late PartnerStatus _status = widget.partnership.status;
  late FuzzyDate? _start = FuzzyDate.tryParse(widget.partnership.startDate);
  late FuzzyDate? _end = FuzzyDate.tryParse(widget.partnership.endDate);
  late final _place = TextEditingController(text: widget.partnership.place ?? '');
  late final _notes = TextEditingController(text: widget.partnership.notes ?? '');

  @override
  void dispose() {
    _place.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Type', style: context.tx.caption),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final t in PartnerType.values)
            FTChip(label: t.label, selected: _type == t, onTap: () => setState(() => _type = t)),
        ]),
        const SizedBox(height: Gap.md),
        Text('Status', style: context.tx.caption),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final s in PartnerStatus.values)
            FTChip(label: s.label, selected: _status == s, onTap: () => setState(() => _status = s)),
        ]),
        const SizedBox(height: Gap.md),
        FuzzyDateField(label: 'Start / wedding date', value: _start, onChanged: (d) => setState(() => _start = d)),
        const SizedBox(height: Gap.sm),
        if (_status != PartnerStatus.current) ...[
          FuzzyDateField(label: 'End date', value: _end, onChanged: (d) => setState(() => _end = d)),
          const SizedBox(height: Gap.sm),
        ],
        FTTextField(controller: _place, label: 'Place', icon: AppIcons.location),
        const SizedBox(height: Gap.sm),
        FTTextField(controller: _notes, label: 'Notes', icon: AppIcons.note, maxLines: 3, minLines: 1),
        const SizedBox(height: Gap.lg),
        FTButton(
          label: 'Save',
          expand: true,
          onTap: () async {
            await ref.read(familyRepoProvider).updatePartnership(
                  widget.partnership.id,
                  PartnershipsCompanion(
                    type: Value(_type),
                    status: Value(_status),
                    startDate: Value(_start?.serialize()),
                    endDate: Value(_status == PartnerStatus.current ? null : _end?.serialize()),
                    place: Value(_place.text.trim().isEmpty ? null : _place.text.trim()),
                    notes: Value(_notes.text.trim().isEmpty ? null : _notes.text.trim()),
                  ),
                );
            if (context.mounted) Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({
    required this.title,
    required this.empty,
    required this.children,
    required this.onAddNew,
    required this.onLink,
  });

  final String title;
  final String empty;
  final List<Widget> children;
  final VoidCallback onAddNew;
  final VoidCallback onLink;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title),
        FTCard(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (children.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
                  child: Text(empty, style: context.tx.caption),
                )
              else
                ...children,
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(child: FTButton.secondary(label: 'Add new', icon: AppIcons.personAdd, height: 46, expand: true, onTap: onAddNew)),
                  const SizedBox(width: 8),
                  Expanded(child: FTButton.secondary(label: 'Link existing', icon: AppIcons.link, height: 46, expand: true, onTap: onLink)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RelRow extends StatelessWidget {
  const _RelRow({required this.person, required this.detail, required this.onEdit, required this.onRemove});
  final Person person;
  final String detail;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return PersonTile(
      person: person,
      subtitle: detail,
      onTap: () => context.push(Routes.person(person.id)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FTIconButton(icon: AppIcons.edit, tooltip: 'Edit relationship type', size: 38, onTap: onEdit),
          FTIconButton(icon: AppIcons.close, tooltip: 'Remove this relationship', size: 38, onTap: onRemove),
        ],
      ),
    );
  }
}
