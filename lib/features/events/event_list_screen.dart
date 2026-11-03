import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/models/enums.dart';
import '../../core/repositories/content_repository.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import 'event_logic.dart';
import 'event_widgets.dart';

/// All family events: search, type filters and year groups (undated last).
class EventListScreen extends ConsumerStatefulWidget {
  const EventListScreen({super.key});

  @override
  ConsumerState<EventListScreen> createState() => _EventListScreenState();
}

class _EventListScreenState extends ConsumerState<EventListScreen> {
  String _query = '';
  EventType? _type;

  void _add() => context.push(Routes.newEvent());

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(eventsWithPeopleProvider);
    return FTPage(
      title: 'Events',
      actions: [
        FTIconButton(icon: AppIcons.add, tooltip: 'Add event', onTap: _add),
      ],
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e),
        data: (all) => all.isEmpty
            ? EmptyState(
                icon: AppIcons.event,
                title: 'No events yet',
                message: 'Record weddings, graduations, moves, reunions and other milestones your family remembers.',
                actionLabel: 'Add event',
                onAction: _add,
              )
            : _buildList(context, all),
      ),
    );
  }

  Widget _buildList(BuildContext context, List<EventWithPeople> all) {
    final pad = context.pagePadding;
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final types = EventQuery.typesIn(all);
    final type = types.contains(_type) ? _type : null;
    final groups = EventQuery.groupByYear(
        EventQuery.filter(all, query: _query, type: type, graph: g));

    // Flatten into header / card rows for a single lazy list.
    final rows = <Object>[];
    for (final grp in groups) {
      rows.add(grp);
      rows.addAll(grp.events);
    }

    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverToBoxAdapter(
          child: ContentWidth(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, Gap.sm),
              child: FTSearchField(
                hint: 'Search events, places or people',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          ),
        ),
        if (types.length > 1)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: pad),
                children: [
                  FTChip(
                    label: 'All · ${all.length}',
                    selected: type == null,
                    onTap: () => setState(() => _type = null),
                  ),
                  for (final t in types) ...[
                    const SizedBox(width: Gap.xs),
                    FTChip(
                      label: t.label,
                      icon: AppIcons.forEvent(t),
                      selected: type == t,
                      onTap: () => setState(() => _type = type == t ? null : t),
                    ),
                  ],
                ],
              ),
            ),
          ),
        if (rows.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: AppIcons.search,
              title: 'No matching events',
              message: 'Try another word or clear the filter.',
              compact: true,
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, FTPage.bottomInset(context)),
            sliver: SliverList.builder(
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final row = rows[i];
                final Widget child;
                if (row is EventYearGroup) {
                  child = Padding(
                    padding: EdgeInsets.only(top: i == 0 ? Gap.xs : Gap.lg, bottom: Gap.xs),
                    child: SectionHeader(
                      row.label,
                      trailing: FTTag('${row.events.length}'),
                    ),
                  );
                } else {
                  final e = row as EventWithPeople;
                  child = Padding(
                    padding: const EdgeInsets.only(bottom: Gap.sm),
                    child: EventCard(
                      item: e,
                      onTap: () => context.push(Routes.event(e.event.id)),
                    ),
                  );
                }
                return ContentWidth(child: FadeSlideIn(index: i, child: child));
              },
            ),
          ),
      ],
    );
  }
}
