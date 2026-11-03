import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import 'duplicate_detector.dart';
import 'widgets/person_widgets.dart';

/// Settings key holding the JSON list of pair keys marked "not a duplicate".
const dismissedDuplicatesKey = 'dup.dismissed';

enum _CompareOutcome { merged, dismissed }

class DuplicatesScreen extends ConsumerStatefulWidget {
  const DuplicatesScreen({super.key});

  @override
  ConsumerState<DuplicatesScreen> createState() => _DuplicatesScreenState();
}

class _DuplicatesScreenState extends ConsumerState<DuplicatesScreen> {
  List<DuplicateCandidate>? _candidates;
  Set<String> _dismissed = {};
  bool _settingsLoaded = false;
  bool _running = false;
  Object? _error;
  int _run = 0;
  Timer? _rerun;

  @override
  void initState() {
    super.initState();
    Future.microtask(_init);
  }

  @override
  void dispose() {
    _rerun?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final settings = await ref.read(systemRepoProvider).loadSettings();
      final raw = settings[dismissedDuplicatesKey];
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) _dismissed = {for (final x in list) x.toString()};
      }
    } catch (_) {
      // A corrupt value only means previously dismissed pairs show again.
    }
    _settingsLoaded = true;
    await _detect();
  }

  Future<void> _detect() async {
    if (!_settingsLoaded || !mounted) return;
    final g = ref.read(familyGraphProvider).value;
    if (g == null) return; // the graph listener re-runs once it loads
    final token = ++_run;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final result = await findDuplicatesInBackground(g, dismissed: {..._dismissed});
      if (!mounted || token != _run) return;
      setState(() {
        _candidates = result;
        _running = false;
      });
    } catch (e) {
      if (!mounted || token != _run) return;
      setState(() {
        _error = e;
        _running = false;
      });
    }
  }

  Future<void> _persistDismissed() =>
      ref.read(systemRepoProvider).putSetting(dismissedDuplicatesKey, jsonEncode(_dismissed.toList()..sort()));

  Future<void> _dismiss(DuplicateCandidate c) async {
    setState(() {
      _dismissed.add(c.key);
      _candidates = [...?_candidates?.where((x) => x.key != c.key)];
    });
    try {
      await _persistDismissed();
      if (!mounted) return;
      showFTToast(
        context,
        'Marked as not a duplicate',
        actionLabel: 'Undo',
        onAction: () async {
          _dismissed.remove(c.key);
          await _persistDismissed();
          await _detect();
        },
      );
    } catch (e) {
      if (mounted) showFTToast(context, friendlyError(e), error: true);
    }
  }

  Future<void> _resetDismissed(Set<String> relevant) async {
    setState(() => _dismissed.removeAll(relevant));
    try {
      await _persistDismissed();
      await _detect();
      if (mounted) {
        showFTToast(context, relevant.length == 1 ? '1 dismissed pair restored' : '${relevant.length} dismissed pairs restored');
      }
    } catch (e) {
      if (mounted) showFTToast(context, friendlyError(e), error: true);
    }
  }

  Future<void> _compare(DuplicateCandidate c) async {
    final outcome = await showFTSheet<_CompareOutcome>(
      context,
      title: 'Compare',
      builder: (_) => _CompareSheet(candidate: c),
    );
    if (!mounted || outcome == null) return;
    switch (outcome) {
      case _CompareOutcome.dismissed:
        await _dismiss(c);
      case _CompareOutcome.merged:
        // Drop pairs that involved either person until detection re-runs.
        setState(() {
          _candidates = [
            ...?_candidates?.where((x) => !{x.aId, x.bId}.any({c.aId, c.bId}.contains)),
          ];
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(familyGraphProvider, (prev, next) {
      final g = next.value;
      if (g == null || identical(prev?.value, g)) return;
      _rerun?.cancel();
      _rerun = Timer(const Duration(milliseconds: 400), _detect);
    });
    final g = ref.watch(familyGraphProvider).value;
    final candidates = _candidates;
    final relevantDismissed = g == null
        ? <String>{}
        : {
            for (final k in _dismissed)
              if (k.split('|') case [final a, final b] when g.contains(a) && g.contains(b)) k,
          };

    Widget body;
    if (_error != null && candidates == null) {
      body = ErrorView(error: _error!, onRetry: _detect);
    } else if (g == null || candidates == null) {
      body = const _Scanning();
    } else {
      final items = <Widget>[
        _IntroCard(running: _running, count: candidates.length, people: g.size),
        if (candidates.isEmpty)
          EmptyState(
            icon: AppIcons.checkCircle,
            title: 'No likely duplicates',
            message: g.size < 2
                ? 'Add more family members to check for duplicates.'
                : 'We compared names, birth details and relationships and found nothing that looks like the same person twice.',
          )
        else
          for (final c in candidates)
            if (g.contains(c.aId) && g.contains(c.bId))
              _CandidateCard(
                candidate: c,
                a: g[c.aId]!,
                b: g[c.bId]!,
                onCompare: () => _compare(c),
                onDismiss: () => _dismiss(c),
              ),
        if (relevantDismissed.isNotEmpty)
          Center(
            child: FTTextAction(
              relevantDismissed.length == 1
                  ? 'Show 1 dismissed pair again'
                  : 'Show ${relevantDismissed.length} dismissed pairs again',
              onTap: () => _resetDismissed(relevantDismissed),
            ),
          ),
      ];
      body = RefreshIndicator(
        color: context.ft.accent,
        onRefresh: _detect,
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(context.pagePadding, Gap.xs, context.pagePadding, FTPage.bottomInset(context)),
          itemCount: items.length,
          itemBuilder: (context, i) => ContentWidth(
            child: Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: FadeSlideIn(index: i, child: items[i]),
            ),
          ),
        ),
      );
    }

    return FTPage(
      title: 'Possible duplicates',
      actions: [
        FTIconButton(
          icon: AppIcons.refresh,
          tooltip: 'Check again',
          onTap: _running ? null : _detect,
        ),
      ],
      body: body,
    );
  }
}

class _Scanning extends StatelessWidget {
  const _Scanning();

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LoadingView(),
            const SizedBox(height: Gap.md),
            Text('Looking for duplicates…', style: context.tx.caption),
          ],
        ),
      );
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.running, required this.count, required this.people});
  final bool running;
  final int count;
  final int people;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return FTCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const IconBadge(icon: AppIcons.duplicate, size: 44),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  running
                      ? 'Checking $people people…'
                      : (count == 0
                          ? 'All clear'
                          : '$count possible ${count == 1 ? 'duplicate' : 'duplicates'}'),
                  style: context.tx.section,
                ),
                const SizedBox(height: Gap.xxs),
                Text(
                  'Suggestions are based on similar names, birth details, places and shared relatives. '
                  'Nothing is merged unless you choose to.',
                  style: context.tx.caption,
                ),
              ],
            ),
          ),
          if (running) ...[
            const SizedBox(width: Gap.sm),
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
            ),
          ],
        ],
      ),
    );
  }
}

/// Mint confidence meter ("Match ▰▰▰▱ 82%").
class _ScoreMeter extends StatelessWidget {
  const _ScoreMeter({required this.score});
  final double score;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final pct = (score * 100).round();
    final label = pct >= 80 ? 'Strong match' : (pct >= 65 ? 'Likely match' : 'Possible match');
    return Semantics(
      label: '$label, $pct percent',
      excludeSemantics: true,
      child: Row(
        children: [
          Flexible(
            flex: 2,
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.caption),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            flex: 3,
            child: Container(
              height: 8,
              decoration: BoxDecoration(
                color: c.text.withValues(alpha: c.isDark ? 0.06 : 0.07),
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: score.clamp(0.04, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [c.accent2, c.accentHi]),
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: Gap.sm),
          Text('$pct%', style: context.tx.label.copyWith(color: c.accent, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _CandidateCard extends StatelessWidget {
  const _CandidateCard({
    required this.candidate,
    required this.a,
    required this.b,
    required this.onCompare,
    required this.onDismiss,
  });

  final DuplicateCandidate candidate;
  final Person a;
  final Person b;
  final VoidCallback onCompare;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    Widget person(Person p) => Row(
          children: [
            PersonAvatarFor(p, size: 42, showGender: true),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                  if (p.lifespanLabel.isNotEmpty || (p.birthPlace ?? '').isNotEmpty)
                    Text(
                      [p.lifespanLabel, (p.birthPlace ?? '').trim()].where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.tx.caption,
                    ),
                ],
              ),
            ),
          ],
        );

    return FTCard(
      onTap: onCompare,
      semanticLabel: '${a.displayName} and ${b.displayName}, ${candidate.percent} percent match',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          person(a),
          Padding(
            padding: const EdgeInsets.only(left: 13, top: 2, bottom: 2),
            child: Icon(AppIcons.arrowsLeftRight, size: 16, color: c.text3),
          ),
          person(b),
          const SizedBox(height: Gap.md),
          _ScoreMeter(score: candidate.score),
          const SizedBox(height: Gap.sm),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final r in candidate.reasons) FTTag(r, accent: r == candidate.reasons.first),
            ],
          ),
          const SizedBox(height: Gap.md),
          Row(
            children: [
              Expanded(
                child: FTButton(
                  label: 'Not a duplicate',
                  kind: FTButtonKind.ghost,
                  height: 46,
                  expand: true,
                  onTap: onDismiss,
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: FTButton(
                  label: 'Compare',
                  icon: AppIcons.merge,
                  height: 46,
                  expand: true,
                  onTap: onCompare,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================ compare

class _CompareSheet extends ConsumerStatefulWidget {
  const _CompareSheet({required this.candidate});
  final DuplicateCandidate candidate;

  @override
  ConsumerState<_CompareSheet> createState() => _CompareSheetState();
}

class _CompareSheetState extends ConsumerState<_CompareSheet> {
  bool _merging = false;

  Future<void> _merge(Person keep, Person remove) async {
    final ok = await showFTConfirm(
      context,
      title: 'Keep ${keep.displayName}?',
      message: '${remove.displayName} will be merged into ${keep.displayName}: relationships, events, '
          'photos, stories, sources and custom values move across, empty details are filled in, '
          'and the other record is removed. This can\'t be undone.',
      confirmLabel: 'Merge',
      destructive: true,
      icon: AppIcons.merge,
    );
    if (!ok || !mounted) return;
    setState(() => _merging = true);
    try {
      await ref.read(familyRepoProvider).mergePeople(keepId: keep.id, removeId: remove.id);
      if (!mounted) return;
      showFTToast(context, 'Merged into ${keep.displayName}');
      Navigator.of(context).pop(_CompareOutcome.merged);
    } catch (e) {
      if (!mounted) return;
      setState(() => _merging = false);
      showFTToast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final mediaPeople = ref.watch(mediaPeopleProvider).value ?? const <MediaPerson>[];
    final eventPeople = ref.watch(eventPeopleProvider).value ?? const <EventPerson>[];
    final a = g[widget.candidate.aId];
    final b = g[widget.candidate.bId];
    if (a == null || b == null) {
      return const EmptyState(
        icon: AppIcons.info,
        title: 'These records have changed',
        message: 'One of the two people is no longer in the tree.',
        compact: true,
      );
    }

    String names(Iterable<String> ids) {
      final list = [for (final id in ids) ?g[id]?.displayName];
      if (list.isEmpty) return '';
      if (list.length <= 3) return list.join(', ');
      return '${list.take(3).join(', ')} +${list.length - 3}';
    }

    String born(Person p) => [p.birth?.format(), (p.birthPlace ?? '').trim()]
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .join(' · ');
    String died(Person p) {
      if (p.isLiving) return 'Living';
      final s = [p.death?.format(), (p.deathPlace ?? '').trim()]
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .join(' · ');
      return s.isEmpty ? 'Deceased' : s;
    }

    String others(Person p) => [
          if ((p.birthName ?? '').trim().isNotEmpty) 'Birth name ${p.birthName!.trim()}',
          if ((p.nickname ?? '').trim().isNotEmpty) '“${p.nickname!.trim()}”',
        ].join(' · ');

    int photos(String id) => mediaPeople.where((m) => m.personId == id).length;
    int events(String id) => eventPeople.where((e) => e.personId == id).length;
    String children(String id) {
      final kids = g.childIds(id);
      if (kids.isEmpty) return '';
      return '${kids.length} · ${names(kids)}';
    }

    final rows = <(String, String, String)>[
      ('Name', a.displayName, b.displayName),
      ('Other names', others(a), others(b)),
      ('Gender', a.gender.label, b.gender.label),
      ('Born', born(a), born(b)),
      ('Died', died(a), died(b)),
      ('Parents', names(g.parentIds(a.id)), names(g.parentIds(b.id))),
      ('Partners', names(g.partnerIds(a.id)), names(g.partnerIds(b.id))),
      ('Children', children(a.id), children(b.id)),
      ('Photos', '${photos(a.id)}', '${photos(b.id)}'),
      ('Events', '${events(a.id)}', '${events(b.id)}'),
    ];

    Widget head(Person p, String side) => Expanded(
          child: Column(
            children: [
              PersonAvatarFor(p, size: 56, showGender: true),
              const SizedBox(height: Gap.xs),
              Text(p.displayName,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.tx.bodyStrong),
              Text(side, style: context.tx.micro),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            head(a, 'LEFT'),
            const SizedBox(width: Gap.sm),
            head(b, 'RIGHT'),
          ],
        ),
        const SizedBox(height: Gap.sm),
        _ScoreMeter(score: widget.candidate.score),
        const SizedBox(height: Gap.md),
        FTCard(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
          radius: Radii.md,
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const HairLine(vertical: 6),
                _CompareRow(label: rows[i].$1, left: rows[i].$2, right: rows[i].$3),
              ],
            ],
          ),
        ),
        const SizedBox(height: Gap.md),
        Text(
          'Choose the record to keep. The other one is merged into it: relationships, events, photos, '
          'stories and sources move across and empty details are filled in.',
          style: context.tx.caption,
        ),
        const SizedBox(height: Gap.md),
        Row(
          children: [
            Expanded(
              child: FTButton.secondary(
                label: 'Keep left',
                icon: AppIcons.back,
                expand: true,
                onTap: _merging ? null : () => _merge(a, b),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: FTButton.secondary(
                label: 'Keep right',
                trailingIcon: AppIcons.forward,
                expand: true,
                onTap: _merging ? null : () => _merge(b, a),
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.sm),
        Row(
          children: [
            Expanded(
              child: FTButton(
                label: 'Not a duplicate',
                kind: FTButtonKind.ghost,
                expand: true,
                loading: _merging,
                onTap: () => Navigator.of(context).pop(_CompareOutcome.dismissed),
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.xs),
        Center(
          child: Wrap(
            spacing: Gap.xs,
            children: [
              FTTextAction('Open ${a.shortName}', onTap: () => _openProfile(a.id)),
              FTTextAction('Open ${b.shortName}', onTap: () => _openProfile(b.id)),
            ],
          ),
        ),
      ],
    );
  }

  void _openProfile(String id) {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    router.push(Routes.person(id));
  }
}

class _CompareRow extends StatelessWidget {
  const _CompareRow({required this.label, required this.left, required this.right});
  final String label;
  final String left;
  final String right;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final same = left.isNotEmpty && left.toLowerCase() == right.toLowerCase();
    Widget cell(String v) => Expanded(
          child: Text(
            v.isEmpty ? '—' : v,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: context.tx.label.copyWith(
              color: v.isEmpty ? c.text3 : (same ? c.accent : c.text),
              fontWeight: FontWeight.w500,
            ),
          ),
        );
    return Semantics(
      label: '$label: left ${left.isEmpty ? 'not recorded' : left}, right ${right.isEmpty ? 'not recorded' : right}'
          '${same ? ', same' : ''}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: context.tx.micro)),
              if (same) Icon(AppIcons.check, size: 13, color: c.accent),
            ],
          ),
          const SizedBox(height: 3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              cell(left),
              const SizedBox(width: Gap.sm),
              cell(right),
            ],
          ),
        ],
      ),
    );
  }
}
