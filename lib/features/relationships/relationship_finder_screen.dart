import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../family/domain/kinship.dart';
import '../members/widgets/person_widgets.dart';

/// Pick two people and see every way they are related, with the path of
/// connections that proves it.
class RelationshipFinderScreen extends ConsumerStatefulWidget {
  const RelationshipFinderScreen({super.key, this.aId, this.bId});
  final String? aId;
  final String? bId;

  @override
  ConsumerState<RelationshipFinderScreen> createState() => _RelationshipFinderScreenState();
}

class _RelationshipFinderScreenState extends ConsumerState<RelationshipFinderScreen> {
  String? _a;
  String? _b;

  @override
  void initState() {
    super.initState();
    _a = widget.aId;
    _b = widget.bId;
  }

  Future<void> _pick(bool first) async {
    final id = await pickPerson(context, title: first ? 'First person' : 'Second person');
    if (id != null) setState(() => first ? _a = id : _b = id);
  }

  @override
  Widget build(BuildContext context) {
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final home = ref.watch(homePersonIdProvider);
    _b ??= (home != null && home != _a) ? home : null;
    final a = _a == null ? null : g[_a!];
    final b = _b == null ? null : g[_b!];
    final results = (a != null && b != null) ? KinshipCalculator(g).between(a.id, b.id) : const <Kinship>[];
    final pad = context.pagePadding;

    return FTPage(
      title: 'Relationship finder',
      body: ListView(
        padding: EdgeInsets.fromLTRB(pad, Gap.sm, pad, FTPage.bottomInset(context)),
        children: [
          ContentWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('How are they related?', style: context.tx.headline),
                const SizedBox(height: 4),
                Text('Calculated only from the parent and partner connections in your tree.', style: context.tx.body),
                const SizedBox(height: Gap.xl),
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Column(
                      children: [
                        _PersonSlot(label: 'Person A', person: a, onTap: () => _pick(true)),
                        const SizedBox(height: 12),
                        _PersonSlot(label: 'Person B', person: b, onTap: () => _pick(false)),
                      ],
                    ),
                    Positioned(
                      right: 18,
                      child: FTIconButton(
                        icon: AppIcons.swap,
                        tooltip: 'Swap people',
                        accent: true,
                        size: 44,
                        onTap: () => setState(() {
                          final t = _a;
                          _a = _b;
                          _b = t;
                        }),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Gap.xl),
                if (a == null || b == null)
                  const EmptyState(icon: AppIcons.path, title: 'Choose two people', compact: true,
                      message: 'For example yourself and a distant cousin.')
                else if (results.isEmpty)
                  FTCard(
                    child: Column(
                      children: [
                        const IconBadge(icon: AppIcons.info, size: 48),
                        const SizedBox(height: 12),
                        Text('No connection found', style: context.tx.section),
                        const SizedBox(height: 4),
                        Text(
                          '${a.shortName} and ${b.shortName} aren’t connected through the relationships recorded in this tree yet.',
                          textAlign: TextAlign.center,
                          style: context.tx.body,
                        ),
                      ],
                    ),
                  )
                else ...[
                  if (results.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Gap.sm),
                      child: Text('${a.shortName} and ${b.shortName} are related in ${results.length} ways:',
                          style: context.tx.caption),
                    ),
                  for (var i = 0; i < results.length; i++)
                    FadeSlideIn(index: i, child: _ResultCard(kin: results[i], graph: g, a: a, b: b, primary: i == 0)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PersonSlot extends StatelessWidget {
  const _PersonSlot({required this.label, required this.person, required this.onTap});
  final String label;
  final Person? person;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FTPill(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(6, 6, 80, 6),
      semanticLabel: '$label: ${person?.displayName ?? 'not chosen'}',
      child: Row(
        children: [
          person == null
              ? const IconBadge(icon: AppIcons.personAdd, size: 48)
              : PersonAvatarFor(person!, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: context.tx.caption),
                Text(person?.displayName ?? 'Tap to choose',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.kin, required this.graph, required this.a, required this.b, required this.primary});
  final Kinship kin;
  final FamilyGraph graph;
  final Person a;
  final Person b;
  final bool primary;

  String _step(String from, String to) {
    if (graph.parentIds(from).contains(to)) return 'child of';
    if (graph.childIds(from).contains(to)) return 'parent of';
    if (graph.partnerIds(from).contains(to)) return 'partner of';
    return 'related to';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: FTCard(
        highlighted: primary,
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconBadge(icon: AppIcons.path, accent: primary, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(kin.label, style: context.tx.title.copyWith(color: primary ? c.accent : null)),
                      Text(kin.describe(graph, a.id, b.id), style: context.tx.body),
                    ],
                  ),
                ),
              ],
            ),
            if (kin.note != null) ...[
              const SizedBox(height: 8),
              FTTag(kin.note!, icon: AppIcons.info),
            ],
            if (kin.path.length > 1) ...[
              const HairLine(vertical: Gap.md),
              Text('Connection path', style: context.tx.caption),
              const SizedBox(height: 8),
              for (var i = 0; i < kin.path.length; i++)
                if (graph[kin.path[i]] != null) ...[
                  PersonTile(
                    person: graph[kin.path[i]]!,
                    avatarSize: 38,
                    subtitle: i < kin.path.length - 1
                        ? '${_step(kin.path[i], kin.path[i + 1])} ${graph[kin.path[i + 1]]?.shortName ?? ''}'
                        : graph[kin.path[i]]!.lifespanLabel,
                    onTap: () => context.push(Routes.person(kin.path[i])),
                  ),
                  if (i < kin.path.length - 1)
                    Padding(
                      padding: const EdgeInsets.only(left: 26),
                      child: Container(width: 1.5, height: 12, color: c.accent.withValues(alpha: 0.5)),
                    ),
                ],
            ],
          ],
        ),
      ),
    );
  }
}
