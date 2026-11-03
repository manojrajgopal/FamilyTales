import '../../core/models/enums.dart';
import '../family/domain/family_graph.dart';

/// Relationships a user can choose when adding a relative. Only parent and
/// partner edges are stored; every option below is translated into those
/// edges by [RelationPlanner].
enum RelationKind {
  father('Father', Gender.male, 'Parents'),
  mother('Mother', Gender.female, 'Parents'),
  parent('Parent', null, 'Parents'),
  stepParent('Step-parent', null, 'Parents'),
  adoptiveParent('Adoptive parent', null, 'Parents'),
  fosterParent('Foster parent', null, 'Parents'),
  guardian('Guardian', null, 'Parents'),
  husband('Husband', Gender.male, 'Partners'),
  wife('Wife', Gender.female, 'Partners'),
  spouse('Spouse', null, 'Partners'),
  partner('Partner', null, 'Partners'),
  son('Son', Gender.male, 'Children'),
  daughter('Daughter', Gender.female, 'Children'),
  child('Child', null, 'Children'),
  stepChild('Step-child', null, 'Children'),
  adoptedChild('Adopted child', null, 'Children'),
  fosterChild('Foster child', null, 'Children'),
  brother('Brother', Gender.male, 'Siblings'),
  sister('Sister', Gender.female, 'Siblings'),
  sibling('Sibling', null, 'Siblings'),
  grandfather('Grandfather', Gender.male, 'Extended family'),
  grandmother('Grandmother', Gender.female, 'Extended family'),
  grandparent('Grandparent', null, 'Extended family'),
  grandchild('Grandchild', null, 'Extended family'),
  uncle('Uncle', Gender.male, 'Extended family'),
  aunt('Aunt', Gender.female, 'Extended family'),
  nephew('Nephew', Gender.male, 'Extended family'),
  niece('Niece', Gender.female, 'Extended family'),
  cousin('Cousin', null, 'Extended family');

  const RelationKind(this.label, this.gender, this.group);
  final String label;
  final Gender? gender;
  final String group;

  static RelationKind? parse(String? s) =>
      RelationKind.values.where((r) => r.name == s).firstOrNull;
}

/// What must happen to connect a new (or existing) person as [kind] of the
/// anchor person.
class RelationPlan {
  const RelationPlan({
    this.parents = const [],
    this.children = const [],
    this.partners = const [],
    this.blockedReason,
    this.choices = const [],
    this.choicePrompt,
    this.coParentChoices = const [],
    this.createParentsFor,
  });

  /// The new person's parents (id, type).
  final List<(String, ParentType)> parents;

  /// The new person's children (id, type).
  final List<(String, ParentType)> children;
  final List<String> partners;

  /// Set when the relationship can't be created yet (e.g. a sibling needs a
  /// shared parent first).
  final String? blockedReason;

  /// When non-empty, the user must pick one of these anchor relatives first
  /// (e.g. "through which parent?").
  final List<String> choices;
  final String? choicePrompt;

  /// For new children: the anchor's partners who could be the other parent.
  final List<String> coParentChoices;

  /// Set when [createParentsFor] has no parents recorded yet: the shared
  /// parent(s) are created together with the new person (names optional) and
  /// linked to both, so siblings / uncles / aunts can be added in one go.
  final String? createParentsFor;

  bool get needsChoice => choices.length > 1;
  bool get isBlocked => blockedReason != null;
}

class RelationPlanner {
  RelationPlanner(this.g);
  final FamilyGraph g;

  RelationPlan plan(RelationKind kind, String anchorId, {String? choiceId, String? coParentId}) {
    final anchor = g[anchorId];
    final name = anchor?.shortName ?? 'this person';
    switch (kind) {
      case RelationKind.father:
      case RelationKind.mother:
      case RelationKind.parent:
        return RelationPlan(children: [(anchorId, ParentType.biological)]);
      case RelationKind.stepParent:
        return RelationPlan(children: [(anchorId, ParentType.step)]);
      case RelationKind.adoptiveParent:
        return RelationPlan(children: [(anchorId, ParentType.adoptive)]);
      case RelationKind.fosterParent:
        return RelationPlan(children: [(anchorId, ParentType.foster)]);
      case RelationKind.guardian:
        return RelationPlan(children: [(anchorId, ParentType.guardian)]);
      case RelationKind.husband:
      case RelationKind.wife:
      case RelationKind.spouse:
      case RelationKind.partner:
        return RelationPlan(partners: [anchorId]);
      case RelationKind.son:
      case RelationKind.daughter:
      case RelationKind.child:
      case RelationKind.stepChild:
      case RelationKind.adoptedChild:
      case RelationKind.fosterChild:
        final type = switch (kind) {
          RelationKind.stepChild => ParentType.step,
          RelationKind.adoptedChild => ParentType.adoptive,
          RelationKind.fosterChild => ParentType.foster,
          _ => ParentType.biological,
        };
        final partners = g.partnerIds(anchorId);
        final parents = <(String, ParentType)>[(anchorId, type)];
        if (coParentId != null && coParentId != anchorId) {
          parents.add((coParentId, type == ParentType.step ? ParentType.biological : type));
        }
        return RelationPlan(parents: parents, coParentChoices: partners);
      case RelationKind.brother:
      case RelationKind.sister:
      case RelationKind.sibling:
        final ps = g.kinParents(anchorId);
        if (ps.isEmpty) return RelationPlan(createParentsFor: anchorId);
        return RelationPlan(parents: [
          for (final p in ps) (p, g.parentType(p, anchorId) ?? ParentType.biological)
        ]);
      case RelationKind.grandfather:
      case RelationKind.grandmother:
      case RelationKind.grandparent:
        final ps = g.parentIds(anchorId, lineageOnly: true);
        if (ps.isEmpty) {
          return RelationPlan(
              blockedReason: 'Add $name’s parents first – grandparents are their parents.');
        }
        final chosen = choiceId ?? (ps.length == 1 ? ps.first : null);
        if (chosen == null) {
          return RelationPlan(choices: ps, choicePrompt: 'On which side of the family?');
        }
        return RelationPlan(children: [(chosen, ParentType.biological)], choices: ps);
      case RelationKind.grandchild:
        final cs = g.childIds(anchorId, lineageOnly: true);
        if (cs.isEmpty) {
          return RelationPlan(blockedReason: 'Add $name’s children first – grandchildren are their children.');
        }
        final chosen = choiceId ?? (cs.length == 1 ? cs.first : null);
        if (chosen == null) return RelationPlan(choices: cs, choicePrompt: 'Whose child is it?');
        return RelationPlan(parents: [(chosen, ParentType.biological)], choices: cs);
      case RelationKind.uncle:
      case RelationKind.aunt:
        final ps = g.parentIds(anchorId, lineageOnly: true);
        if (ps.isEmpty) {
          return RelationPlan(blockedReason: 'Add $name’s parents first – an uncle or aunt is a parent’s sibling.');
        }
        final chosen = choiceId ?? (ps.length == 1 ? ps.first : null);
        if (chosen == null) {
          return RelationPlan(choices: ps, choicePrompt: 'Sibling of which parent?');
        }
        final gps = g.kinParents(chosen);
        if (gps.isEmpty) return RelationPlan(choices: ps, createParentsFor: chosen);
        return RelationPlan(parents: [for (final gp in gps) (gp, ParentType.biological)], choices: ps);
      case RelationKind.nephew:
      case RelationKind.niece:
        final sibs = g.siblings(anchorId).map((s) => s.personId).toList();
        if (sibs.isEmpty) {
          return RelationPlan(blockedReason: 'Add $name’s brother or sister first.');
        }
        final chosen = choiceId ?? (sibs.length == 1 ? sibs.first : null);
        if (chosen == null) return RelationPlan(choices: sibs, choicePrompt: 'Child of which sibling?');
        return RelationPlan(parents: [(chosen, ParentType.biological)], choices: sibs);
      case RelationKind.cousin:
        final piblings = <String>{
          for (final p in g.parentIds(anchorId, lineageOnly: true))
            for (final s in g.siblings(p))
              if (s.kind != SiblingKind.step) s.personId
        }.toList();
        if (piblings.isEmpty) {
          return RelationPlan(
              blockedReason: 'Add an uncle or aunt of $name first – cousins are their children.');
        }
        final chosen = choiceId ?? (piblings.length == 1 ? piblings.first : null);
        if (chosen == null) {
          return RelationPlan(choices: piblings, choicePrompt: 'Child of which uncle or aunt?');
        }
        return RelationPlan(parents: [(chosen, ParentType.biological)], choices: piblings);
    }
  }
}
