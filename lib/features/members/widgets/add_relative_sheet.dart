import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/widgets/widgets.dart';
import '../relation_planner.dart';

/// The relatives people add most often, shown as big tiles. Everything else
/// (step, adoptive, foster, extended family…) sits behind "More relatives".
const _common = [
  RelationKind.father,
  RelationKind.mother,
  RelationKind.husband,
  RelationKind.wife,
  RelationKind.son,
  RelationKind.daughter,
  RelationKind.brother,
  RelationKind.sister,
];

IconData _iconFor(RelationKind r) => switch (r.group) {
      'Parents' => AppIcons.arrowUp,
      'Partners' => AppIcons.heart,
      'Children' => AppIcons.arrowDown,
      'Siblings' => AppIcons.arrowsLeftRight,
      _ => AppIcons.family,
    };

/// Opens the member form preconfigured to add a relative of [anchorId].
Future<void> showAddRelativeSheet(BuildContext context, String anchorId, String anchorName) {
  void open(BuildContext ctx, RelationKind r) {
    Navigator.of(ctx).pop();
    context.push(Routes.newPerson(relation: r.name, anchorId: anchorId));
  }

  return showFTSheet<void>(
    context,
    title: 'Add a relative of $anchorName',
    builder: (ctx) {
      var showAll = false;
      return StatefulBuilder(builder: (ctx, setState) {
        final c = ctx.ft;
        final groups = <String, List<RelationKind>>{};
        for (final r in RelationKind.values.where((r) => !_common.contains(r))) {
          (groups[r.group] ??= []).add(r);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: Gap.xs),
            LayoutBuilder(builder: (ctx, cons) {
              const cols = 4;
              final w = (cons.maxWidth - (cols - 1) * 8) / cols;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final r in _common)
                    Pressable(
                      onTap: () => open(ctx, r),
                      semanticLabel: 'Add ${r.label.toLowerCase()}',
                      child: Container(
                        width: w,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          gradient: c.chipGradient,
                          borderRadius: BorderRadius.circular(Radii.md),
                          border: Border.all(color: c.border),
                        ),
                        child: Column(
                          children: [
                            Icon(_iconFor(r), size: 20, color: c.accent),
                            const SizedBox(height: 6),
                            Text(r.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ctx.tx.label.copyWith(fontSize: 12.5)),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            }),
            const SizedBox(height: Gap.md),
            if (!showAll)
              Center(
                child: FTTextAction('More relatives (step, adopted, cousins…)',
                    accent: true, onTap: () => setState(() => showAll = true)),
              )
            else
              for (final e in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.xs),
                  child: Text(e.key, style: ctx.tx.caption),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final r in e.value)
                      FTChip(label: r.label, icon: _iconFor(r), selected: false, onTap: () => open(ctx, r)),
                  ],
                ),
              ],
          ],
        );
      });
    },
  );
}
