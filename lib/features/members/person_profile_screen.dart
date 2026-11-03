import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme/app_theme.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/services/app_paths.dart';
import '../../core/widgets/widgets.dart';
import '../dashboard/dashboard_screen.dart' show profileCompleteness;
import '../family/domain/family_graph.dart';
import '../family/domain/occasions.dart';
import '../gallery/media_import.dart';
import '../sources/citations_section.dart';
import 'widgets/add_relative_sheet.dart';
import 'widgets/person_widgets.dart';

class PersonProfileScreen extends ConsumerWidget {
  const PersonProfileScreen({super.key, required this.personId});
  final String personId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final graphAsync = ref.watch(familyGraphProvider);
    final c = context.ft;
    return graphAsync.when(
      loading: () => const FTPage(body: LoadingView()),
      error: (e, _) => FTPage(body: ErrorView(error: e)),
      data: (g) {
        final p = g[personId];
        if (p == null) {
          return const FTPage(
            title: 'Profile',
            body: EmptyState(icon: AppIcons.person, title: 'This person is no longer in the tree',
                message: 'They may have been moved to the trash.'),
          );
        }
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: AppTheme.overlayStyle(c.isDark),
          child: Scaffold(
            backgroundColor: c.bg0,
            body: Stack(
              children: [
                const Positioned.fill(child: FTBackground()),
                _ProfileBody(person: p, graph: g),
                // Status-bar scrim so scrolled content never collides with it.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: MediaQuery.paddingOf(context).top + 12,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [c.bg0, c.bg0.withValues(alpha: 0)],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ProfileBody extends ConsumerWidget {
  const _ProfileBody({required this.person, required this.graph});
  final Person person;
  final FamilyGraph graph;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = person;
    final g = graph;
    final pad = context.pagePadding;
    final top = MediaQuery.paddingOf(context).top;
    final photoPath = ref.watch(avatarPathProvider(p.profileMediaId));
    final fullPhoto = _fullPhotoPath(ref, p.profileMediaId);
    final c = context.ft;
    final width = MediaQuery.sizeOf(context).width;
    final heroH = (width * 0.86).clamp(300.0, 460.0) + top;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
            height: heroH,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (fullPhoto != null)
                  GestureDetector(
                    onTap: () => context.push(Routes.media(p.profileMediaId!)),
                    child: Hero(
                      tag: 'avatar-${p.id}',
                      child: Image.file(
                        File(fullPhoto),
                        fit: BoxFit.cover,
                        cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
                        color: p.isLiving ? null : Colors.grey,
                        colorBlendMode: p.isLiving ? null : BlendMode.saturation,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  )
                else
                  Align(
                    alignment: const Alignment(0, -0.42),
                    child: Padding(
                      padding: EdgeInsets.only(top: top),
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [BoxShadow(color: c.accent.withValues(alpha: 0.18), blurRadius: 60)],
                        ),
                        child: PersonAvatar(name: p.displayName, size: 128, heroTag: 'avatar-${p.id}', imagePath: photoPath),
                      ),
                    ),
                  ),
                // Fade into the page background.
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            c.bg0.withValues(alpha: 0.55),
                            c.bg0.withValues(alpha: 0.0),
                            c.bg0.withValues(alpha: 0.0),
                            c.bg0,
                          ],
                          stops: const [0, 0.25, 0.55, 1],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: top + 8,
                  left: pad - 4,
                  right: pad - 4,
                  child: Row(
                    children: [
                      FTIconButton(
                        icon: AppIcons.back,
                        tooltip: 'Back',
                        onTap: () => context.canPop() ? context.pop() : context.go(Routes.members),
                      ),
                      const Spacer(),
                      FTIconButton(
                        icon: AppIcons.edit,
                        tooltip: 'Edit profile',
                        onTap: () => context.push(Routes.personEdit(p.id)),
                      ),
                      const SizedBox(width: 4),
                      FTIconButton(
                        icon: AppIcons.moreHoriz,
                        tooltip: 'More actions',
                        onTap: () => _moreActions(context, ref, p, g),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: pad,
                  right: pad,
                  bottom: 8,
                  child: _Identity(person: p, graph: g),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(pad, Gap.md, pad, FTPage.bottomInset(context, extra: 40)),
          sliver: SliverList.list(
            children: [
              ContentWidth(child: _ActionRow(person: p, graph: g)),
              const SizedBox(height: Gap.xl),
              ContentWidth(child: _AboutCard(person: p)),
              ContentWidth(child: _LifeFacts(person: p)),
              ContentWidth(child: _FamilySection(person: p, graph: g)),
              ContentWidth(child: _DatesSection(person: p, graph: g)),
              ContentWidth(child: _EventsSection(person: p)),
              ContentWidth(child: _PhotosSection(person: p)),
              ContentWidth(child: _StoriesSection(person: p)),
              ContentWidth(child: _BranchesTagsSection(person: p, graph: g)),
              ContentWidth(child: _CustomFieldsSection(person: p)),
              ContentWidth(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: Gap.xl),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SectionHeader('Sources & evidence'),
                      CitationsSection(entityType: 'person', entityId: p.id),
                    ],
                  ),
                ),
              ),
              if ((p.notes ?? '').isNotEmpty || (p.email ?? '').isNotEmpty || (p.phone ?? '').isNotEmpty || (p.address ?? '').isNotEmpty)
                ContentWidth(child: _NotesSection(person: p)),
            ],
          ),
        ),
      ],
    );
  }

  String? _fullPhotoPath(WidgetRef ref, String? mediaId) {
    if (mediaId == null) return null;
    final m = ref.watch(mediaByIdProvider)[mediaId];
    if (m == null) return null;
    return AppPaths.I.resolve(m.filePath);
  }

  Future<void> _moreActions(BuildContext context, WidgetRef ref, Person p, FamilyGraph g) async {
    final tree = ref.read(activeTreeProvider);
    final isHome = tree?.homePersonId == p.id;
    final r = await showFTOptions<String>(context, title: p.displayName, options: [
      const FTOption('relationships', 'Manage relationships', icon: AppIcons.link),
      const FTOption('finder', 'How are we related?', icon: AppIcons.path),
      if (!isHome) const FTOption('home', 'Set as home person', icon: AppIcons.house, subtitle: 'Relationships are described relative to them'),
      FTOption('private', p.isPrivate ? 'Mark as not private' : 'Mark as private',
          icon: p.isPrivate ? AppIcons.eye : AppIcons.eyeOff, subtitle: 'Private people are hidden from public exports'),
      FTOption('archive', p.isArchived ? 'Unarchive' : 'Archive', icon: AppIcons.archive),
      const FTOption('pdf', 'Export profile as PDF', icon: AppIcons.pdf),
      const FTOption('delete', 'Move to trash', icon: AppIcons.delete, danger: true),
    ]);
    if (r == null || !context.mounted) return;
    final repo = ref.read(familyRepoProvider);
    switch (r) {
      case 'relationships':
        context.push(Routes.personRelationships(p.id));
      case 'finder':
        final home = ref.read(homePersonIdProvider);
        context.push(Uri(path: Routes.relationshipFinder, queryParameters: {
          'a': p.id,
          if (home != null && home != p.id) 'b': home,
        }).toString());
      case 'home':
        await repo.updateTree(p.treeId, homePersonId: p.id);
        if (context.mounted) showFTToast(context, '${p.shortName} is now the home person');
      case 'private':
        await repo.setPrivate(p.id, !p.isPrivate);
      case 'archive':
        await repo.setArchived([p.id], !p.isArchived);
      case 'pdf':
        context.push(Routes.pdf(kind: 'profile', personId: p.id));
      case 'delete':
        final ok = await showFTConfirm(
          context,
          title: 'Move ${p.displayName} to trash?',
          message: 'Their relationships, events and photos are kept. You can restore them from Trash.',
          confirmLabel: 'Move to trash',
          destructive: true,
        );
        if (!ok || !context.mounted) return;
        await repo.trashPerson(p.id);
        if (!context.mounted) return;
        final router = GoRouter.of(context);
        // Captured now: this screen is gone by the time Undo is tapped.
        final system = ref.read(systemRepoProvider);
        showFTToast(context, '${p.displayName} moved to trash', actionLabel: 'Undo', onAction: () async {
          final records = await system.watchTrash().first;
          final rec = records.where((x) => x.entityId == p.id).firstOrNull;
          if (rec != null) await system.restore(rec.id);
        });
        if (router.canPop()) router.pop();
    }
  }
}

class _Identity extends ConsumerWidget {
  const _Identity({required this.person, required this.graph});
  final Person person;
  final FamilyGraph graph;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = person;
    final c = context.ft;
    final home = ref.watch(homePersonIdProvider);
    final kin = ref.watch(kinshipProvider);
    String? rel;
    if (home != null && home != p.id && kin != null) {
      final l = kin.primaryLabel(p.id, home);
      if (l != null) rel = '$l of ${graph[home]?.shortName}';
    } else if (home == p.id) {
      rel = 'Home person';
    }
    final age = p.age;
    final lifespan = [
      if (p.lifespanLabel.isNotEmpty) p.lifespanLabel,
      if (age != null) p.isLiving ? 'Age ${age.format()}' : 'Lived ${age.format()} years',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (rel != null) FTTag(rel, icon: AppIcons.path, accent: true),
            FTTag(p.isLiving ? 'Living' : 'Deceased', icon: p.isLiving ? AppIcons.heart : AppIcons.flower),
            if (p.isPrivate) const FTTag('Private', icon: AppIcons.eyeOff),
            if (p.isArchived) const FTTag('Archived', icon: AppIcons.archive),
          ],
        ),
        const SizedBox(height: 10),
        Semantics(
          header: true,
          child: Text(p.displayName, style: context.tx.display.copyWith(fontSize: 32), maxLines: 3),
        ),
        if ((p.nickname ?? '').isNotEmpty || (p.birthName ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              [
                if ((p.nickname ?? '').isNotEmpty) '“${p.nickname}”',
                if ((p.birthName ?? '').isNotEmpty) 'née ${p.birthName}',
              ].join(' · '),
              style: context.tx.body.copyWith(color: c.text2),
            ),
          ),
        if (lifespan.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(lifespan, style: context.tx.caption.copyWith(fontSize: 13)),
          ),
      ],
    );
  }
}

class _ActionRow extends ConsumerWidget {
  const _ActionRow({required this.person, required this.graph});
  final Person person;
  final FamilyGraph graph;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = person;
    Widget action(IconData icon, String label, VoidCallback onTap, {bool accent = false}) => Expanded(
          child: Column(
            children: [
              FTIconButton(icon: icon, tooltip: label, onTap: onTap, accent: accent, size: 52),
              const SizedBox(height: 4),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.micro, textAlign: TextAlign.center),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            action(AppIcons.personAdd, 'Add relative', () => showAddRelativeSheet(context, p.id, p.shortName), accent: true),
            action(AppIcons.tree, 'View in tree', () => context.go(Uri(path: Routes.tree, queryParameters: {'focus': p.id}).toString())),
            action(AppIcons.share, 'Share', () => _share(p)),
            action(AppIcons.pdf, 'Export', () => context.push(Routes.pdf(kind: 'profile', personId: p.id))),
          ],
        ),
        const SizedBox(height: Gap.lg),
        FTCard(
          padding: EdgeInsets.zero,
          shadow: false,
          onTap: () => context.push(Routes.personEdit(p.id)),
          child: StripedProgress(
            value: profileCompleteness(p, graph),
            label: 'Profile completeness · tap to add details',
          ),
        ),
      ],
    );
  }

  Future<void> _share(Person p) async {
    final lines = [
      p.displayName,
      if (p.lifespanLabel.isNotEmpty) p.lifespanLabel,
      if (p.birth != null) 'Born: ${p.birth!.format(long: true)}${p.birthPlace != null ? ', ${p.birthPlace}' : ''}',
      if (!p.isLiving && p.death != null) 'Died: ${p.death!.format(long: true)}${p.deathPlace != null ? ', ${p.deathPlace}' : ''}',
      if ((p.occupation ?? '').isNotEmpty) 'Occupation: ${p.occupation}',
      if ((p.biography ?? '').isNotEmpty) '\n${p.biography}',
      '\nShared from Family Tales',
    ];
    await SharePlus.instance.share(ShareParams(text: lines.join('\n'), subject: p.displayName));
  }
}

/// Card with a section title used throughout the profile.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.action, this.onAction, this.padding});
  final String title;
  final Widget child;
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(title, action: action, onAction: onAction),
            FTCard(padding: padding ?? const EdgeInsets.all(Gap.lg), child: child),
          ],
        ),
      );
}

class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.label, this.value);
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconBadge(icon: icon, size: 34),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: context.tx.caption),
                  const SizedBox(height: 1),
                  Text(value, style: context.tx.bodyStrong.copyWith(fontWeight: FontWeight.w400)),
                ],
              ),
            ),
          ],
        ),
      );
}

class _AboutCard extends StatefulWidget {
  const _AboutCard({required this.person});
  final Person person;

  @override
  State<_AboutCard> createState() => _AboutCardState();
}

class _AboutCardState extends State<_AboutCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.person;
    final facts = <Widget>[
      if ((p.occupation ?? '').isNotEmpty) _Fact(AppIcons.briefcase, 'Occupation', p.occupation!),
      if ((p.education ?? '').isNotEmpty) _Fact(AppIcons.graduation, 'Education', p.education!),
      if ((p.nationality ?? '').isNotEmpty) _Fact(AppIcons.globe, 'Nationality', p.nationality!),
      if ((p.languages ?? '').isNotEmpty) _Fact(AppIcons.language, 'Languages', p.languages!),
      if ((p.interests ?? '').isNotEmpty) _Fact(AppIcons.sparkle, 'Interests', p.interests!),
      if ((p.achievements ?? '').isNotEmpty) _Fact(AppIcons.trophy, 'Achievements', p.achievements!),
      if (p.gender != Gender.unknown || (p.pronouns ?? '').isNotEmpty)
        _Fact(AppIcons.forGender(p.gender), 'Gender',
            [if (p.gender != Gender.unknown) p.gender.label, if ((p.pronouns ?? '').isNotEmpty) p.pronouns!].join(' · ')),
    ];
    final bio = p.biography ?? '';
    if (bio.isEmpty && facts.isEmpty) return const SizedBox.shrink();
    return _Section(
      title: 'Biography',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (bio.isNotEmpty) ...[
            AnimatedSize(
              duration: Motion.medium,
              alignment: Alignment.topCenter,
              child: Text(
                bio,
                maxLines: _expanded ? null : 5,
                overflow: _expanded ? TextOverflow.visible : TextOverflow.fade,
                style: context.tx.body.copyWith(fontSize: 15, height: 1.6, color: context.ft.text),
              ),
            ),
            if (bio.length > 260)
              FTTextAction(_expanded ? 'Show less' : 'Read more', accent: true,
                  onTap: () => setState(() => _expanded = !_expanded)),
            if (facts.isNotEmpty) const HairLine(),
          ],
          ...facts,
        ],
      ),
    );
  }
}

class _LifeFacts extends StatelessWidget {
  const _LifeFacts({required this.person});
  final Person person;

  @override
  Widget build(BuildContext context) {
    final p = person;
    String place(String? a, String? b) => [a, b].whereType<String>().where((s) => s.trim().isNotEmpty).join(', ');
    final birthPlace = place(p.birthPlace, p.birthCountry);
    final facts = <Widget>[
      if (p.birth != null) _Fact(AppIcons.baby, 'Born', p.birth!.format(long: true)),
      if (birthPlace.isNotEmpty) _Fact(AppIcons.location, 'Birthplace', birthPlace),
      if ((p.birthNotes ?? '').isNotEmpty) _Fact(AppIcons.note, 'Birth notes', p.birthNotes!),
      if (!p.isLiving) ...[
        _Fact(AppIcons.flower, 'Died', p.death?.format(long: true) ?? 'Date unknown'),
        if ((p.deathPlace ?? '').isNotEmpty) _Fact(AppIcons.location, 'Place of death', p.deathPlace!),
        if ((p.causeOfDeath ?? '').isNotEmpty) _Fact(AppIcons.info, 'Cause of death', p.causeOfDeath!),
        if ((p.burialPlace ?? '').isNotEmpty) _Fact(AppIcons.plant, 'Burial / memorial', p.burialPlace!),
        if ((p.deathNotes ?? '').isNotEmpty) _Fact(AppIcons.note, 'Notes', p.deathNotes!),
      ],
    ];
    if (facts.isEmpty) return const SizedBox.shrink();
    return _Section(title: 'Life', child: Column(children: facts));
  }
}

class _FamilySection extends ConsumerWidget {
  const _FamilySection({required this.person, required this.graph});
  final Person person;
  final FamilyGraph graph;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = graph;
    final id = person.id;
    final groups = <(String, List<(String, String?)>)>[];
    groups.add(('Parents', [
      for (final l in g.parentLinksOf(id)) (l.parentId, l.type == ParentType.biological ? null : l.type.label)
    ]));
    groups.add(('Partners', [
      for (final s in g.partnershipsOf(id))
        (
          s.personAId == id ? s.personBId : s.personAId,
          [
            s.type.label,
            if (s.status != PartnerStatus.current) s.status.label,
            if (FuzzyDate.tryParse(s.startDate) != null) 'since ${FuzzyDate.tryParse(s.startDate)!.formatYear()}',
          ].join(' · ')
        )
    ]));
    groups.add(('Children', [
      for (final l in g.childLinksOf(id)) (l.childId, l.type == ParentType.biological ? null : l.type.label)
    ]));
    groups.add(('Siblings', [
      for (final s in g.siblings(id))
        (s.personId, switch (s.kind) {
          SiblingKind.full => null,
          SiblingKind.half => 'Half-sibling',
          SiblingKind.step => 'Step-sibling',
          SiblingKind.adoptive => 'Adoptive sibling',
        })
    ]));
    groups.add(('Grandparents', [for (final x in g.grandparents(id)) (x, null)]));
    groups.add(('Grandchildren', [for (final x in g.grandchildren(id)) (x, null)]));
    final nonEmpty = groups.where((e) => e.$2.isNotEmpty).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader('Family', action: 'Manage', onAction: () => context.push(Routes.personRelationships(id))),
          FTCard(
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
            child: nonEmpty.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('No relatives connected yet.', style: context.tx.caption),
                        ),
                        FTTextAction('Add relative', accent: true,
                            onTap: () => showAddRelativeSheet(context, id, person.shortName)),
                      ],
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < nonEmpty.length; i++) ...[
                        if (i > 0) const HairLine(vertical: 6),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
                          child: Text(nonEmpty[i].$1, style: context.tx.caption),
                        ),
                        for (final (pid, note) in nonEmpty[i].$2)
                          if (g[pid] != null)
                            PersonTile(
                              person: g[pid]!,
                              avatarSize: 40,
                              subtitle: [?note, if (g[pid]!.lifespanLabel.isNotEmpty) g[pid]!.lifespanLabel]
                                  .join(' · '),
                              onTap: () => context.push(Routes.person(pid)),
                            ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _DatesSection extends ConsumerWidget {
  const _DatesSection({required this.person, required this.graph});
  final Person person;
  final FamilyGraph graph;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final occ = OccasionCalculator(graph: graph)
        .between(now, now.add(const Duration(days: 366)))
        .where((o) => o.personIds.contains(person.id))
        .take(4)
        .toList();
    if (occ.isEmpty) return const SizedBox.shrink();
    final fmt = DateFormat('EEE, d MMM y');
    return _Section(
      title: 'Important dates',
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          for (final o in occ)
            _Fact(
              switch (o.kind) {
                OccasionKind.birthday => AppIcons.cake,
                OccasionKind.anniversary => AppIcons.heart,
                OccasionKind.memorial => AppIcons.candle,
                _ => AppIcons.calendar,
              },
              '${o.kind.label} · ${fmt.format(o.date)}',
              o.subtitle ?? o.title,
            ),
        ],
      ),
    );
  }
}

class _EventsSection extends ConsumerWidget {
  const _EventsSection({required this.person});
  final Person person;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(eventsWithPeopleProvider).value ?? const [];
    final mine = all.where((e) => e.personIds.contains(person.id)).toList()
      ..sort((a, b) => (FuzzyDate.tryParse(a.event.date)?.sortKey ?? double.infinity)
          .compareTo(FuzzyDate.tryParse(b.event.date)?.sortKey ?? double.infinity));
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader('Life events', action: 'Add', onAction: () => context.push(Routes.newEvent(personId: person.id))),
          if (mine.isEmpty)
            _EmptyRow(icon: AppIcons.event, text: 'Graduations, moves, awards and other milestones appear here.',
                onTap: () => context.push(Routes.newEvent(personId: person.id)))
          else
            FTCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                children: [
                  for (var i = 0; i < mine.length; i++)
                    _TimelineRow(
                      icon: AppIcons.forEvent(mine[i].event.type),
                      title: mine[i].event.title,
                      subtitle: [
                        FuzzyDate.tryParse(mine[i].event.date)?.format() ?? 'Undated',
                        if ((mine[i].event.location ?? '').isNotEmpty) mine[i].event.location!,
                      ].join(' · '),
                      first: i == 0,
                      last: i == mine.length - 1,
                      onTap: () => context.push(Routes.event(mine[i].event.id)),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.first,
    required this.last,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final bool first;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Pressable(
      onTap: onTap,
      scale: 0.985,
      semanticLabel: '$title, $subtitle',
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 40,
              child: Column(
                children: [
                  Expanded(child: Container(width: 1.5, color: first ? Colors.transparent : c.border)),
                  IconBadge(icon: icon, size: 34),
                  Expanded(child: Container(width: 1.5, color: last ? Colors.transparent : c.border)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(title, style: context.tx.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
                    Text(subtitle, style: context.tx.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ),
            Icon(AppIcons.forward, size: 16, color: c.text3),
          ],
        ),
      ),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow({required this.icon, required this.text, required this.onTap});
  final IconData icon;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FTCard(
        padding: const EdgeInsets.all(14),
        shadow: false,
        onTap: onTap,
        child: Row(
          children: [
            IconBadge(icon: icon, size: 36),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: context.tx.caption)),
            Icon(AppIcons.add, color: context.ft.accent, size: 20),
          ],
        ),
      );
}

class _PhotosSection extends ConsumerWidget {
  const _PhotosSection({required this.person});
  final Person person;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final links = ref.watch(mediaPeopleProvider).value ?? const <MediaPerson>[];
    final byId = ref.watch(mediaByIdProvider);
    final ids = links.where((l) => l.personId == person.id).map((l) => l.mediaId).where(byId.containsKey).toList();
    final photos = ids.map((i) => byId[i]!).where((m) => m.kind == MediaKind.photo).toList();
    final c = context.ft;
    Future<void> add() async {
      final added = await importPhotosFlow(context, ref, personIds: [person.id]);
      if (added.isNotEmpty && person.profileMediaId == null) {
        await ref.read(familyRepoProvider).setProfilePhoto(person.id, added.first);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader('Photos', action: 'Add', onAction: add),
          if (photos.isEmpty)
            _EmptyRow(icon: AppIcons.photos, text: 'Add photos of ${person.shortName}. The first becomes the profile picture.', onTap: add)
          else
            LayoutBuilder(builder: (context, cons) {
              final cols = cons.maxWidth > 500 ? 4 : 3;
              final size = (cons.maxWidth - (cols - 1) * 8) / cols;
              final dpr = MediaQuery.devicePixelRatioOf(context);
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in photos.take(cols * 2))
                    Pressable(
                      onTap: () => context.push(Routes.media(m.id), extra: [for (final x in photos) x.id]),
                      onLongPress: () async {
                        await ref.read(familyRepoProvider).setProfilePhoto(person.id, m.id);
                        if (context.mounted) showFTToast(context, 'Profile photo updated');
                      },
                      semanticLabel: '${m.caption ?? 'Photo'}. Long-press to use as profile photo',
                      child: Container(
                        width: size,
                        height: size,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                              color: m.id == person.profileMediaId ? c.accent : c.border,
                              width: m.id == person.profileMediaId ? 1.6 : 1),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Image.file(
                          File(AppPaths.I.resolve(m.thumbPath ?? m.filePath)),
                          fit: BoxFit.cover,
                          cacheWidth: (size * dpr).round(),
                          errorBuilder: (_, _, _) => Icon(AppIcons.photo, color: c.text3),
                        ),
                      ),
                    ),
                ],
              );
            }),
          if (photos.length > 6)
            Align(
              alignment: Alignment.centerRight,
              child: FTTextAction('All ${photos.length} photos', onTap: () => context.push(Routes.gallery)),
            ),
        ],
      ),
    );
  }
}

class _StoriesSection extends ConsumerWidget {
  const _StoriesSection({required this.person});
  final Person person;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final links = ref.watch(storyPeopleProvider).value ?? const <StoryPerson>[];
    final stories = ref.watch(storiesProvider).value ?? const <Story>[];
    final ids = links.where((l) => l.personId == person.id).map((l) => l.storyId).toSet();
    final mine = stories.where((s) => ids.contains(s.id)).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader('Stories', action: 'Write', onAction: () => context.push(Routes.newStory(personId: person.id))),
          if (mine.isEmpty)
            _EmptyRow(icon: AppIcons.storyAlt, text: 'Write down a memory about ${person.shortName}.',
                onTap: () => context.push(Routes.newStory(personId: person.id)))
          else
            for (final s in mine)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: FTCard(
                  padding: const EdgeInsets.all(16),
                  onTap: () => context.push(Routes.story(s.id)),
                  child: Row(
                    children: [
                      const IconBadge(icon: AppIcons.story, size: 38),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s.title, style: context.tx.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                            Text(
                              FuzzyDate.tryParse(s.historicalDate)?.format() ?? DateFormat.yMMMd().format(s.updatedAt),
                              style: context.tx.caption,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _BranchesTagsSection extends ConsumerWidget {
  const _BranchesTagsSection({required this.person, required this.graph});
  final Person person;
  final FamilyGraph graph;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branches = ref.watch(branchesProvider).value ?? const <FamilyBranch>[];
    final members = ref.watch(branchMembersProvider).value ?? const <PersonBranch>[];
    final tags = ref.watch(tagsProvider).value ?? const <Tag>[];
    final personTags = ref.watch(personTagsProvider).value ?? const <PersonTag>[];
    final myBranches = branches.where((b) {
      if (members.any((m) => m.branchId == b.id && m.personId == person.id)) return true;
      final root = b.rootPersonId;
      if (root == null || !graph.contains(root)) return false;
      return root == person.id ||
          graph.descendants(root).contains(person.id) ||
          graph.partnerIds(person.id).any((x) => x == root || graph.descendants(root).contains(x));
    }).toList();
    final myTagIds = personTags.where((t) => t.personId == person.id).map((t) => t.tagId).toSet();
    final myTags = tags.where((t) => myTagIds.contains(t.id)).toList();
    if (myBranches.isEmpty && myTags.isEmpty) return const SizedBox.shrink();
    return _Section(
      title: 'Branches & tags',
      action: 'Branches',
      onAction: () => context.push(Routes.branches),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final b in myBranches) FTTag(b.name, icon: AppIcons.branch, accent: true),
          for (final t in myTags) FTTag('#${t.name}', icon: AppIcons.tag),
        ],
      ),
    );
  }
}

class _CustomFieldsSection extends ConsumerWidget {
  const _CustomFieldsSection({required this.person});
  final Person person;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fields = ref.watch(customFieldsProvider).value ?? const <CustomField>[];
    final values = ref.watch(_customValuesProvider(person.id)).value ?? const <PersonCustomValue>[];
    final shown = [
      for (final f in fields)
        if (values.any((v) => v.fieldId == f.id)) (f, values.firstWhere((v) => v.fieldId == f.id).value)
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    return _Section(
      title: 'More details',
      child: Column(
        children: [
          for (final (f, v) in shown)
            _Fact(f.isPrivate ? AppIcons.eyeOff : AppIcons.fields, f.name, v),
        ],
      ),
    );
  }
}

final _customValuesProvider = StreamProvider.family<List<PersonCustomValue>, String>(
    (ref, id) => ref.watch(familyRepoProvider).watchCustomValues(id));

class _NotesSection extends StatelessWidget {
  const _NotesSection({required this.person});
  final Person person;

  @override
  Widget build(BuildContext context) {
    final p = person;
    return _Section(
      title: 'Personal notes & contact',
      child: Column(
        children: [
          if ((p.email ?? '').isNotEmpty) _Fact(AppIcons.mail, 'Email', p.email!),
          if ((p.phone ?? '').isNotEmpty) _Fact(AppIcons.phone, 'Phone', p.phone!),
          if ((p.address ?? '').isNotEmpty) _Fact(AppIcons.house, 'Address', p.address!),
          if ((p.notes ?? '').isNotEmpty) _Fact(AppIcons.note, 'Notes', p.notes!),
        ],
      ),
    );
  }
}
