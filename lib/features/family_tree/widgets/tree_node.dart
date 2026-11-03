import 'package:flutter/material.dart';

import '../../../core/database/app_database.dart';
import '../../../core/models/enums.dart';
import '../../../core/widgets/widgets.dart';
import '../../family/domain/family_graph.dart';
import '../layout/tree_layout.dart';

/// A person in the tree canvas: photo/initials, name, years and status.
class TreeNodeCard extends StatelessWidget {
  const TreeNodeCard({
    super.key,
    required this.person,
    required this.node,
    required this.options,
    required this.imagePath,
    required this.selected,
    required this.dimmed,
    required this.collapsed,
    required this.onTap,
    required this.onExpandChildren,
    required this.onRevealParents,
    this.showGender = true,
  });

  final Person person;
  final LayoutNode node;
  final TreeLayoutOptions options;
  final String? imagePath;
  final bool selected;
  final bool dimmed;
  final bool collapsed;
  final VoidCallback onTap;
  final VoidCallback onExpandChildren;
  final VoidCallback onRevealParents;

  /// Colours the card's border by gender (the background stays plain).
  final bool showGender;

  /// Vertical space above and below the card reserved for the expand
  /// badges (kept inside the widget so they remain tappable).
  static const badgeSpace = 28.0;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final compact = options.compact;
    final w = options.nodeWidth, h = options.nodeHeight;
    final focus = node.isFocus;
    final br = BorderRadius.circular(compact ? 20 : 24);
    final years = person.lifespanLabel;
    final gs = showGender ? GenderStyle.of(person.gender, dark: c.isDark) : null;

    final card = AnimatedContainer(
      key: gs == null ? null : ValueKey('gender-${gs.gender.name}'),
      duration: context.reduceMotion ? Duration.zero : Motion.medium,
      curve: Motion.curve,
      width: w,
      height: h,
      decoration: BoxDecoration(
        borderRadius: br,
        gradient: c.cardGradient,
        boxShadow: [
          ...c.cardShadow,
          if (selected)
            BoxShadow(color: c.accent.withValues(alpha: 0.35), blurRadius: 26, spreadRadius: -2),
        ],
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: br,
        border: Border.all(
          color: selected
              ? c.accent
              : gs != null
                  ? gs.color
                  : (focus ? c.accent.withValues(alpha: 0.45) : c.border),
          width: selected ? 2.2 : (gs != null ? 2 : 1),
        ),
      ),
      padding: EdgeInsets.fromLTRB(8, compact ? 10 : 14, 8, 8),
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              PersonAvatar(
                name: person.displayName,
                imagePath: imagePath,
                size: compact ? 50 : 64,
                ring: selected || focus,
                deceased: !person.isLiving,
              ),
              Positioned(
                right: -1,
                bottom: compact ? 0 : 2,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: person.isLiving ? c.accent : c.text3,
                    border: Border.all(color: c.cardMid, width: 2),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 6 : 10),
          Text(
            compact ? person.shortName : person.displayName,
            maxLines: compact ? 1 : 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            textScaler: TextScaler.noScaling,
            style: context.tx.label.copyWith(
              fontSize: compact ? 11.5 : 13.2,
              height: 1.2,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (!compact) const Spacer(),
          if (years.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: compact ? 2 : 0),
              child: Text(
                compact ? (person.birth?.formatYear() ?? '') : years,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textScaler: TextScaler.noScaling,
                style: context.tx.micro.copyWith(fontSize: compact ? 10 : 11, color: c.text3),
              ),
            ),
        ],
      ),
    );

    const pad = TreeNodeCard.badgeSpace;
    return SizedBox(
      width: w,
      height: h + pad * 2,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: pad,
            child: AnimatedOpacity(
              duration: Motion.medium,
              opacity: dimmed ? 0.42 : 1,
              child: Pressable(
                onTap: onTap,
                scale: 0.95,
                semanticLabel: '${person.displayName}'
                    '${person.gender == Gender.unknown ? '' : ', ${person.gender.label}'}'
                    '${years.isEmpty ? '' : ', $years'}${person.isLiving ? '' : ', deceased'}',
                child: card,
              ),
            ),
          ),
          if (node.hiddenParents > 0)
            Positioned(
              top: 2,
              left: w / 2 - 14,
              child: _Badge(
                icon: AppIcons.arrowUp,
                tooltip: 'Show ${person.shortName}’s parents',
                onTap: onRevealParents,
              ),
            ),
          if (node.hiddenChildren > 0)
            Positioned(
              top: pad + h - 2,
              left: w / 2 - 22,
              child: _Badge(
                label: '+${node.hiddenChildren}',
                tooltip: collapsed
                    ? 'Expand ${person.shortName}’s branch'
                    : 'Show ${person.shortName}’s descendants',
                onTap: onExpandChildren,
              ),
            ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({this.icon, this.label, required this.tooltip, required this.onTap});
  final IconData? icon;
  final String? label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Tooltip(
      message: tooltip,
      child: Pressable(
        onTap: onTap,
        semanticLabel: tooltip,
        child: Container(
          height: 28,
          constraints: const BoxConstraints(minWidth: 28),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            gradient: c.accentGradient,
            borderRadius: BorderRadius.circular(Radii.pill),
            border: Border.all(color: c.bg0, width: 2),
          ),
          alignment: Alignment.center,
          child: icon != null
              ? Icon(icon, size: 14, color: c.onAccent)
              : Text(label!,
                  textScaler: TextScaler.noScaling,
                  style: context.tx.micro.copyWith(color: c.onAccent, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}
