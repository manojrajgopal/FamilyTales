import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/database/app_database.dart';
import '../../../core/widgets/widgets.dart';
import '../../family/domain/family_graph.dart';

/// Avatar for a [Person] that resolves their profile photo automatically.
class PersonAvatarFor extends ConsumerWidget {
  const PersonAvatarFor(this.person, {super.key, this.size = 44, this.ring = false, this.heroTag});
  final Person person;
  final double size;
  final bool ring;
  final Object? heroTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ref.watch(avatarPathProvider(person.profileMediaId));
    return PersonAvatar(
      name: person.displayName,
      imagePath: path,
      size: size,
      ring: ring,
      deceased: !person.isLiving,
      heroTag: heroTag,
    );
  }
}

/// Standard person row: avatar, name, lifespan / subtitle, trailing.
class PersonTile extends StatelessWidget {
  const PersonTile({
    super.key,
    required this.person,
    this.subtitle,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.selected = false,
    this.avatarSize = 46,
    this.titleWidget,
  });

  final Person person;
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final bool selected;
  final double avatarSize;

  /// Replaces the plain name text (e.g. with search highlighting).
  final Widget? titleWidget;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final sub = subtitle ?? _defaultSubtitle(person);
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      scale: 0.985,
      semanticLabel: '${person.displayName}${sub.isEmpty ? '' : ', $sub'}',
      child: AnimatedContainer(
        duration: Motion.fast,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? c.accent.withValues(alpha: 0.10) : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: selected ? c.accent.withValues(alpha: 0.5) : Colors.transparent),
        ),
        child: Row(
          children: [
            PersonAvatarFor(person, size: avatarSize, ring: selected),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  titleWidget ??
                      Text(person.displayName,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                  if (sub.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.caption),
                  ],
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }

  static String _defaultSubtitle(Person p) {
    final parts = <String>[];
    if (p.lifespanLabel.isNotEmpty) parts.add(p.lifespanLabel);
    if (p.birthPlace != null && p.birthPlace!.isNotEmpty) parts.add(p.birthPlace!);
    return parts.join(' · ');
  }
}

/// Opens a searchable picker of people in the active tree. Returns the
/// selected person id, or null if dismissed.
Future<String?> pickPerson(
  BuildContext context, {
  String title = 'Choose a person',
  Set<String> exclude = const {},
  String? createLabel,
  VoidCallback? onCreate,
}) async {
  final r = await showFTSheet<List<String>>(
    context,
    title: title,
    scrollable: false,
    builder: (_) => _PersonPicker(
      multi: false,
      exclude: exclude,
      initial: const {},
      createLabel: createLabel,
      onCreate: onCreate,
    ),
  );
  return (r == null || r.isEmpty) ? null : r.first;
}

/// Multi-select variant. Returns the full selection (or null if dismissed).
Future<List<String>?> pickPeople(
  BuildContext context, {
  String title = 'Choose people',
  Set<String> initial = const {},
  Set<String> exclude = const {},
}) {
  return showFTSheet<List<String>>(
    context,
    title: title,
    scrollable: false,
    builder: (_) => _PersonPicker(multi: true, exclude: exclude, initial: initial),
  );
}

class _PersonPicker extends ConsumerStatefulWidget {
  const _PersonPicker({
    required this.multi,
    required this.exclude,
    required this.initial,
    this.createLabel,
    this.onCreate,
  });

  final bool multi;
  final Set<String> exclude;
  final Set<String> initial;
  final String? createLabel;
  final VoidCallback? onCreate;

  @override
  ConsumerState<_PersonPicker> createState() => _PersonPickerState();
}

class _PersonPickerState extends ConsumerState<_PersonPicker> {
  String _q = '';
  late final Set<String> _sel = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final q = _q.trim().toLowerCase();
    final people = g.sortedPeople().where((p) {
      if (widget.exclude.contains(p.id)) return false;
      if (q.isEmpty) return true;
      return [p.displayName, p.nickname, p.birthName, p.lastName, p.birth?.formatYear()]
          .whereType<String>()
          .any((s) => s.toLowerCase().contains(q));
    }).toList();
    final mq = MediaQuery.of(context);
    return SizedBox(
      height: (mq.size.height - mq.viewInsets.bottom) * 0.72,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.xl, Gap.sm),
            child: FTSearchField(hint: 'Search by name or year', onChanged: (v) => setState(() => _q = v)),
          ),
          if (widget.createLabel != null && widget.onCreate != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
              child: FTListRow(
                title: widget.createLabel!,
                icon: AppIcons.personAdd,
                onTap: () {
                  Navigator.of(context).pop();
                  widget.onCreate!();
                },
              ),
            ),
          Expanded(
            child: people.isEmpty
                ? const EmptyState(icon: AppIcons.people, title: 'No matching people', compact: true)
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, widget.multi ? Gap.md : mq.padding.bottom + Gap.md),
                    itemCount: people.length,
                    itemBuilder: (context, i) {
                      final p = people[i];
                      final selected = _sel.contains(p.id);
                      return PersonTile(
                        person: p,
                        selected: selected,
                        trailing: widget.multi
                            ? Icon(selected ? AppIcons.checkCircle : AppIcons.add,
                                color: selected ? context.ft.accent : context.ft.text3, size: 22)
                            : null,
                        onTap: () {
                          if (!widget.multi) {
                            Navigator.of(context).pop([p.id]);
                            return;
                          }
                          setState(() => selected ? _sel.remove(p.id) : _sel.add(p.id));
                        },
                      );
                    },
                  ),
          ),
          if (widget.multi)
            Padding(
              padding: EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.xl, mq.padding.bottom + Gap.md),
              child: FTButton(
                label: _sel.isEmpty ? 'Done' : 'Done · ${_sel.length} selected',
                expand: true,
                onTap: () => Navigator.of(context).pop(_sel.toList()),
              ),
            ),
        ],
      ),
    );
  }
}

/// Wrap of small removable person chips (used in forms).
class PersonChips extends ConsumerWidget {
  const PersonChips({super.key, required this.ids, this.onRemove, this.onAdd, this.addLabel = 'Add people'});
  final List<String> ids;
  final ValueChanged<String>? onRemove;
  final VoidCallback? onAdd;
  final String addLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final c = context.ft;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final id in ids)
          if (g[id] != null)
            Container(
              padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
              decoration: BoxDecoration(
                color: c.isDark ? Colors.white.withValues(alpha: 0.06) : c.surfaceHigh,
                borderRadius: BorderRadius.circular(Radii.pill),
                border: Border.all(color: c.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PersonAvatarFor(g[id]!, size: 26),
                  const SizedBox(width: 8),
                  Text(g[id]!.displayName, style: context.tx.label),
                  if (onRemove != null)
                    GestureDetector(
                      onTap: () => onRemove!(id),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(AppIcons.close, size: 14, color: c.text3,
                            semanticLabel: 'Remove ${g[id]!.displayName}'),
                      ),
                    ),
                ],
              ),
            ),
        if (onAdd != null) FTChip(label: addLabel, icon: AppIcons.add, selected: false, onTap: onAdd),
      ],
    );
  }
}
