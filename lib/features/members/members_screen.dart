import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../app/navigation/app_shell.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/services/app_paths.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import 'widgets/person_widgets.dart';

enum _Filter { all, living, deceased, archived }

enum _Sort { name, birth, recent }

/// Members tab: searchable, filterable directory with bulk actions.
class MembersScreen extends ConsumerStatefulWidget {
  const MembersScreen({super.key});

  @override
  ConsumerState<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends ConsumerState<MembersScreen> {
  String _q = '';
  _Filter _filter = _Filter.all;
  _Sort _sort = _Sort.name;
  String? _tagId;
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

  List<Person> _apply(FamilyGraph g, List<PersonTag> personTags) {
    final q = _q.trim().toLowerCase();
    final tagged = _tagId == null ? null : {for (final t in personTags) if (t.tagId == _tagId) t.personId};
    final list = g.people.values.where((p) {
      if (_filter == _Filter.archived) {
        if (!p.isArchived) return false;
      } else if (p.isArchived) {
        return false;
      }
      if (_filter == _Filter.living && !p.isLiving) return false;
      if (_filter == _Filter.deceased && p.isLiving) return false;
      if (tagged != null && !tagged.contains(p.id)) return false;
      if (q.isEmpty) return true;
      return [
        p.displayName,
        p.nickname,
        p.birthName,
        p.birthPlace,
        p.occupation,
        p.birth?.formatYear(),
        p.death?.formatYear(),
      ].whereType<String>().any((s) => s.toLowerCase().contains(q));
    }).toList();
    switch (_sort) {
      case _Sort.name:
        list.sort((a, b) => _sortKey(a).compareTo(_sortKey(b)));
      case _Sort.birth:
        list.sort((a, b) => (a.birth?.sortKey ?? double.infinity).compareTo(b.birth?.sortKey ?? double.infinity));
      case _Sort.recent:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return list;
  }

  static String _sortKey(Person p) =>
      '${(p.lastName ?? '').toLowerCase()} ${p.displayName.toLowerCase()}';

  static String _letter(Person p) {
    final s = (p.lastName?.trim().isNotEmpty ?? false) ? p.lastName!.trim() : p.displayName;
    final ch = s.isEmpty ? '#' : s.characters.first.toUpperCase();
    return RegExp(r'[A-Z]').hasMatch(ch) ? ch : '#';
  }

  // ------------------------------------------------------------ bulk actions

  /// Runs a bulk action and reports failures instead of failing silently.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) showFTToast(context, friendlyError(e), error: true);
    }
  }

  Future<void> _bulkBranch() async {
    final branches = ref.read(branchesProvider).value ?? const [];
    final repo = ref.read(familyRepoProvider);
    final r = await showFTOptions<String>(
      context,
      title: 'Assign to branch',
      options: [
        for (final b in branches) FTOption(b.id, b.name, icon: AppIcons.branch),
        const FTOption('__new', 'New branch…', icon: AppIcons.add),
      ],
    );
    if (r == null || !mounted) return;
    var branchId = r;
    if (r == '__new') {
      final name = await showFTTextPrompt(context, title: 'New branch', label: 'Branch name', hint: 'e.g. Paternal line');
      if (name == null) return;
      branchId = await repo.createBranch(ref.read(activeTreeIdProvider)!, name);
    }
    await repo.assignToBranch(_selected, branchId);
    if (mounted) showFTToast(context, '${_selected.length} assigned to branch');
    if (mounted) setState(_selected.clear);
  }

  Future<void> _bulkTag() async {
    final tags = ref.read(tagsProvider).value ?? const [];
    final repo = ref.read(familyRepoProvider);
    final r = await showFTOptions<String>(
      context,
      title: 'Add a tag',
      options: [
        for (final t in tags) FTOption(t.id, t.name, icon: AppIcons.tag),
        const FTOption('__new', 'New tag…', icon: AppIcons.add),
      ],
    );
    if (r == null || !mounted) return;
    var tagId = r;
    if (r == '__new') {
      final name = await showFTTextPrompt(context, title: 'New tag', label: 'Tag name', hint: 'e.g. Kerala, Military');
      if (name == null) return;
      tagId = await repo.ensureTag(ref.read(activeTreeIdProvider)!, name);
    }
    await repo.tagPeople(_selected, tagId);
    if (mounted) showFTToast(context, 'Tag added to ${_selected.length}');
    if (mounted) setState(_selected.clear);
  }

  Future<void> _bulkArchive(bool archive) async {
    await ref.read(familyRepoProvider).setArchived(_selected, archive);
    if (mounted) showFTToast(context, archive ? 'Archived ${_selected.length}' : 'Restored ${_selected.length} from archive');
    if (mounted) setState(_selected.clear);
  }

  Future<void> _bulkExport(FamilyGraph g) async {
    final rows = <List<String>>[
      ['Name', 'Gender', 'Birth date', 'Birth place', 'Living', 'Death date', 'Death place', 'Occupation', 'Parents', 'Partners'],
      for (final id in _selected)
        if (g[id] != null)
          [
            g[id]!.displayName,
            g[id]!.gender.label,
            g[id]!.birth?.format() ?? '',
            g[id]!.birthPlace ?? '',
            g[id]!.isLiving ? 'Yes' : 'No',
            g[id]!.death?.format() ?? '',
            g[id]!.deathPlace ?? '',
            g[id]!.occupation ?? '',
            g.parentIds(id).map((x) => g[x]?.displayName ?? '').join('; '),
            g.partnerIds(id).map((x) => g[x]?.displayName ?? '').join('; '),
          ],
    ];
    String esc(String s) => '"${s.replaceAll('"', '""')}"';
    final csv = rows.map((r) => r.map(esc).join(',')).join('\r\n');
    final f = File(p.join(AppPaths.I.exportsDir().path, 'family_members_${DateTime.now().millisecondsSinceEpoch}.csv'));
    await f.writeAsString('﻿$csv');
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'text/csv')], subject: 'Family members'));
  }

  Future<void> _bulkTrash() async {
    final n = _selected.length;
    final ok = await showFTConfirm(
      context,
      title: 'Move $n ${n == 1 ? 'person' : 'people'} to trash?',
      message: 'Their relationships are kept and everything can be restored from Trash.',
      confirmLabel: 'Move to trash',
      destructive: true,
    );
    if (!ok) return;
    final repo = ref.read(familyRepoProvider);
    for (final id in _selected) {
      await repo.trashPerson(id);
    }
    if (mounted) {
      showFTToast(context, 'Moved $n to trash', actionLabel: 'View', onAction: () => context.push(Routes.trash));
    }
    if (mounted) setState(_selected.clear);
  }

  @override
  Widget build(BuildContext context) {
    final graphAsync = ref.watch(familyGraphProvider);
    final personTags = ref.watch(personTagsProvider).value ?? const <PersonTag>[];
    final tags = ref.watch(tagsProvider).value ?? const <Tag>[];
    final c = context.ft;
    final pad = context.pagePadding;

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: FTPage(
        showBack: false,
        leading: _selecting
            ? FTIconButton(icon: AppIcons.close, tooltip: 'Cancel selection', onTap: () => setState(_selected.clear))
            : null,
        titleWidget: _selecting
            ? Text('${_selected.length} selected', style: context.tx.title)
            : null,
        actions: [
          if (_selecting)
            FTIconButton(
              icon: AppIcons.selectAll,
              tooltip: 'Select all',
              onTap: () {
                final g = graphAsync.value;
                if (g == null) return;
                setState(() => _selected.addAll(_apply(g, personTags).map((p) => p.id)));
              },
            ),
        ],
        body: graphAsync.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(error: e),
          data: (g) {
            final list = _apply(g, personTags);
            final children = <Widget>[];
            String? last;
            for (var i = 0; i < list.length; i++) {
              final person = list[i];
              if (_sort == _Sort.name) {
                final l = _letter(person);
                if (l != last) {
                  last = l;
                  children.add(Padding(
                    padding: EdgeInsets.fromLTRB(pad + 6, Gap.md, pad, 4),
                    child: Text(l, style: context.tx.caption.copyWith(color: c.accent, fontWeight: FontWeight.w600)),
                  ));
                }
              }
              final sel = _selected.contains(person.id);
              children.add(Padding(
                padding: EdgeInsets.symmetric(horizontal: pad - 6),
                child: FadeSlideIn(
                  index: i.clamp(0, 10),
                  child: PersonTile(
                    person: person,
                    selected: sel,
                    subtitle: _subtitle(person, g),
                    onTap: () {
                      if (_selecting) {
                        setState(() => sel ? _selected.remove(person.id) : _selected.add(person.id));
                      } else {
                        context.push(Routes.person(person.id));
                      }
                    },
                    onLongPress: () => setState(() => _selected.add(person.id)),
                    trailing: _selecting
                        ? Icon(sel ? AppIcons.checkCircle : AppIcons.add,
                            size: 22, color: sel ? c.accent : c.text3)
                        : (!person.isLiving
                            ? Icon(AppIcons.flower, size: 16, color: c.text3, semanticLabel: 'Deceased')
                            : null),
                  ),
                ),
              ));
            }

            return Stack(
              children: [
                CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(pad, 0, pad, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Family members', style: context.tx.headline),
                                      Text('${g.size} people · ${g.people.values.where((p) => p.isLiving).length} living',
                                          style: context.tx.caption),
                                    ],
                                  ),
                                ),
                                FTIconButton(
                                  icon: AppIcons.personAdd,
                                  tooltip: 'Add family member',
                                  accent: true,
                                  onTap: () => context.push(Routes.newPerson()),
                                ),
                              ],
                            ),
                            const SizedBox(height: Gap.lg),
                            Row(
                              children: [
                                Expanded(
                                  child: FTSearchField(
                                    hint: 'Search name, place, year',
                                    onChanged: (v) => setState(() {
                                      _q = v;
                                      _selected.clear();
                                    }),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FTIconButton(
                                  icon: AppIcons.sort,
                                  tooltip: 'Sort',
                                  onTap: () async {
                                    final s = await showFTOptions<_Sort>(context, title: 'Sort by', options: [
                                      FTOption(_Sort.name, 'Surname', icon: AppIcons.sort, selected: _sort == _Sort.name),
                                      FTOption(_Sort.birth, 'Birth date', icon: AppIcons.cake, selected: _sort == _Sort.birth),
                                      FTOption(_Sort.recent, 'Recently added', icon: AppIcons.clock, selected: _sort == _Sort.recent),
                                    ]);
                                    if (s != null) setState(() => _sort = s);
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: Gap.sm),
                            SizedBox(
                              height: 40,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                children: [
                                  for (final f in _Filter.values) ...[
                                    FTChip(
                                      label: switch (f) {
                                        _Filter.all => 'All',
                                        _Filter.living => 'Living',
                                        _Filter.deceased => 'Deceased',
                                        _Filter.archived => 'Archived',
                                      },
                                      selected: _filter == f,
                                      onTap: () => setState(() {
                                        _filter = f;
                                        _selected.clear();
                                      }),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  for (final t in tags) ...[
                                    FTChip(
                                      label: '#${t.name}',
                                      selected: _tagId == t.id,
                                      onTap: () => setState(() {
                                        _tagId = _tagId == t.id ? null : t.id;
                                        _selected.clear();
                                      }),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  FTChip(
                                    label: 'Duplicates',
                                    icon: AppIcons.duplicate,
                                    selected: false,
                                    onTap: () => context.push(Routes.duplicates),
                                  ),
                                ],
                              ),
                            ),
                            if (!_selecting && g.size > 0)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text('Long-press to select several people', style: context.tx.micro),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (list.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyState(
                          icon: AppIcons.people,
                          title: g.size == 0 ? 'No family members yet' : 'No one matches',
                          message: g.size == 0 ? 'Start with yourself or an ancestor.' : 'Try another search or filter.',
                          actionLabel: g.size == 0 ? 'Add a person' : null,
                          onAction: g.size == 0 ? () => context.push(Routes.newPerson()) : null,
                        ),
                      )
                    else
                      SliverList.list(children: children),
                    SliverToBoxAdapter(child: SizedBox(height: AppShell.contentInset(context) + (_selecting ? 80 : 0))),
                  ],
                ),
                if (_selecting)
                  Positioned(
                    left: pad,
                    right: pad,
                    bottom: AppShell.contentInset(context) - 16,
                    child: FTCard(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      radius: Radii.pill,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          FTIconButton(icon: AppIcons.branch, tooltip: 'Assign branch', onTap: () => _guard(_bulkBranch)),
                          FTIconButton(icon: AppIcons.tag, tooltip: 'Add tag', onTap: () => _guard(_bulkTag)),
                          FTIconButton(
                            icon: AppIcons.archive,
                            tooltip: _filter == _Filter.archived ? 'Unarchive' : 'Archive',
                            onTap: () => _guard(() => _bulkArchive(_filter != _Filter.archived)),
                          ),
                          FTIconButton(icon: AppIcons.export, tooltip: 'Export selected (CSV)', onTap: () => _guard(() => _bulkExport(g))),
                          FTIconButton(icon: AppIcons.delete, tooltip: 'Move to trash', onTap: () => _guard(_bulkTrash)),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  String _subtitle(Person p, FamilyGraph g) {
    final parts = <String>[];
    if (p.lifespanLabel.isNotEmpty) parts.add(p.lifespanLabel);
    if ((p.nickname ?? '').isNotEmpty) parts.add('“${p.nickname}”');
    if ((p.birthPlace ?? '').isNotEmpty) parts.add(p.birthPlace!);
    if (parts.isEmpty && p.gender != Gender.unknown) parts.add(p.gender.label);
    return parts.join(' · ');
  }
}
