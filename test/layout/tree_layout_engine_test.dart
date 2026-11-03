import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:family_tales/core/database/app_database.dart';
import 'package:family_tales/core/models/enums.dart';
import 'package:family_tales/core/repositories/family_repository.dart';
import 'package:family_tales/features/family/domain/family_graph.dart';
import 'package:family_tales/features/family_tree/layout/tree_layout.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/layout_harness.dart';

TreeLayout _layout(FamilyGraph g, {TreeViewMode mode = TreeViewMode.full, String? focus}) =>
    TreeLayoutEngine(g).compute(TreeLayoutOptions(mode: mode, focusId: focus, generationsUp: 99, generationsDown: 99));

/// Lays out [g] in the full and compact views and checks every rule.
TreeLayout _valid(FamilyGraph g, {String? focus}) {
  late TreeLayout full;
  for (final mode in [TreeViewMode.full, TreeViewMode.compact]) {
    final l = _layout(g, mode: mode, focus: focus);
    final d = validateLayout(g, l, expected: g.people.keys.toSet());
    expect(d, isEmpty, reason: '${mode.name}:\n${d.take(12).join('\n')}');
    if (mode == TreeViewMode.full) full = l;
  }
  return full;
}

double _cx(TreeLayout l, String id) => l.nodes[id]!.center(l.options).dx;

/// Families whose lines reach [child].
List<FamilyConnector> _linesTo(TreeLayout l, String child) =>
    [for (final f in l.families) if (f.children.any((c) => c.childId == child)) f];

/// Same positions for every person and every connector.
void _expectSame(TreeLayout a, TreeLayout b) {
  expect(b.nodes.keys.toSet(), a.nodes.keys.toSet());
  for (final id in a.nodes.keys) {
    expect(b.nodes[id]!.x, closeTo(a.nodes[id]!.x, 0.001), reason: id);
    expect(b.nodes[id]!.y, closeTo(a.nodes[id]!.y, 0.001), reason: id);
  }
  expect(b.size, a.size);
  expect(b.families.length, a.families.length);
  expect(b.partners.length, a.partners.length);
}

void main() {
  // ---------------------------------------------------------------------------
  group('The layout checker itself catches broken layouts', () {
    late GraphBuilder b;
    late String dad, mum, kid, kid2, stranger;
    late FamilyGraph g;
    late TreeLayout l;

    setUp(() {
      b = GraphBuilder();
      dad = b.person('Dad', gender: Gender.male);
      mum = b.person('Mum', gender: Gender.female);
      b.couple(dad, mum);
      kid = b.child([dad, mum], 'Kid');
      kid2 = b.child([dad, mum], 'Kid2');
      stranger = b.person('Stranger');
      g = b.build();
      l = _layout(g);
    });

    Set<String> defects(TreeLayout l, {bool all = true}) =>
        defectSummary(validateLayout(g, l, expected: all ? g.people.keys.toSet() : null)).keys.toSet();

    test('a correct layout has no defects', () => expect(defects(l), isEmpty));

    test('overlapping cards', () {
      l.nodes[mum]!.x = l.nodes[dad]!.x + 10;
      expect(defects(l), contains('overlap'));
    });

    test('NaN and infinite coordinates', () {
      l.nodes[kid]!.x = double.nan;
      expect(defects(l), contains('nan'));
      l.nodes[kid]!.x = double.infinity;
      expect(defects(l), contains('nan'));
    });

    test('a card outside the canvas', () {
      l.nodes[kid]!.y = l.size.height + 40;
      expect(defects(l), containsAll(['bounds', 'layer-y']));
    });

    test('a person left out of the layout', () {
      final missing = TreeLayout(l.options, {...l.nodes}..remove(kid), l.partners, l.families, l.size);
      expect(defects(missing), containsAll(['missing', 'child-missing']));
    });

    test('a line that does not end on its card', () {
      final f = l.families.single;
      final c = f.children.first;
      final bad = TreeLayout(l.options, l.nodes, l.partners,
          [FamilyConnector(f.parents, f.origin, f.busY, [ChildLine(c.childId, c.type, c.top + const Offset(40, 0)), f.children.last])],
          l.size);
      expect(defects(bad), contains('child-top'));
    });

    test('a line running through an unrelated card', () {
      final drop = l.families.single.children.first.top;
      l.nodes[stranger]!
        ..x = drop.dx - l.options.nodeWidth / 2
        ..y = drop.dy - 30;
      expect(defects(l), contains('through-card'));
    });

    test('a relationship without a line', () {
      final none = TreeLayout(l.options, l.nodes, l.partners, const [], l.size);
      expect(defects(none), contains('link-missing'));
      final noCouple = TreeLayout(l.options, l.nodes, const [], l.families, l.size);
      expect(defects(noCouple), contains('partner-missing'));
    });

    test('a relationship drawn twice', () {
      final twice = TreeLayout(l.options, l.nodes, l.partners, [...l.families, ...l.families], l.size);
      expect(defects(twice), contains('link-duplicate'));
    });

    test('two families sharing one horizontal line', () {
      final f = l.families.single;
      final other = FamilyConnector([dad], Offset(l.nodes[dad]!.x + l.options.nodeWidth / 2, l.nodes[dad]!.y + l.options.nodeHeight),
          f.busY, [ChildLine(kid2, ParentType.step, l.nodes[kid2]!.rect(l.options).topCenter)]);
      final shared = TreeLayout(l.options, l.nodes, l.partners, [f, other], l.size);
      expect(defects(shared), contains('bus-shared'));
    });

    test('a child drawn on its parents\' row', () {
      final n = l.nodes[kid]!;
      final flat = {...l.nodes, kid: LayoutNode(kid, l.nodes[dad]!.layer)..x = n.x..y = n.y};
      expect(defects(TreeLayout(l.options, flat, l.partners, l.families, l.size)), contains('parent-below'));
    });
  });

  // ---------------------------------------------------------------------------
  group('Scenario A: small family', () {
    for (final n in [1, 2, 3]) {
      test('2 parents with $n ${n == 1 ? 'child' : 'children'}', () {
        final b = GraphBuilder();
        final dad = b.person('Dad', gender: Gender.male, born: 1970);
        final mum = b.person('Mum', gender: Gender.female, born: 1972);
        b.couple(dad, mum);
        final kids = [for (var i = 0; i < n; i++) b.child([dad, mum], 'K$i', born: 2000 + i)];
        final g = b.build();
        final l = _valid(g);

        // Generations.
        expect(l.nodes[dad]!.y, l.nodes[mum]!.y);
        for (final k in kids) {
          expect(l.nodes[k]!.layer, l.nodes[dad]!.layer + 1);
          expect(l.nodes[k]!.y, l.nodes[kids.first]!.y);
        }
        // Children in birth order, evenly spaced.
        final xs = [for (final k in kids) l.nodes[k]!.x];
        expect(xs, orderedEquals([...xs]..sort()));
        for (var i = 2; i < xs.length; i++) {
          expect(xs[i] - xs[i - 1], closeTo(xs[1] - xs[0], 0.5));
        }
        // One family line from the couple, centred over the children.
        final f = l.families.single;
        expect(f.parents.toSet(), {dad, mum});
        expect(f.children.map((c) => c.childId).toSet(), kids.toSet());
        expect(f.origin.dx, closeTo((_cx(l, kids.first) + _cx(l, kids.last)) / 2, 1));
        expect(f.origin.dx, closeTo((_cx(l, dad) + _cx(l, mum)) / 2, 0.5));
        // The couple line joins the facing card edges.
        final p = l.partners.single;
        expect(p.adjacent, isTrue);
        expect(p.from.dx, closeTo(l.nodes[dad]!.x + l.options.nodeWidth, 0.01));
        expect(p.to.dx, closeTo(l.nodes[mum]!.x, 0.01));
      });

      test('single parent with $n ${n == 1 ? 'child' : 'children'}', () {
        final b = GraphBuilder();
        final mum = b.person('Mum', gender: Gender.female);
        final kids = [for (var i = 0; i < n; i++) b.child([mum], 'K$i', born: 2000 + i)];
        final g = b.build();
        final l = _valid(g);
        final f = l.families.single;
        expect(f.parents, [mum]);
        expect(f.origin, Offset(_cx(l, mum), l.nodes[mum]!.y + l.options.nodeHeight));
        expect(f.origin.dx, closeTo((_cx(l, kids.first) + _cx(l, kids.last)) / 2, 1));
      });
    }
  });

  // ---------------------------------------------------------------------------
  group('Scenario B: medium family', () {
    test('grandparents, parents, four children, aunts and uncles', () {
      final b = GraphBuilder();
      final gpa = b.person('Grandpa', gender: Gender.male, born: 1940);
      final gma = b.person('Grandma', gender: Gender.female, born: 1942);
      b.couple(gpa, gma);
      final dad = b.child([gpa, gma], 'Dad', gender: Gender.male, born: 1968);
      final aunt = b.child([gpa, gma], 'Aunt', gender: Gender.female, born: 1970);
      final uncle = b.child([gpa, gma], 'Uncle', gender: Gender.male, born: 1972);
      final mum = b.person('Mum', gender: Gender.female, born: 1969);
      b.couple(dad, mum);
      final uncleWife = b.person('UncleWife', gender: Gender.female, born: 1973);
      b.couple(uncle, uncleWife);
      final kids = [for (var i = 0; i < 4; i++) b.child([dad, mum], 'Kid$i', born: 1995 + i)];
      final cousins = [for (var i = 0; i < 2; i++) b.child([uncle, uncleWife], 'Cousin$i', born: 2000 + i)];
      final g = b.build();
      final l = _valid(g);

      expect({for (final n in l.nodes.values) n.layer}, {0, 1, 2});
      for (final s in [dad, aunt, uncle, mum, uncleWife]) {
        expect(l.nodes[s]!.layer, 1);
      }
      for (final k in [...kids, ...cousins]) {
        expect(l.nodes[k]!.layer, 2);
      }
      // Partners side by side.
      for (final p in l.partners) {
        expect(p.adjacent, isTrue);
      }
      // The grandparents' line spans their children.
      final top = _linesTo(l, dad).single;
      expect(top.parents.toSet(), {gpa, gma});
      final childXs = [_cx(l, dad), _cx(l, aunt), _cx(l, uncle)];
      expect(top.origin.dx, inInclusiveRange(childXs.reduce((a, b) => a < b ? a : b), childXs.reduce((a, b) => a > b ? a : b)));
      // Siblings evenly spaced in birth order; cousins connect to their own parents.
      final xs = [for (final k in kids) l.nodes[k]!.x];
      for (var i = 2; i < xs.length; i++) {
        expect(xs[i] - xs[i - 1], closeTo(xs[1] - xs[0], 0.5));
      }
      for (final c in cousins) {
        expect(_linesTo(l, c).single.parents.toSet(), {uncle, uncleWife});
      }
    });
  });

  // ---------------------------------------------------------------------------
  group('Scenario C: large family', () {
    test('four generations, 20+ people, several branches and partners', () {
      final b = GraphBuilder();
      final a = b.person('A', gender: Gender.male, born: 1920), a2 = b.person('A2', gender: Gender.female, born: 1922);
      b.couple(a, a2);
      final gen2 = <String>[];
      for (var i = 0; i < 3; i++) {
        final c = b.child([a, a2], 'B$i', gender: i.isEven ? Gender.male : Gender.female, born: 1945 + i);
        final s = b.person('BS$i', gender: i.isEven ? Gender.female : Gender.male, born: 1946 + i);
        b.couple(c, s);
        gen2.add(c);
        for (var j = 0; j < 2 + i; j++) {
          final gc = b.child([c, s], 'C$i$j', gender: j.isEven ? Gender.male : Gender.female, born: 1970 + j);
          if (j == 0) {
            final gs = b.person('CS$i$j', born: 1971);
            b.couple(gc, gs);
            b.child([gc, gs], 'D$i${j}a', born: 1995);
            b.child([gc, gs], 'D$i${j}b', born: 1997);
          }
        }
      }
      // A second marriage with a child in generation two.
      final second = b.person('B0second', gender: Gender.female, born: 1950);
      b.couple(gen2.first, second, status: PartnerStatus.current);
      b.couple(gen2.first, b.persons.firstWhere((p) => p.firstName == 'BS0').id, status: PartnerStatus.divorced);
      final half = b.child([gen2.first, second], 'Half', born: 1980);
      final g = b.build();
      expect(g.size, greaterThanOrEqualTo(20));
      final l = _valid(g);
      expect({for (final n in l.nodes.values) n.layer}.length, 4);
      expect(_linesTo(l, half).expand((f) => f.parents).toSet(), {gen2.first, second});
    });
  });

  // ---------------------------------------------------------------------------
  group('Scenario D: very large families', () {
    for (final size in [100, 250, 500, 1000, 2000]) {
      test('$size people: valid and fast', () {
        final g = randomFamily(size, size: size);
        final sw = Stopwatch()..start();
        final l = _layout(g);
        sw.stop();
        final d = validateLayout(g, l, expected: g.people.keys.toSet());
        expect(d, isEmpty, reason: d.take(12).join('\n'));
        final compact = _layout(g, mode: TreeViewMode.compact);
        expect(validateLayout(g, compact, expected: g.people.keys.toSet()), isEmpty);
        // Debug-mode test VM; release builds are several times faster.
        expect(sw.elapsedMilliseconds, lessThan(size * 6 + 500), reason: '$size people took ${sw.elapsedMilliseconds} ms');
        // The canvas grows with the family but stays proportionate.
        final o = l.options;
        expect(l.size.width, lessThan(g.size * (o.nodeWidth + o.groupGap) + 2 * o.margin + 2000));
        // ignore: avoid_print
        print('$size people: ${sw.elapsedMilliseconds} ms, canvas ${l.size.width.round()}×${l.size.height.round()}');
      }, timeout: const Timeout(Duration(minutes: 2)));
    }
  });

  // ---------------------------------------------------------------------------
  group('Scenario E: complex relationships', () {
    test('a parent who is not recorded (unknown parent type)', () {
      final b = GraphBuilder();
      final mum = b.person('Mum');
      final kid = b.child([mum], 'Kid', type: ParentType.unknown);
      final l = _valid(b.build());
      expect(_linesTo(l, kid).single.children.single.type, ParentType.unknown);
    });

    test('three marriages, a child with each partner (half-siblings)', () {
      final b = GraphBuilder();
      final h = b.person('Hub', gender: Gender.male, born: 1950);
      final partners = [for (var i = 0; i < 3; i++) b.person('P$i', gender: Gender.female, born: 1952 + i)];
      for (final (i, p) in partners.indexed) {
        b.couple(h, p, status: i < 2 ? PartnerStatus.divorced : PartnerStatus.current);
      }
      final kids = [for (final (i, p) in partners.indexed) b.child([h, p], 'K$i', born: 1975 + i * 5)];
      final l = _valid(b.build());
      expect(l.partners, hasLength(3));
      // Only two partners can stand beside him; the third gets a bracket.
      expect(l.partners.where((p) => !p.adjacent).single.bracketY, isNotNull);
      for (final (i, k) in kids.indexed) {
        expect(_linesTo(l, k).expand((f) => f.parents).toSet(), {h, partners[i]}, reason: 'K$i');
        expect(l.nodes[k]!.layer, l.nodes[h]!.layer + 1);
      }
    });

    test('children from different partners on both sides of a parent', () {
      final b = GraphBuilder();
      final m = b.person('Mum', gender: Gender.female, born: 1960);
      final d1 = b.person('First', gender: Gender.male, born: 1958), d2 = b.person('Second', gender: Gender.male, born: 1959);
      b
        ..couple(d1, m, status: PartnerStatus.divorced)
        ..couple(m, d2);
      final a = [b.child([d1, m], 'A1', born: 1982), b.child([d1, m], 'A2', born: 1984)];
      final c = [b.child([m, d2], 'C1', born: 1990), b.child([m, d2], 'C2', born: 1992)];
      final l = _valid(b.build());
      // Each set of children sits under its own couple, not interleaved.
      final aMax = a.map((x) => _cx(l, x)).reduce((p, q) => p > q ? p : q);
      final cMin = c.map((x) => _cx(l, x)).reduce((p, q) => p < q ? p : q);
      final aMin = a.map((x) => _cx(l, x)).reduce((p, q) => p < q ? p : q);
      final cMax = c.map((x) => _cx(l, x)).reduce((p, q) => p > q ? p : q);
      expect(aMax < cMin || cMax < aMin, isTrue);
    });

    test('a married-in branch sits just above its child even with other children', () {
      // Regression: the in-laws were left at the top of the tree because
      // their unmarried daughter pinned them there.
      final b = GraphBuilder();
      var top = [b.person('G0', gender: Gender.male), b.person('G0w', gender: Gender.female)];
      b.couple(top[0], top[1]);
      String? groom;
      for (var i = 0; i < 4; i++) {
        final c = b.child(top, 'Line$i', gender: Gender.male);
        final w = b.person('Wife$i', gender: Gender.female);
        b.couple(c, w);
        top = [c, w];
        groom = c;
      }
      final inLawDad = b.person('InLawDad', gender: Gender.male), inLawMum = b.person('InLawMum', gender: Gender.female);
      b.couple(inLawDad, inLawMum);
      final bride = b.child([inLawDad, inLawMum], 'Bride', gender: Gender.female);
      final sister = b.child([inLawDad, inLawMum], 'Sister', gender: Gender.female);
      final newGroom = b.child(top, 'Groom', gender: Gender.male);
      b.couple(newGroom, bride);
      final l = _valid(b.build());
      expect(l.nodes[bride]!.layer, l.nodes[newGroom]!.layer);
      expect(l.nodes[inLawDad]!.layer, l.nodes[bride]!.layer - 1);
      expect(l.nodes[sister]!.layer, l.nodes[bride]!.layer);
      expect(groom, isNotNull);
    });

    test('grandparents with many children and large cousin branches', () {
      final b = GraphBuilder();
      final gp = [b.person('GP', gender: Gender.male), b.person('GM', gender: Gender.female)];
      b.couple(gp[0], gp[1]);
      final cousins = <String>[];
      for (var i = 0; i < 6; i++) {
        final c = b.child(gp, 'Child$i', born: 1950 + i);
        final s = b.person('Spouse$i', born: 1950 + i);
        b.couple(c, s);
        for (var j = 0; j < 5; j++) {
          cousins.add(b.child([c, s], 'Cousin$i$j', born: 1975 + j));
        }
      }
      final l = _valid(b.build());
      expect({for (final c in cousins) l.nodes[c]!.y}.length, 1, reason: 'cousins share a generation');
    });

    test('adoptive, step, foster and guardian lines keep their own kind', () {
      final b = GraphBuilder();
      final mum = b.person('Mum', gender: Gender.female, born: 1960);
      final step = b.person('StepDad', gender: Gender.male, born: 1958);
      b.couple(step, mum);
      final kid = b.child([mum], 'Kid', born: 1985);
      b.parent(step, kid, ParentType.step);
      final adopted = b.child([mum, step], 'Adopted', born: 1990, type: ParentType.adoptive);
      final fostered = b.child([mum], 'Fostered', born: 1992, type: ParentType.foster);
      final guardian = b.person('Guardian', born: 1940);
      final ward = b.child([guardian], 'Ward', born: 1990, type: ParentType.guardian);
      final l = _valid(b.build());
      // The step-parent's line is separate from the birth mother's.
      final kidLines = {for (final f in _linesTo(l, kid)) f.parents.join(): f.children.firstWhere((c) => c.childId == kid).type};
      expect(kidLines, {mum: ParentType.biological, step: ParentType.step});
      expect(_linesTo(l, adopted).single.children.single.type, ParentType.adoptive);
      expect(_linesTo(l, fostered).single.children.firstWhere((c) => c.childId == fostered).type, ParentType.foster);
      // A guardian sits above the ward, like a parent.
      expect(l.nodes[guardian]!.layer, lessThan(l.nodes[ward]!.layer));
    });

    test('a marriage across generations routes lines around the cards in between', () {
      final b = GraphBuilder();
      final old = [b.person('Old', gender: Gender.male), b.person('OldW', gender: Gender.female)];
      b.couple(old[0], old[1]);
      var line = old;
      for (var i = 0; i < 3; i++) {
        final c = b.child(line, 'Gen$i', gender: Gender.male);
        final w = b.person('W$i', gender: Gender.female);
        b.couple(c, w);
        // A sibling in every generation fills the rows in between.
        b.child(line, 'Sib$i');
        line = [c, w];
      }
      // A son of the oldest couple marries into the youngest generation.
      final late = b.child(old, 'LateSon', gender: Gender.male);
      b.couple(late, line[0]);
      b.child([late, line[0]], 'Mixed');
      final l = _valid(b.build());
      // The line from the old couple down to their late son skips rows and
      // is routed through lanes.
      final skip = _linesTo(l, late).single.children.firstWhere((c) => c.childId == late);
      expect(skip.route, isNotNull);
      expect(skip.route!.length, greaterThan(3));
    });

    test('people without relationships and couples without children', () {
      final b = GraphBuilder();
      b.person('Alone');
      final x = b.person('X'), y = b.person('Y');
      b.couple(x, y);
      final m = b.person('M');
      b.child([m], 'C');
      final l = _valid(b.build());
      expect(l.nodes, hasLength(5));
    });

    test('incomplete data in focus view: parents out of view stay hidden', () {
      final g = randomFamily(7, size: 80);
      final focus = g.people.keys.elementAt(40);
      for (final mode in TreeViewMode.values) {
        final l = _layout(g, mode: mode, focus: focus);
        expect(validateLayout(g, l), isEmpty, reason: mode.name);
        expect(l.nodes, contains(focus));
      }
    });

    test('contradictory data does not hang or produce invalid coordinates', () {
      final b = GraphBuilder();
      final a = b.person('A'), c = b.child([a], 'C');
      final gc = b.child([c], 'GC');
      b.couple(a, gc); // a partner who is also a grandchild
      b.parent(a, a); // a self link
      b.couple(c, c);
      final g = b.build();
      final sw = Stopwatch()..start();
      for (final mode in TreeViewMode.values) {
        final l = _layout(g, mode: mode, focus: a);
        final kinds = defectSummary(validateLayout(g, l)).keys.toSet();
        expect(kinds.intersection({'nan', 'overlap', 'bounds', 'unknown', 'missing', 'size'}), isEmpty, reason: mode.name);
      }
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('a couple recorded twice (married, divorced, remarried)', () {
      final b = GraphBuilder();
      final x = b.person('X', gender: Gender.male), y = b.person('Y', gender: Gender.female);
      b
        ..couple(x, y, status: PartnerStatus.divorced)
        ..couple(x, y);
      b.child([x, y], 'K');
      final l = _valid(b.build());
      expect(l.partners, hasLength(2));
    });

    for (var seed = 0; seed < 12; seed++) {
      for (final size in [12, 40, 120]) {
        test('random family seed $seed, $size people, every view', () {
          final g = randomFamily(seed, size: size);
          for (final mode in TreeViewMode.values) {
            final focus = g.people.keys.elementAt((seed * 7) % g.size);
            final l = _layout(g, mode: mode, focus: focus);
            final all = mode == TreeViewMode.full || mode == TreeViewMode.compact;
            final d = validateLayout(g, l, expected: all ? g.people.keys.toSet() : null);
            expect(d, isEmpty, reason: '${mode.name}:\n${d.take(12).join('\n')}');
          }
        });
      }
    }
  });

  // ---------------------------------------------------------------------------
  group('Scenario F: changes one at a time', () {
    test('growing from 2 to 140 people keeps every layout valid and stable', () {
      final b = GraphBuilder();
      final first = b.person('First', gender: Gender.male, born: 1950);
      final second = b.person('Second', gender: Gender.female, born: 1952);
      b.couple(first, second);
      var step = 0;
      TreeLayout? before;
      // Deterministic sequence of edits touching every kind of relative.
      void grow(int count) {
        for (var i = 0; i < count; i++) {
          step++;
          final ids = [for (final p in b.persons) p.id];
          final anchor = ids[(step * 37) % ids.length];
          switch (step % 6) {
            case 0 || 1 || 2: // child (with the anchor's partner when there is one)
              final partner = b.couples.where((c) => c.personAId == anchor || c.personBId == anchor).firstOrNull;
              final other = partner == null ? null : (partner.personAId == anchor ? partner.personBId : partner.personAId);
              b.child([anchor, ?other], 'Child$step', gender: step.isEven ? Gender.male : Gender.female, born: 1960 + step);
            case 3: // partner
              b.couple(anchor, b.person('Partner$step', born: 1960 + step));
            case 4: // parents for someone without any
              final orphan = ids.firstWhere((id) => b.links.every((l) => l.childId != id), orElse: () => anchor);
              if (b.links.any((l) => l.childId == orphan)) break;
              final p1 = b.person('Parent$step', gender: Gender.male), p2 = b.person('ParentW$step', gender: Gender.female);
              b
                ..couple(p1, p2)
                ..parent(p1, orphan)
                ..parent(p2, orphan);
            case _: // sibling: another child of the anchor's parents
              final ps = [for (final l in b.links) if (l.childId == anchor && l.type == ParentType.biological) l.parentId];
              if (ps.isEmpty) break;
              b.child(ps, 'Sibling$step', born: 1960 + step);
          }
        }
        final g = b.build();
        final l = _valid(g);
        // Determinism: the same family always gives the same picture.
        _expectSame(l, _layout(g));
        // Everyone already shown is still shown.
        if (before != null) expect(l.nodes.keys.toSet().containsAll(before!.nodes.keys), isTrue);
        before = l;
      }

      grow(1); // 3 people
      grow(5);
      grow(10);
      grow(20);
      for (var i = 0; i < 6; i++) {
        grow(15);
      }
      expect(b.persons.length, greaterThan(100));
    });

    test('adding a child never moves anyone else to another generation', () {
      final g0 = randomFamily(21, size: 150);
      final b = GraphBuilder()
        ..persons.addAll(g0.people.values)
        ..links.addAll(g0.links)
        ..couples.addAll(g0.couples);
      var before = _valid(b.build());
      for (var i = 0; i < 20; i++) {
        final parent = b.persons[(i * 53) % b.persons.length].id;
        final kid = b.child([parent], 'New$i');
        final after = _valid(b.build());
        for (final id in before.nodes.keys) {
          expect(after.nodes[id]!.layer, before.nodes[id]!.layer, reason: 'after adding New$i');
        }
        expect(after.nodes[kid]!.layer, after.nodes[parent]!.layer + 1);
        before = after;
      }
    });

    test('removing people and changing relationships', () {
      final g0 = randomFamily(3, size: 120);
      final b = GraphBuilder()
        ..persons.addAll(g0.people.values)
        ..links.addAll(g0.links)
        ..couples.addAll(g0.couples);
      _valid(b.build());
      // Remove ten people one by one, from the middle of the tree.
      for (var i = 0; i < 10; i++) {
        b.removePerson(b.persons[b.persons.length ~/ 2].id);
        _valid(b.build());
      }
      // Divorce, re-type, re-parent and break up.
      final c0 = b.couples.first;
      b.couples[0] = c0.copyWith(status: PartnerStatus.divorced);
      _valid(b.build());
      for (var i = 0; i < b.links.length; i += 7) {
        b.links[i] = b.links[i].copyWith(type: ParentType.adoptive);
      }
      _valid(b.build());
      final moved = b.links.lastWhere((l) => l.type == ParentType.biological);
      final newParent = b.persons.first.id;
      if (!b.build().wouldCreateCycle(newParent, moved.childId) && moved.parentId != newParent) {
        b.links[b.links.indexOf(moved)] = moved.copyWith(parentId: newParent);
      }
      _valid(b.build());
      b.couples.removeRange(0, 3);
      _valid(b.build());
    });

    test('a saved tree reopens with exactly the same layout', () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final dir = Directory.systemTemp.createTempSync('ft_layout');
      final file = File('${dir.path}/tree.db');
      final g0 = randomFamily(11, size: 90);
      var db = AppDatabase.open(file);
      var repo = FamilyRepository(db);
      final tree = await saveFamily(repo, g0, 'Layout');
      final g1 = await repo.loadGraph(tree);
      expect(g1.size, g0.size);
      final before = _valid(g1);
      await db.close();

      db = AppDatabase.open(file);
      repo = FamilyRepository(db);
      final g2 = await repo.loadGraph(tree);
      _expectSame(before, _valid(g2));
      await db.close();
      dir.deleteSync(recursive: true);
    });
  });
}
