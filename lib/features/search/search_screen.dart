import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../members/widgets/person_widgets.dart';
import 'search_engine.dart';
import 'text_normalize.dart';

/// Search index for the active tree; rebuilt when any searchable data
/// changes. Sections that are still loading simply contribute nothing.
final searchEngineProvider = Provider.autoDispose<AsyncValue<SearchEngine>>((ref) {
  final g = ref.watch(familyGraphProvider);
  final events = ref.watch(eventsProvider).value ?? const <FamilyEvent>[];
  final stories = ref.watch(storiesProvider).value ?? const <Story>[];
  final branches = ref.watch(branchesProvider).value ?? const <FamilyBranch>[];
  final sources = ref.watch(sourcesProvider).value ?? const <Source>[];
  if (g.hasError) return AsyncError(g.error!, g.stackTrace ?? StackTrace.empty);
  final graph = g.value;
  if (graph == null) return const AsyncLoading();
  return AsyncData(SearchEngine(
    graph: graph,
    events: events,
    stories: stories,
    branches: branches,
    sources: sources,
  ));
});

/// Recent searches for this app session (kept in memory only).
class RecentSearches extends Notifier<List<String>> {
  static const max = 8;

  @override
  List<String> build() => const [];

  void add(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    final k = normalizeKey(q);
    state = [q, ...state.where((x) => normalizeKey(x) != k)].take(max).toList();
  }

  void remove(String query) => state = [...state.where((x) => x != query)];

  void clear() => state = const [];
}

final recentSearchesProvider = NotifierProvider<RecentSearches, List<String>>(RecentSearches.new);

enum _Section {
  people('People', AppIcons.people),
  places('Places', AppIcons.location),
  events('Events', AppIcons.event),
  stories('Stories', AppIcons.story),
  branches('Branches', AppIcons.branch),
  sources('Sources', AppIcons.source);

  const _Section(this.label, this.icon);
  final String label;
  final IconData icon;
}

sealed class _Item {
  const _Item();
}

class _HeaderItem extends _Item {
  const _HeaderItem(this.section, this.count, this.expandable);
  final _Section section;
  final int count;
  final bool expandable;
}

class _ResultItem extends _Item {
  const _ResultItem(this.result);
  final Object result;
}

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  static const _collapsedCount = 5;
  static const _debounce = Duration(milliseconds: 220);

  final _ctl = TextEditingController();
  Timer? _timer;
  String _query = '';
  final Set<_Section> _expanded = {};

  SearchEngine? _cachedEngine;
  String? _cachedQuery;
  SearchResults _cached = SearchResults.empty;

  @override
  void dispose() {
    _timer?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _timer?.cancel();
    if (v.trim().isEmpty) {
      setState(() {
        _query = '';
        _expanded.clear();
      });
      return;
    }
    _timer = Timer(_debounce, () {
      if (!mounted) return;
      setState(() {
        _query = v.trim();
        _expanded.clear();
      });
    });
  }

  void _useRecent(String q) {
    _timer?.cancel();
    _ctl.value = TextEditingValue(text: q, selection: TextSelection.collapsed(offset: q.length));
    setState(() {
      _query = q;
      _expanded.clear();
    });
  }

  SearchResults _results(SearchEngine engine) {
    if (identical(engine, _cachedEngine) && _cachedQuery == _query) return _cached;
    _cachedEngine = engine;
    _cachedQuery = _query;
    return _cached = engine.search(_query);
  }

  void _open(String route) {
    ref.read(recentSearchesProvider.notifier).add(_query);
    FocusScope.of(context).unfocus();
    context.push(route);
  }

  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(searchEngineProvider);
    return FTPage(
      title: 'Search',
      headerBottom: Padding(
        padding: EdgeInsets.fromLTRB(context.pagePadding, Gap.xxs, context.pagePadding, Gap.sm),
        child: ContentWidth(
          child: FTSearchField(
            controller: _ctl,
            autofocus: true,
            hint: 'People, places, events, stories…',
            onChanged: _onChanged,
          ),
        ),
      ),
      body: engine.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(searchEngineProvider)),
        data: (engine) => _query.isEmpty ? _idle(context) : _resultsView(context, engine),
      ),
    );
  }

  // ------------------------------------------------------------- idle

  Widget _idle(BuildContext context) {
    final recent = ref.watch(recentSearchesProvider);
    if (recent.isEmpty) {
      return const SingleChildScrollView(
        child: EmptyState(
          icon: AppIcons.search,
          title: 'Search your family',
          message: 'Find people, places, events, stories, branches and sources. '
              'Try a name, a town or a year such as 1950.',
        ),
      );
    }
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(context.pagePadding, Gap.sm, context.pagePadding, FTPage.bottomInset(context)),
      children: [
        ContentWidth(
          child: FadeSlideIn(
            child: FTCard(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.sm, Gap.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeader(
                    'Recent searches',
                    action: 'Clear',
                    onAction: () => ref.read(recentSearchesProvider.notifier).clear(),
                  ),
                  for (final q in recent)
                    FTListRow(
                      icon: AppIcons.clock,
                      title: q,
                      onTap: () => _useRecent(q),
                      trailing: FTIconButton(
                        icon: AppIcons.close,
                        size: 36,
                        tooltip: 'Remove “$q” from recent searches',
                        onTap: () => ref.read(recentSearchesProvider.notifier).remove(q),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: Gap.lg),
        ContentWidth(
          child: FadeSlideIn(
            index: 1,
            child: Text(
              'Tip: type a four-digit year to find people born or died that year.',
              style: context.tx.caption,
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------- results

  List<Object> _sectionResults(SearchResults r, _Section s) => switch (s) {
        _Section.people => r.people,
        _Section.places => r.places,
        _Section.events => r.events,
        _Section.stories => r.stories,
        _Section.branches => r.branches,
        _Section.sources => r.sources,
      };

  Widget _resultsView(BuildContext context, SearchEngine engine) {
    final r = _results(engine);
    if (r.isEmpty) {
      return SingleChildScrollView(
        child: EmptyState(
          icon: AppIcons.search,
          title: 'No results for “$_query”',
          message: 'Check the spelling, or try fewer or different words.',
        ),
      );
    }
    final items = <_Item>[];
    for (final s in _Section.values) {
      final list = _sectionResults(r, s);
      if (list.isEmpty) continue;
      final expandable = list.length > _collapsedCount;
      items.add(_HeaderItem(s, list.length, expandable));
      final shown = _expanded.contains(s) ? list : list.take(_collapsedCount);
      for (final x in shown) {
        items.add(_ResultItem(x));
      }
    }
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(context.pagePadding - 8, Gap.xs, context.pagePadding - 8, FTPage.bottomInset(context)),
      itemCount: items.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, Gap.sm),
            child: Semantics(
              liveRegion: true,
              child: Text(
                r.total == 1 ? '1 result' : '${r.total} results',
                style: context.tx.caption,
              ),
            ),
          );
        }
        final item = items[i - 1];
        return ContentWidth(
          child: FadeSlideIn(
            key: ValueKey('$_query-$i'),
            index: math.min(i, 8),
            child: switch (item) {
              _HeaderItem() => _header(context, item),
              _ResultItem() => _row(context, engine, r, item.result),
            },
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, _HeaderItem h) {
    final open = _expanded.contains(h.section);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, Gap.md, 0, Gap.xxs),
      child: SectionHeader(
        h.section.label,
        trailing: Padding(
          padding: const EdgeInsets.only(left: Gap.xs, right: Gap.xs),
          child: FTTag('${h.count}', accent: true),
        ),
        action: h.expandable ? (open ? 'Show less' : 'See all') : null,
        onAction: () => setState(() => open ? _expanded.remove(h.section) : _expanded.add(h.section)),
      ),
    );
  }

  Widget _row(BuildContext context, SearchEngine engine, SearchResults r, Object result) {
    final tokens = r.tokens;
    switch (result) {
      case PersonResult(:final person, :final field):
        return PersonTile(
          person: person,
          subtitle: _personContext(person, field),
          onTap: () => _open(Routes.person(person.id)),
          trailing: field == PersonMatchField.name ? null : FTTag(field.label),
        );
      case final PlaceResult place:
        final parts = [
          if (place.bornHere.isNotEmpty) '${place.bornHere.length} born',
          if (place.diedHere.isNotEmpty) '${place.diedHere.length} died',
          if (place.eventIds.isNotEmpty)
            '${place.eventIds.length} ${place.eventIds.length == 1 ? 'event' : 'events'}',
        ];
        return _ResultRow(
          icon: AppIcons.location,
          title: place.place,
          subtitle: parts.join(' · '),
          tokens: tokens,
          onTap: () => _openPlace(engine, place),
        );
      case EventResult(:final event):
        final date = FuzzyDate.tryParse(event.date)?.format();
        final sub = [date, event.location, event.type.label]
            .whereType<String>()
            .where((s) => s.trim().isNotEmpty)
            .join(' · ');
        return _ResultRow(
          icon: AppIcons.forEvent(event.type),
          title: event.title,
          subtitle: sub,
          highlightSubtitle: true,
          tokens: tokens,
          onTap: () => _open(Routes.event(event.id)),
        );
      case StoryResult(:final story, :final snippet):
        final date = FuzzyDate.tryParse(story.historicalDate)?.format();
        return _ResultRow(
          icon: AppIcons.story,
          title: story.title,
          subtitle: snippet ?? date ?? 'Story',
          highlightSubtitle: snippet != null,
          subtitleLines: 2,
          tokens: tokens,
          onTap: () => _open(Routes.story(story.id)),
        );
      case BranchResult(:final branch):
        return _ResultRow(
          icon: AppIcons.branch,
          title: branch.name,
          subtitle: (branch.description ?? '').trim().isEmpty ? 'Family branch' : branch.description!.trim(),
          highlightSubtitle: true,
          tokens: tokens,
          dot: branch.colorValue == null ? null : Color(branch.colorValue!),
          onTap: () => _open(Routes.branches),
        );
      case SourceResult(:final source):
        final sub = [source.type.label, source.author, source.repository]
            .whereType<String>()
            .where((s) => s.trim().isNotEmpty)
            .join(' · ');
        return _ResultRow(
          icon: AppIcons.forSource(source.type),
          title: source.title,
          subtitle: sub,
          highlightSubtitle: true,
          tokens: tokens,
          onTap: () => _open(Routes.source(source.id)),
        );
    }
    return const SizedBox.shrink();
  }

  String? _personContext(Person p, PersonMatchField field) {
    final life = p.lifespanLabel;
    String join(String s) => life.isEmpty ? s : '$s · $life';
    switch (field) {
      case PersonMatchField.name:
        return null; // PersonTile default: lifespan · birthplace
      case PersonMatchField.birthName:
        return join('Birth name: ${p.birthName!.trim()}');
      case PersonMatchField.nickname:
        return join('Known as “${p.nickname!.trim()}”');
      case PersonMatchField.birthYear:
        final place = (p.birthPlace ?? '').trim();
        return 'Born ${p.birth?.format() ?? ''}${place.isEmpty ? '' : ' · $place'}';
      case PersonMatchField.deathYear:
        final place = (p.deathPlace ?? '').trim();
        return 'Died ${p.death?.format() ?? ''}${place.isEmpty ? '' : ' · $place'}';
    }
  }

  Future<void> _openPlace(SearchEngine engine, PlaceResult place) async {
    ref.read(recentSearchesProvider.notifier).add(_query);
    FocusScope.of(context).unfocus();
    final g = engine.graph;
    final born = place.bornHere.toSet();
    final died = place.diedHere.toSet();
    final people = place.personIds.where(g.contains).map((id) => g[id]!).toList()
      ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    final events = [for (final id in place.eventIds) ?engine.eventsById[id]];
    final route = await showFTSheet<String>(
      context,
      title: place.place,
      scrollable: false,
      builder: (ctx) {
        final rows = <Widget>[
          if (people.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.xs, Gap.xs, Gap.xxs),
              child: SectionHeader('People', trailing: FTTag('${people.length}', accent: true)),
            ),
          for (final p in people)
            PersonTile(
              person: p,
              subtitle: [
                if (born.contains(p.id)) 'Born here',
                if (died.contains(p.id)) 'Died here',
                if (p.lifespanLabel.isNotEmpty) p.lifespanLabel,
              ].join(' · '),
              onTap: () => Navigator.of(ctx).pop(Routes.person(p.id)),
            ),
          if (events.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.md, Gap.xs, Gap.xxs),
              child: SectionHeader('Events', trailing: FTTag('${events.length}', accent: true)),
            ),
          for (final e in events)
            _ResultRow(
              icon: AppIcons.forEvent(e.type),
              title: e.title,
              subtitle: [FuzzyDate.tryParse(e.date)?.format(), e.type.label]
                  .whereType<String>()
                  .where((s) => s.isNotEmpty)
                  .join(' · '),
              tokens: const [],
              onTap: () => Navigator.of(ctx).pop(Routes.event(e.id)),
            ),
        ];
        return ListView.builder(
          shrinkWrap: rows.length < 30,
          padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.lg),
          itemCount: rows.length,
          itemBuilder: (_, i) => rows[i],
        );
      },
    );
    if (route != null && mounted) context.push(route);
  }
}

/// Generic search result row: inset icon, highlighted title and subtitle.
class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tokens,
    required this.onTap,
    this.highlightSubtitle = false,
    this.subtitleLines = 1,
    this.dot,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<String> tokens;
  final VoidCallback onTap;
  final bool highlightSubtitle;
  final int subtitleLines;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Pressable(
      onTap: onTap,
      scale: 0.985,
      semanticLabel: subtitle.isEmpty ? title : '$title, $subtitle',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        child: Row(
          children: [
            IconBadge(icon: icon, size: 46),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      if (dot != null) ...[
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: HighlightText(
                          title,
                          tokens: tokens,
                          style: context.tx.bodyStrong,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    HighlightText(
                      subtitle,
                      tokens: highlightSubtitle ? tokens : const [],
                      style: context.tx.caption,
                      maxLines: subtitleLines,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: Gap.xs),
            Icon(AppIcons.forward, size: 18, color: c.text3),
          ],
        ),
      ),
    );
  }
}

/// Text with the parts matching [tokens] emphasised in the accent colour.
class HighlightText extends StatelessWidget {
  const HighlightText(
    this.text, {
    super.key,
    required this.tokens,
    required this.style,
    this.maxLines = 1,
  });

  final String text;
  final List<String> tokens;
  final TextStyle style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final ranges = matchRanges(text, tokens);
    if (ranges.isEmpty) {
      return Text(text, style: style, maxLines: maxLines, overflow: TextOverflow.ellipsis);
    }
    final c = context.ft;
    final hi = style.copyWith(
      color: c.accent,
      fontWeight: FontWeight.w600,
      backgroundColor: c.accent.withValues(alpha: 0.10),
    );
    final spans = <TextSpan>[];
    var pos = 0;
    for (final (s, e) in ranges) {
      if (s > pos) spans.add(TextSpan(text: text.substring(pos, s)));
      spans.add(TextSpan(text: text.substring(s, e), style: hi));
      pos = e;
    }
    if (pos < text.length) spans.add(TextSpan(text: text.substring(pos)));
    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}
