import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../members/widgets/person_widgets.dart';
import '../search/text_normalize.dart';
import 'branch_logic.dart';

/// Muted branch colours (plus the signature mint), stored as ARGB ints.
const branchPalette = <int>[
  0xFF86D8CA, // mint
  0xFF8FB7D9, // sky
  0xFFAFA4D8, // lavender
  0xFFD8BE8C, // sand
  0xFFD69DA8, // rose
  0xFFA5C39B, // sage
  0xFFD3A083, // clay
  0xFF9EA6B3, // slate
];

const _paletteNames = ['Mint', 'Sky', 'Lavender', 'Sand', 'Rose', 'Sage', 'Clay', 'Slate'];

Color _branchColor(BuildContext context, FamilyBranch b) =>
    b.colorValue == null ? context.ft.accent : Color(b.colorValue!);

int _nextColor(Iterable<FamilyBranch> existing) {
  final used = {for (final b in existing) ?b.colorValue};
  return branchPalette.firstWhere((c) => !used.contains(c), orElse: () => branchPalette.first);
}

String _treeRoute(String focusId) => Uri(path: Routes.tree, queryParameters: {'focus': focusId}).toString();

class BranchesScreen extends ConsumerWidget {
  const BranchesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final graphAsync = ref.watch(familyGraphProvider);
    final branchesAsync = ref.watch(branchesProvider);
    final explicit = ref.watch(branchMembersProvider).value ?? const <PersonBranch>[];
    final home = ref.watch(homePersonIdProvider);

    return FTPage(
      title: 'Family branches',
      actions: [
        FTIconButton(
          icon: AppIcons.add,
          tooltip: 'New branch',
          onTap: () => showBranchForm(context, ref),
        ),
      ],
      body: Builder(builder: (context) {
        if (graphAsync.hasError) {
          return ErrorView(error: graphAsync.error!, onRetry: () => ref.invalidate(peopleProvider));
        }
        if (branchesAsync.hasError) {
          return ErrorView(error: branchesAsync.error!, onRetry: () => ref.invalidate(branchesProvider));
        }
        final g = graphAsync.value;
        final branches = branchesAsync.value;
        if (g == null || branches == null) return const LoadingView();
        if (g.size == 0) {
          return EmptyState(
            icon: AppIcons.branch,
            title: 'No family members yet',
            message: 'Branches group relatives by family line. Add people to your tree first.',
            actionLabel: 'Add a person',
            onAction: () => context.push(Routes.newPerson()),
          );
        }
        final suggestions = suggestBranches(g, homePersonId: home, existing: branches);
        final items = <Widget>[
          Text(
            'A branch contains its root person, their descendants and partners, '
            'plus anyone you add yourself.',
            style: context.tx.body,
          ),
          SectionHeader(
            'Your branches',
            trailing: branches.isEmpty
                ? null
                : Padding(
                    padding: const EdgeInsets.only(right: Gap.xs),
                    child: FTTag('${branches.length}', accent: true),
                  ),
            action: 'New',
            onAction: () => showBranchForm(context, ref),
          ),
          if (branches.isEmpty)
            FTCard(
              child: EmptyState(
                icon: AppIcons.branch,
                title: 'No branches yet',
                message: suggestions.isEmpty
                    ? 'Create a branch to follow one family line.'
                    : 'Create your own, or start from a suggestion below.',
                compact: true,
              ),
            )
          else
            for (final b in branches)
              _BranchCard(
                branch: b,
                graph: g,
                members: branchMembers(b, g, explicit),
                onTap: () => showBranchDetail(context, b.id),
              ),
          if (suggestions.isNotEmpty) ...[
            const SectionHeader('Suggested branches'),
            for (final s in suggestions)
              _SuggestionCard(
                suggestion: s,
                graph: g,
                onCreate: () => _createFromSuggestion(context, ref, s, branches),
              ),
          ],
        ];
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(
              context.pagePadding, Gap.xs, context.pagePadding, FTPage.bottomInset(context)),
          itemCount: items.length,
          itemBuilder: (context, i) => ContentWidth(
            child: Padding(
              padding: EdgeInsets.only(bottom: items[i] is SectionHeader ? Gap.xxs : Gap.md, top: items[i] is SectionHeader ? Gap.sm : 0),
              child: FadeSlideIn(index: i, child: items[i]),
            ),
          ),
        );
      }),
    );
  }

  Future<void> _createFromSuggestion(
      BuildContext context, WidgetRef ref, BranchSuggestion s, List<FamilyBranch> existing) async {
    final treeId = ref.read(activeTreeIdProvider);
    if (treeId == null) return;
    try {
      final id = await ref.read(familyRepoProvider).createBranch(
            treeId,
            s.name,
            rootPersonId: s.rootId,
            description: s.description,
            color: _nextColor(existing),
          );
      if (!context.mounted) return;
      showFTToast(
        context,
        '“${s.name}” created',
        actionLabel: 'Open',
        onAction: () {
          if (context.mounted) showBranchDetail(context, id);
        },
      );
    } catch (e) {
      if (context.mounted) showFTToast(context, friendlyError(e), error: true);
    }
  }
}

// ================================================================ cards

class _BranchCard extends ConsumerWidget {
  const _BranchCard({required this.branch, required this.graph, required this.members, required this.onTap});
  final FamilyBranch branch;
  final FamilyGraph graph;
  final Set<String> members;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ft;
    final color = _branchColor(context, branch);
    final root = branch.rootPersonId == null ? null : graph[branch.rootPersonId!];
    final ordered = orderedMembers(members, graph, rootId: branch.rootPersonId);
    final faces = [
      for (final id in ordered.take(4))
        (graph[id]!.displayName, ref.watch(avatarPathProvider(graph[id]!.profileMediaId))),
    ];
    final count = members.length;
    return FTCard(
      onTap: onTap,
      semanticLabel: '${branch.name}, $count ${count == 1 ? 'member' : 'members'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _ColorBadge(color: color),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(branch.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.section),
                    const SizedBox(height: 2),
                    Text(
                      root == null ? 'No root person' : 'From ${root.displayName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.tx.caption,
                    ),
                  ],
                ),
              ),
              Icon(AppIcons.forward, size: 18, color: c.text3),
            ],
          ),
          if ((branch.description ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(branch.description!.trim(),
                maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.body),
          ],
          const SizedBox(height: Gap.md),
          Row(
            children: [
              if (faces.isNotEmpty) AvatarStack(people: faces, max: 4, total: count, size: 32),
              const Spacer(),
              FTTag(count == 1 ? '1 member' : '$count members', icon: AppIcons.people),
            ],
          ),
        ],
      ),
    );
  }
}

class _ColorBadge extends StatelessWidget {
  const _ColorBadge({required this.color, this.size = 44});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: c.chipGradient,
        border: Border.all(color: c.border),
      ),
      child: Center(
        child: Container(
          width: size * 0.36,
          height: size * 0.36,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 10)],
          ),
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.suggestion, required this.graph, required this.onCreate});
  final BranchSuggestion suggestion;
  final FamilyGraph graph;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final s = suggestion;
    final icon = switch (s.kind) {
      SuggestionKind.paternal || SuggestionKind.maternal => AppIcons.footprints,
      SuggestionKind.rootLine => AppIcons.branch,
    };
    return FTCard(
      padding: const EdgeInsets.all(Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconBadge(icon: icon, size: 42),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.section),
                    const SizedBox(height: 2),
                    Text(s.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.tx.caption),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.sm),
          Row(
            children: [
              Flexible(
                child: FTTag(
                  s.memberCount == 1 ? '1 person' : '${s.memberCount} people',
                  icon: AppIcons.people,
                ),
              ),
              const Spacer(),
              FTButton.secondary(label: 'Create', icon: AppIcons.add, height: 44, onTap: onCreate),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================== detail

/// Opens the live detail sheet of a branch.
Future<void> showBranchDetail(BuildContext context, String branchId) {
  final router = GoRouter.of(context);
  final screenContext = context;
  return showFTSheet<void>(
    context,
    scrollable: false,
    builder: (ctx) => _BranchDetail(branchId: branchId, router: router, screenContext: screenContext),
  );
}

class _BranchDetail extends ConsumerWidget {
  const _BranchDetail({required this.branchId, required this.router, required this.screenContext});
  final String branchId;
  final GoRouter router;
  final BuildContext screenContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ft;
    final mq = MediaQuery.of(context);
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final branches = ref.watch(branchesProvider).value ?? const <FamilyBranch>[];
    final explicitRows = ref.watch(branchMembersProvider).value ?? const <PersonBranch>[];
    FamilyBranch? branch;
    for (final b in branches) {
      if (b.id == branchId) branch = b;
    }
    final height = (mq.size.height - mq.viewInsets.bottom) * 0.8;
    if (branch == null) {
      return SizedBox(
        height: 240,
        child: EmptyState(icon: AppIcons.branch, title: 'This branch no longer exists', compact: true),
      );
    }
    final b = branch;
    final members = branchMembers(b, g, explicitRows);
    final explicit = explicitBranchMembers(b.id, g, explicitRows);
    final rootId = b.rootPersonId;
    final root = rootId == null ? null : g[rootId];
    final line = root == null ? <String>{} : {rootId!, ...g.descendants(rootId)};
    final ordered = orderedMembers(members, g, rootId: rootId);
    final focusId = root?.id ?? (ordered.isEmpty ? null : ordered.first);

    String roleOf(String id) {
      final roles = <String>[];
      if (id == rootId) {
        roles.add('Root person');
      } else if (line.contains(id)) {
        roles.add('Descendant of ${root!.shortName}');
      } else if (root != null && members.contains(id) && !explicit.contains(id)) {
        roles.add('Partner in this line');
      }
      if (explicit.contains(id)) roles.add('Added to branch');
      return roles.join(' · ');
    }

    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.md, 0),
            child: Row(
              children: [
                _ColorBadge(color: _branchColor(context, b), size: 40),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(b.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.title),
                  ),
                ),
                FTIconButton(
                  icon: AppIcons.moreHoriz,
                  tooltip: 'Branch options',
                  size: 40,
                  onTap: () => _options(context, ref, b, explicit),
                ),
                FTIconButton(
                  icon: AppIcons.close,
                  tooltip: 'Close',
                  size: 40,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.sm, Gap.xl, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if ((b.description ?? '').trim().isNotEmpty) ...[
                  Text(b.description!.trim(), maxLines: 3, overflow: TextOverflow.ellipsis, style: context.tx.body),
                  const SizedBox(height: Gap.sm),
                ],
                Wrap(
                  spacing: Gap.xs,
                  runSpacing: Gap.xs,
                  children: [
                    FTTag(members.length == 1 ? '1 member' : '${members.length} members',
                        icon: AppIcons.people, accent: true),
                    FTTag(root == null ? 'No root person' : 'Root: ${root.displayName}', icon: AppIcons.tree),
                    if (explicit.isNotEmpty) FTTag('${explicit.length} added by you', icon: AppIcons.personAdd),
                  ],
                ),
                const SizedBox(height: Gap.md),
                Wrap(
                  spacing: Gap.xs,
                  runSpacing: Gap.xs,
                  children: [
                    FTButton.secondary(
                      label: 'View in tree',
                      icon: AppIcons.tree,
                      height: 44,
                      onTap: focusId == null
                          ? null
                          : () {
                              Navigator.of(context).pop();
                              router.go(_treeRoute(focusId));
                            },
                    ),
                    FTButton.secondary(
                      label: 'Add people',
                      icon: AppIcons.personAdd,
                      height: 44,
                      onTap: () => _addPeople(context, ref, b, members),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: Gap.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
            child: Container(height: 1, color: c.border),
          ),
          Expanded(
            child: ordered.isEmpty
                ? EmptyState(
                    icon: AppIcons.people,
                    title: 'No members yet',
                    message: 'Choose a root person or add people to this branch.',
                    compact: true,
                    actionLabel: 'Add people',
                    onAction: () => _addPeople(context, ref, b, members),
                  )
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, mq.padding.bottom + Gap.md),
                    itemCount: ordered.length,
                    itemBuilder: (context, i) {
                      final p = g[ordered[i]]!;
                      final isExplicit = explicit.contains(p.id);
                      return PersonTile(
                        person: p,
                        subtitle: roleOf(p.id),
                        onTap: () {
                          Navigator.of(context).pop();
                          router.push(Routes.person(p.id));
                        },
                        trailing: isExplicit
                            ? FTIconButton(
                                icon: AppIcons.close,
                                size: 36,
                                tooltip: 'Remove ${p.displayName} from branch',
                                onTap: () => _remove(context, ref, b, p, members, line),
                              )
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _addPeople(BuildContext context, WidgetRef ref, FamilyBranch b, Set<String> members) async {
    final picked = await pickPeople(context, title: 'Add to ${b.name}', exclude: members);
    if (picked == null || picked.isEmpty) return;
    try {
      await ref.read(familyRepoProvider).assignToBranch(picked, b.id);
      if (screenContext.mounted) {
        showFTToast(screenContext, picked.length == 1 ? '1 person added' : '${picked.length} people added');
      }
    } catch (e) {
      if (screenContext.mounted) showFTToast(screenContext, friendlyError(e), error: true);
    }
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    FamilyBranch b,
    Person p,
    Set<String> members,
    Set<String> line,
  ) async {
    final repo = ref.read(familyRepoProvider);
    try {
      await repo.removeFromBranch(p.id, b.id);
      if (!screenContext.mounted) return;
      final stays = line.contains(p.id) || (members.contains(p.id) && b.rootPersonId != null && _inLine(ref, b, p.id));
      showFTToast(
        screenContext,
        stays
            ? '${p.shortName} stays in the branch as part of its family line'
            : '${p.shortName} removed from ${b.name}',
        actionLabel: 'Undo',
        onAction: () => repo.assignToBranch([p.id], b.id),
      );
    } catch (e) {
      if (screenContext.mounted) showFTToast(screenContext, friendlyError(e), error: true);
    }
  }

  bool _inLine(WidgetRef ref, FamilyBranch b, String personId) {
    final g = ref.read(familyGraphProvider).value;
    final root = b.rootPersonId;
    return g != null && root != null && lineMembers(root, g).contains(personId);
  }

  Future<void> _options(BuildContext context, WidgetRef ref, FamilyBranch b, Set<String> explicit) async {
    final choice = await showFTOptions<String>(
      context,
      title: b.name,
      options: const [
        FTOption('edit', 'Edit branch', icon: AppIcons.edit, subtitle: 'Name, description, root person, colour'),
        FTOption('rename', 'Rename', icon: AppIcons.textSize),
        FTOption('delete', 'Delete branch', icon: AppIcons.delete, danger: true, subtitle: 'People are not deleted'),
      ],
    );
    if (choice == null || !context.mounted) return;
    final repo = ref.read(familyRepoProvider);
    switch (choice) {
      case 'edit':
        await showBranchForm(context, ref, existing: b);
      case 'rename':
        final name = await showFTTextPrompt(context, title: 'Rename branch', label: 'Branch name', initial: b.name);
        if (name == null || name.trim().isEmpty || name.trim() == b.name) return;
        final others = (ref.read(branchesProvider).value ?? const <FamilyBranch>[]).where((x) => x.id != b.id);
        if (others.any((x) => normalizeKey(x.name) == normalizeKey(name))) {
          if (screenContext.mounted) {
            showFTToast(screenContext, 'A branch called “${name.trim()}” already exists.', error: true);
          }
          return;
        }
        try {
          await repo.updateBranch(b.id, name: name);
        } catch (e) {
          if (screenContext.mounted) showFTToast(screenContext, friendlyError(e), error: true);
        }
      case 'delete':
        final ok = await showFTConfirm(
          context,
          title: 'Delete “${b.name}”?',
          message: 'The branch and its list of added members will be removed. '
              'Nobody is deleted from your family tree.',
          confirmLabel: 'Delete',
          destructive: true,
        );
        if (!ok) return;
        final treeId = b.treeId;
        final saved = (
          name: b.name,
          description: b.description,
          root: b.rootPersonId,
          color: b.colorValue,
          members: explicit.toList(),
        );
        try {
          await repo.deleteBranch(b.id);
          if (context.mounted) Navigator.of(context).pop();
          if (!screenContext.mounted) return;
          showFTToast(
            screenContext,
            'Branch “${b.name}” deleted',
            actionLabel: 'Undo',
            onAction: () async {
              final id = await repo.createBranch(
                treeId,
                saved.name,
                rootPersonId: saved.root,
                description: saved.description,
                color: saved.color,
              );
              if (saved.members.isNotEmpty) await repo.assignToBranch(saved.members, id);
            },
          );
        } catch (e) {
          if (screenContext.mounted) showFTToast(screenContext, friendlyError(e), error: true);
        }
    }
  }
}

// ================================================================= form

/// Create (no [existing]) or edit a branch.
Future<void> showBranchForm(BuildContext context, WidgetRef ref, {FamilyBranch? existing}) async {
  final treeId = ref.read(activeTreeIdProvider);
  if (treeId == null) {
    showFTToast(context, 'Create a family tree first.', error: true);
    return;
  }
  final saved = await showFTSheet<String>(
    context,
    title: existing == null ? 'New branch' : 'Edit branch',
    builder: (_) => _BranchForm(treeId: treeId, existing: existing),
  );
  if (saved != null && context.mounted) {
    showFTToast(context, existing == null ? '“$saved” created' : 'Branch saved');
  }
}

class _BranchForm extends ConsumerStatefulWidget {
  const _BranchForm({required this.treeId, this.existing});
  final String treeId;
  final FamilyBranch? existing;

  @override
  ConsumerState<_BranchForm> createState() => _BranchFormState();
}

class _BranchFormState extends ConsumerState<_BranchForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _description = TextEditingController(text: widget.existing?.description);
  late String? _rootId = widget.existing?.rootPersonId;
  late int _color = widget.existing?.colorValue ??
      _nextColor(ref.read(branchesProvider).value ?? const <FamilyBranch>[]);
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  String? _validateName(String? v) {
    final name = (v ?? '').trim();
    if (name.isEmpty) return 'Please enter a name';
    final others = (ref.read(branchesProvider).value ?? const <FamilyBranch>[])
        .where((b) => b.id != widget.existing?.id);
    if (others.any((b) => normalizeKey(b.name) == normalizeKey(name))) {
      return 'A branch with this name already exists';
    }
    return null;
  }

  Future<void> _pickRoot() async {
    final id = await pickPerson(context, title: 'Root person');
    if (id != null) setState(() => _rootId = id);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final repo = ref.read(familyRepoProvider);
    final name = _name.text.trim();
    final description = _description.text.trim();
    try {
      final e = widget.existing;
      if (e == null) {
        await repo.createBranch(
          widget.treeId,
          name,
          rootPersonId: _rootId,
          description: description.isEmpty ? null : description,
          color: _color,
        );
      } else {
        await repo.updateBranch(
          e.id,
          name: name,
          description: description,
          rootPersonId: _rootId,
          clearRoot: _rootId == null,
          color: _color,
        );
      }
      if (mounted) Navigator.of(context).pop(name);
    } catch (err) {
      if (!mounted) return;
      setState(() => _saving = false);
      showFTToast(context, friendlyError(err), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final root = _rootId == null ? null : g[_rootId!];
    final preview = _rootId == null ? 0 : lineMembers(_rootId!, g).length;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FTTextField(
            controller: _name,
            label: 'Branch name',
            hint: 'e.g. Paternal line',
            icon: AppIcons.branch,
            textCapitalization: TextCapitalization.words,
            validator: _validateName,
            autofocus: widget.existing == null,
          ),
          const SizedBox(height: Gap.md),
          FTTextField(
            controller: _description,
            label: 'Description (optional)',
            maxLines: 3,
            minLines: 1,
          ),
          const SizedBox(height: Gap.md),
          FTSelectField(
            label: 'Root person',
            value: root?.displayName,
            placeholder: 'Choose who this line starts with',
            icon: AppIcons.tree,
            onTap: _pickRoot,
            onClear: () => setState(() => _rootId = null),
          ),
          const SizedBox(height: Gap.xs),
          Text(
            root == null
                ? 'Without a root person, the branch only contains the people you add.'
                : 'Includes ${root.shortName}, their descendants and partners ($preview people) '
                    'plus anyone you add.',
            style: context.tx.caption,
          ),
          const SizedBox(height: Gap.lg),
          Text('Colour', style: context.tx.label.copyWith(color: c.text2)),
          const SizedBox(height: Gap.xs),
          Wrap(
            spacing: Gap.xs,
            runSpacing: Gap.xs,
            children: [
              for (var i = 0; i < branchPalette.length; i++)
                _Swatch(
                  color: Color(branchPalette[i]),
                  name: _paletteNames[i],
                  selected: _color == branchPalette[i],
                  onTap: () => setState(() => _color = branchPalette[i]),
                ),
            ],
          ),
          const SizedBox(height: Gap.xl),
          FTButton(
            label: widget.existing == null ? 'Create branch' : 'Save changes',
            expand: true,
            loading: _saving,
            onTap: _save,
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.name, required this.selected, required this.onTap});
  final Color color;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Tooltip(
      message: name,
      excludeFromSemantics: true,
      child: Semantics(
        selected: selected,
        child: Pressable(
          onTap: onTap,
          semanticLabel: '$name colour',
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: AnimatedContainer(
                duration: Motion.fast,
                width: 36,
                height: 36,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: selected ? c.text : c.border, width: selected ? 2 : 1),
                ),
                child: Container(
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  child: selected ? const Icon(AppIcons.check, size: 16, color: Color(0xFF0B0C0F)) : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
