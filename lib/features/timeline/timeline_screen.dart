import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/app_shell.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../members/widgets/person_widgets.dart';
import 'timeline_builder.dart';
import 'timeline_widgets.dart';

/// Family timeline tab: births, partnerships, deaths, events, dated stories
/// and photos in chronological order, filterable by category and scope,
/// with decade quick-jump.
class TimelineScreen extends ConsumerStatefulWidget {
  const TimelineScreen({super.key});

  @override
  ConsumerState<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends ConsumerState<TimelineScreen> {
  static const _undatedId = -1;

  final _scroll = ScrollController();
  final Map<int, GlobalKey> _sectionKeys = {};
  final Map<int, GlobalKey> _chipKeys = {};

  TimelineScope _scope = const TimelineScope.family();
  Set<TimelineCategory> _categories = TimelineCategory.values.toSet();
  String? _selectedKey;
  int? _activeSection;
  bool _jumping = false;
  bool _measureScheduled = false;
  List<TimelineSection> _sections = const [];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  int _idOf(int? decade) => decade ?? _undatedId;
  GlobalKey _sectionKey(int id) => _sectionKeys.putIfAbsent(id, GlobalKey.new);
  GlobalKey _chipKey(int id) => _chipKeys.putIfAbsent(id, GlobalKey.new);

  // -------------------------------------------------------------- scrolling

  /// Highlights the decade chip of the section currently at the top.
  void _onScroll() {
    if (_jumping || !_scroll.hasClients || _sections.isEmpty) return;
    // Never measure while a frame is being laid out.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      if (!_measureScheduled) {
        _measureScheduled = true;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          _measureScheduled = false;
          if (mounted) _onScroll();
        });
      }
      return;
    }
    final pixels = _scroll.position.pixels;
    int? active = _idOf(_sections.first.decade);
    for (final s in _sections) {
      final ro = _sectionKeys[_idOf(s.decade)]?.currentContext?.findRenderObject();
      if (ro == null || !ro.attached) continue;
      final vp = RenderAbstractViewport.maybeOf(ro);
      if (vp == null) continue;
      if (vp.getOffsetToReveal(ro, 0).offset <= pixels + 4) {
        active = _idOf(s.decade);
      } else {
        break;
      }
    }
    if (active != _activeSection) {
      setState(() => _activeSection = active);
      _revealChip(active);
    }
  }

  void _revealChip(int? id) {
    if (id == null) return;
    final ctx = _chipKeys[id]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: context.reduceMotion ? Duration.zero : Motion.medium,
      curve: Motion.curve,
    );
  }

  /// Jumps to a decade. Lazy sections have estimated extents, so the jump is
  /// refined over a few frames until the header sits at the top.
  Future<void> _jumpTo(int id) async {
    setState(() => _activeSection = id);
    _revealChip(id);
    _jumping = true;
    try {
      for (var pass = 0; pass < 3; pass++) {
        final ctx = _sectionKeys[id]?.currentContext;
        if (ctx == null || !ctx.mounted) break;
        await Scrollable.ensureVisible(ctx, alignment: 0, duration: Duration.zero);
        await WidgetsBinding.instance.endOfFrame;
      }
    } finally {
      _jumping = false;
    }
  }

  // ---------------------------------------------------------------- filters

  void _toggleCategory(TimelineCategory cat) {
    setState(() {
      final all = TimelineCategory.values.toSet();
      if (_categories.length == all.length) {
        _categories = {cat};
      } else if (_categories.contains(cat)) {
        final next = {..._categories}..remove(cat);
        _categories = next.isEmpty ? all : next;
      } else {
        _categories = {..._categories, cat};
      }
    });
  }

  Future<void> _pickScope(FamilyGraph g, TimelineBuilder builder) async {
    final kind = await showFTOptions<TimelineScopeKind>(
      context,
      title: 'Show timeline for',
      options: [
        FTOption(TimelineScopeKind.family, TimelineScopeKind.family.label,
            icon: AppIcons.family,
            subtitle: 'Everyone in this tree',
            selected: _scope.kind == TimelineScopeKind.family),
        FTOption(TimelineScopeKind.person, TimelineScopeKind.person.label,
            icon: AppIcons.person,
            subtitle: 'Their life, partnerships, events, stories and photos',
            selected: _scope.kind == TimelineScopeKind.person),
        FTOption(TimelineScopeKind.branch, TimelineScopeKind.branch.label,
            icon: AppIcons.branch,
            subtitle: 'A family line and its descendants',
            selected: _scope.kind == TimelineScopeKind.branch),
        FTOption(TimelineScopeKind.generation, TimelineScopeKind.generation.label,
            icon: AppIcons.generations,
            subtitle: 'People of the same generation',
            selected: _scope.kind == TimelineScopeKind.generation),
      ],
    );
    if (kind == null || !mounted) return;
    TimelineScope? next;
    switch (kind) {
      case TimelineScopeKind.family:
        next = const TimelineScope.family();
      case TimelineScopeKind.person:
        if (g.size == 0) {
          showFTToast(context, 'Add people to your tree first', error: true);
          return;
        }
        final id = await pickPerson(context, title: 'Whose timeline?');
        if (id != null) next = TimelineScope.person(id);
      case TimelineScopeKind.branch:
        final branches = ref.read(branchesProvider).value ?? const <FamilyBranch>[];
        if (branches.isEmpty) {
          final go = await showFTConfirm(
            context,
            title: 'No branches yet',
            message: 'Branches group a family line, for example “Paternal side”. Create one to see its timeline.',
            confirmLabel: 'Create branch',
            icon: AppIcons.branch,
          );
          if (go && mounted) context.push(Routes.branches);
          return;
        }
        final links = ref.read(branchMembersProvider).value ?? const <PersonBranch>[];
        final id = await showFTOptions<String>(
          context,
          title: 'Choose a branch',
          options: [
            for (final b in branches)
              FTOption(
                b.id,
                b.name,
                icon: AppIcons.branch,
                subtitle: _countLabel(TimelineBuilder.membersOfBranch(b, links, g).length, 'person', 'people'),
                selected: _scope.kind == TimelineScopeKind.branch && _scope.id == b.id,
              ),
          ],
        );
        if (id != null) next = TimelineScope.branch(id);
      case TimelineScopeKind.generation:
        final gens = builder.generationIndexes();
        if (gens.isEmpty) {
          showFTToast(context, 'Add people to your tree first', error: true);
          return;
        }
        final counts = <int, int>{};
        for (final v in g.generations().values) {
          counts[v] = (counts[v] ?? 0) + 1;
        }
        final n = await showFTOptions<int>(
          context,
          title: 'Choose a generation',
          options: [
            for (final i in gens)
              FTOption(
                i,
                'Generation ${i + 1}${i == gens.first ? ' · oldest' : ''}',
                icon: AppIcons.generations,
                subtitle: _countLabel(counts[i] ?? 0, 'person', 'people'),
                selected: _scope.kind == TimelineScopeKind.generation && _scope.generation == i,
              ),
          ],
        );
        if (n != null) next = TimelineScope.generation(n);
    }
    if (next != null && mounted) {
      setState(() {
        _scope = next!;
        _selectedKey = null;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  static String _countLabel(int n, String one, String many) => '$n ${n == 1 ? one : many}';

  String _scopeLabel(FamilyGraph g) {
    switch (_scope.kind) {
      case TimelineScopeKind.family:
        return 'Entire family';
      case TimelineScopeKind.person:
        return g[_scope.id!]?.displayName ?? 'Unknown person';
      case TimelineScopeKind.branch:
        final branches = ref.watch(branchesProvider).value ?? const <FamilyBranch>[];
        return branches.where((b) => b.id == _scope.id).firstOrNull?.name ?? 'Branch';
      case TimelineScopeKind.generation:
        return 'Generation ${_scope.generation! + 1}';
    }
  }

  IconData get _scopeIcon => switch (_scope.kind) {
        TimelineScopeKind.family => AppIcons.family,
        TimelineScopeKind.person => AppIcons.person,
        TimelineScopeKind.branch => AppIcons.branch,
        TimelineScopeKind.generation => AppIcons.generations,
      };

  // ------------------------------------------------------------- navigation

  void _open(TimelineItem i, List<String> photoIds) {
    setState(() => _selectedKey = i.key);
    switch (i.target) {
      case TimelineTarget.person:
        context.push(Routes.person(i.targetId));
      case TimelineTarget.event:
        context.push(Routes.event(i.targetId));
      case TimelineTarget.story:
        context.push(Routes.story(i.targetId));
      case TimelineTarget.media:
        context.push(Routes.media(i.targetId), extra: photoIds);
    }
  }

  // --------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final graphAsync = ref.watch(familyGraphProvider);
    final eventsAsync = ref.watch(eventsWithPeopleProvider);

    final actions = [
      FTIconButton(
        icon: AppIcons.calendar,
        tooltip: 'Family calendar',
        onTap: () => context.push(Routes.calendar),
      ),
      FTIconButton(
        icon: AppIcons.add,
        tooltip: 'Add event',
        onTap: () => context.push(Routes.newEvent()),
      ),
    ];

    if (graphAsync.hasError || eventsAsync.hasError) {
      return FTPage(
        showBack: false,
        title: 'Timeline',
        actions: actions,
        body: ErrorView(error: graphAsync.error ?? eventsAsync.error!),
      );
    }
    final g = graphAsync.value;
    final events = eventsAsync.value;
    if (g == null || events == null) {
      return FTPage(showBack: false, title: 'Timeline', actions: actions, body: const LoadingView());
    }

    final builder = TimelineBuilder(
      graph: g,
      events: events,
      stories: ref.watch(storiesProvider).value ?? const [],
      storyPeople: ref.watch(storyPeopleProvider).value ?? const [],
      media: ref.watch(mediaProvider).value ?? const [],
      mediaPeople: ref.watch(mediaPeopleProvider).value ?? const [],
      branches: ref.watch(branchesProvider).value ?? const [],
      branchMembers: ref.watch(branchMembersProvider).value ?? const [],
    );

    // A scope pointing at a removed person / branch falls back to everyone.
    if (_scope.kind == TimelineScopeKind.person && !g.contains(_scope.id!) ||
        _scope.kind == TimelineScopeKind.branch &&
            !builder.branches.any((b) => b.id == _scope.id)) {
      _scope = const TimelineScope.family();
    }

    final everything = builder.build(scope: _scope);
    final items = everything.where((i) => _categories.contains(i.category)).toList();
    _sections = TimelineBuilder.group(items);
    final photoIds = [
      for (final i in items)
        if (i.target == TimelineTarget.media) i.targetId,
    ];
    final accentKey = (_selectedKey != null && items.any((i) => i.key == _selectedKey))
        ? _selectedKey
        : items.firstOrNull?.key;

    final pad = context.pagePadding;
    final totalEmpty = everything.isEmpty && _scope.kind == TimelineScopeKind.family;

    return FTPage(
      showBack: false,
      title: 'Timeline',
      actions: actions,
      headerBottom: _sections.length > 1 ? _decadeBar(context) : null,
      body: totalEmpty
          ? Padding(
              padding: EdgeInsets.only(bottom: AppShell.contentInset(context) - 40),
              child: EmptyState(
                icon: AppIcons.timeline,
                title: 'Your timeline is empty',
                message: 'Add birth dates, marriages, events, dated stories or photos and they will appear here in order.',
                actionLabel: 'Add event',
                onAction: () => context.push(Routes.newEvent()),
              ),
            )
          : CustomScrollView(
              controller: _scroll,
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, 0),
                    child: ContentWidth(child: _scopePill(context, g, builder)),
                  ),
                ),
                SliverToBoxAdapter(child: _categoryChips(context, everything)),
                if (items.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: EdgeInsets.only(bottom: AppShell.contentInset(context)),
                      child: EmptyState(
                        icon: AppIcons.filter,
                        title: 'Nothing to show',
                        message: _scope.kind == TimelineScopeKind.family
                            ? 'No milestones match these filters.'
                            : 'No dated milestones for ${_scopeLabel(g)} with these filters.',
                        compact: true,
                      ),
                    ),
                  )
                else
                  for (var s = 0; s < _sections.length; s++) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: pad),
                        child: ContentWidth(
                          child: TimelineDecadeHeader(
                            key: _sectionKey(_idOf(_sections[s].decade)),
                            section: _sections[s],
                            first: s == 0,
                          ),
                        ),
                      ),
                    ),
                    _sectionList(context, _sections[s], isLastSection: s == _sections.length - 1,
                        accentKey: accentKey, photoIds: photoIds),
                  ],
                SliverToBoxAdapter(child: SizedBox(height: AppShell.contentInset(context))),
              ],
            ),
    );
  }

  Widget _sectionList(
    BuildContext context,
    TimelineSection section, {
    required bool isLastSection,
    required String? accentKey,
    required List<String> photoIds,
  }) {
    final pad = context.pagePadding;
    final rows = section.rows;
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      sliver: SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final row = rows[i];
          final Widget child = switch (row) {
            TimelineYearRow() => TimelineYearHeader(row: row),
            TimelineItemRow(:final item) => TimelineItemTile(
                item: item,
                accent: item.key == accentKey,
                selected: item.key == _selectedKey,
                lineBottom: !(isLastSection && i == rows.length - 1),
                onTap: () => _open(item, photoIds),
              ),
          };
          return ContentWidth(child: FadeSlideIn(index: i < 10 ? i : 0, child: child));
        },
      ),
    );
  }

  Widget _scopePill(BuildContext context, FamilyGraph g, TimelineBuilder builder) {
    final c = context.ft;
    final label = _scopeLabel(g);
    return Row(
      children: [
        Expanded(
          child: FTPill(
            onTap: () => _pickScope(g, builder),
            semanticLabel: 'Showing $label. Change scope',
            padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
            child: Row(
              children: [
                IconBadge(icon: _scopeIcon, size: 40, accent: _scope.kind != TimelineScopeKind.family),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Showing', style: context.tx.caption),
                      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                    ],
                  ),
                ),
                Icon(AppIcons.chevronDown, size: 18, color: c.text3),
              ],
            ),
          ),
        ),
        if (_scope.kind != TimelineScopeKind.family) ...[
          const SizedBox(width: Gap.xs),
          FTIconButton(
            icon: AppIcons.close,
            tooltip: 'Show entire family',
            onTap: () => setState(() {
              _scope = const TimelineScope.family();
              _selectedKey = null;
            }),
          ),
        ],
      ],
    );
  }

  Widget _categoryChips(BuildContext context, List<TimelineItem> all) {
    final pad = context.pagePadding;
    final counts = <TimelineCategory, int>{};
    for (final i in all) {
      counts[i.category] = (counts[i.category] ?? 0) + 1;
    }
    final allSelected = _categories.length == TimelineCategory.values.length;
    return SizedBox(
      height: 60,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(pad, Gap.sm, pad, Gap.sm),
        children: [
          FTChip(
            label: 'All',
            selected: allSelected,
            onTap: () => setState(() => _categories = TimelineCategory.values.toSet()),
          ),
          for (final cat in TimelineCategory.values) ...[
            const SizedBox(width: Gap.xs),
            FTChip(
              label: counts[cat] == null ? cat.label : '${cat.label} · ${counts[cat]}',
              icon: categoryIcon(cat),
              selected: !allSelected && _categories.contains(cat),
              onTap: () => _toggleCategory(cat),
            ),
          ],
        ],
      ),
    );
  }

  Widget _decadeBar(BuildContext context) {
    final pad = context.pagePadding;
    final active = _activeSection ?? _idOf(_sections.first.decade);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(pad, 4, pad, 8),
        children: [
          for (final s in _sections) ...[
            FTChip(
              key: _chipKey(_idOf(s.decade)),
              label: s.label,
              icon: s.decade == null ? AppIcons.hourglass : null,
              selected: active == _idOf(s.decade),
              onTap: () => _jumpTo(_idOf(s.decade)),
            ),
            const SizedBox(width: Gap.xs),
          ],
        ],
      ),
    );
  }
}
