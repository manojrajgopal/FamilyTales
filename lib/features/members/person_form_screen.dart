import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/repositories/family_repository.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import 'relation_planner.dart';
import 'widgets/person_widgets.dart';

/// Quick one-page form to add or edit a family member: the essentials are
/// shown up front and everything else sits behind "More details". When opened with a
/// [relation] and [anchorId] it also connects the person (new or existing)
/// to the anchor using only parent/partner edges.
class PersonFormScreen extends ConsumerStatefulWidget {
  const PersonFormScreen({super.key, this.personId, this.relation, this.anchorId});
  final String? personId;
  final String? relation;
  final String? anchorId;

  @override
  ConsumerState<PersonFormScreen> createState() => _PersonFormScreenState();
}

class _PersonFormScreenState extends ConsumerState<PersonFormScreen> {
  final _form = GlobalKey<FormState>();
  final _scroll = ScrollController();
  bool _loaded = false;
  bool _dirty = false;
  bool _saving = false;
  bool _showMore = false;

  // Connect
  RelationKind? _relation;
  bool _useExisting = false;
  String? _existingId;
  String? _choiceId;
  String? _coParentId;
  bool _coParentTouched = false;
  PartnerType _partnerType = PartnerType.marriage;
  PartnerStatus _partnerStatus = PartnerStatus.current;
  FuzzyDate? _partnerStart;
  final _partnerPlace = TextEditingController();
  final _sharedFather = TextEditingController();
  final _sharedMother = TextEditingController();

  // Person fields
  final _first = TextEditingController();
  final _middle = TextEditingController();
  final _last = TextEditingController();
  final _full = TextEditingController();
  final _birthName = TextEditingController();
  final _nickname = TextEditingController();
  final _pronouns = TextEditingController();
  Gender _gender = Gender.unknown;
  String? _profileMediaId;
  String? _newPhotoPath;

  FuzzyDate? _birth;
  final _birthPlace = TextEditingController();
  final _birthCountry = TextEditingController();
  final _birthNotes = TextEditingController();

  bool _living = true;
  FuzzyDate? _death;
  final _deathPlace = TextEditingController();
  final _cause = TextEditingController();
  final _burial = TextEditingController();
  final _deathNotes = TextEditingController();

  final _occupation = TextEditingController();
  final _education = TextEditingController();
  final _nationality = TextEditingController();
  final _languages = TextEditingController();
  final _bio = TextEditingController();
  final _interests = TextEditingController();
  final _achievements = TextEditingController();
  final _notes = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  bool _private = false;
  final Map<String, TextEditingController> _custom = {};

  bool get _editing => widget.personId != null;

  List<TextEditingController> get _allControllers => [
        _partnerPlace, _sharedFather, _sharedMother, _first, _middle, _last, _full, _birthName, _nickname, _pronouns,
        _birthPlace, _birthCountry, _birthNotes, _deathPlace, _cause, _burial, _deathNotes,
        _occupation, _education, _nationality, _languages, _bio, _interests, _achievements,
        _notes, _email, _phone, _address, ..._custom.values,
      ];

  @override
  void initState() {
    super.initState();
    _relation = RelationKind.parse(widget.relation);
    if (_relation?.gender != null) _gender = _relation!.gender!;
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(familyRepoProvider);
    if (_editing) {
      final p = await repo.person(widget.personId!);
      if (p != null) {
        _first.text = p.firstName;
        _middle.text = p.middleName ?? '';
        _last.text = p.lastName ?? '';
        _full.text = p.fullName ?? '';
        _birthName.text = p.birthName ?? '';
        _nickname.text = p.nickname ?? '';
        _pronouns.text = p.pronouns ?? '';
        _gender = p.gender;
        _profileMediaId = p.profileMediaId;
        _birth = p.birth;
        _birthPlace.text = p.birthPlace ?? '';
        _birthCountry.text = p.birthCountry ?? '';
        _birthNotes.text = p.birthNotes ?? '';
        _living = p.isLiving;
        _death = p.death;
        _deathPlace.text = p.deathPlace ?? '';
        _cause.text = p.causeOfDeath ?? '';
        _burial.text = p.burialPlace ?? '';
        _deathNotes.text = p.deathNotes ?? '';
        _occupation.text = p.occupation ?? '';
        _education.text = p.education ?? '';
        _nationality.text = p.nationality ?? '';
        _languages.text = p.languages ?? '';
        _bio.text = p.biography ?? '';
        _interests.text = p.interests ?? '';
        _achievements.text = p.achievements ?? '';
        _notes.text = p.notes ?? '';
        _email.text = p.email ?? '';
        _phone.text = p.phone ?? '';
        _address.text = p.address ?? '';
        _private = p.isPrivate;
        final values = await repo.watchCustomValues(p.id).first;
        for (final v in values) {
          _customCtl(v.fieldId).text = v.value;
        }
        // Open the extra sections straight away when they already hold data.
        _showMore = [
          _middle, _birthName, _nickname, _full, _pronouns, _birthCountry, _birthNotes,
          _deathPlace, _cause, _burial, _deathNotes, _occupation, _education, _nationality,
          _languages, _bio, _interests, _achievements, _notes, _email, _phone, _address,
          ..._custom.values,
        ].any((c) => c.text.trim().isNotEmpty) || _private;
      }
    } else if (widget.anchorId != null && _relation != null) {
      // Suggest the family name for blood relatives.
      final anchor = await repo.person(widget.anchorId!);
      const inherit = {
        RelationKind.father, RelationKind.son, RelationKind.daughter, RelationKind.child,
        RelationKind.brother, RelationKind.sister, RelationKind.sibling, RelationKind.grandchild,
      };
      if (anchor != null && inherit.contains(_relation) && (anchor.lastName ?? '').isNotEmpty) {
        _last.text = anchor.lastName!;
      }
    }
    for (final c in _allControllers) {
      c.addListener(_markDirty);
    }
    if (mounted) setState(() => _loaded = true);
  }

  void _markDirty() => _dirty = true;

  TextEditingController _customCtl(String fieldId) {
    return _custom.putIfAbsent(fieldId, () => TextEditingController()..addListener(_markDirty));
  }

  @override
  void dispose() {
    for (final c in _allControllers) {
      c.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  String? _t(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  PersonsCompanion _companion(String treeId) => PersonsCompanion(
        treeId: Value(treeId),
        firstName: Value(_first.text.trim()),
        middleName: Value(_t(_middle)),
        lastName: Value(_t(_last)),
        fullName: Value(_t(_full)),
        birthName: Value(_t(_birthName)),
        nickname: Value(_t(_nickname)),
        gender: Value(_gender),
        pronouns: Value(_t(_pronouns)),
        birthDate: Value(_birth?.serialize()),
        birthPlace: Value(_t(_birthPlace)),
        birthCountry: Value(_t(_birthCountry)),
        birthNotes: Value(_t(_birthNotes)),
        isLiving: Value(_living),
        deathDate: Value(_living ? null : _death?.serialize()),
        deathPlace: Value(_living ? null : _t(_deathPlace)),
        causeOfDeath: Value(_living ? null : _t(_cause)),
        burialPlace: Value(_living ? null : _t(_burial)),
        deathNotes: Value(_living ? null : _t(_deathNotes)),
        occupation: Value(_t(_occupation)),
        education: Value(_t(_education)),
        nationality: Value(_t(_nationality)),
        languages: Value(_t(_languages)),
        biography: Value(_t(_bio)),
        interests: Value(_t(_interests)),
        achievements: Value(_t(_achievements)),
        notes: Value(_t(_notes)),
        email: Value(_t(_email)),
        phone: Value(_t(_phone)),
        address: Value(_t(_address)),
        isPrivate: Value(_private),
      );

  RelationPlan? _plan(FamilyGraph g) {
    if (_relation == null || widget.anchorId == null || !g.contains(widget.anchorId!)) return null;
    return RelationPlanner(g).plan(_relation!, widget.anchorId!, choiceId: _choiceId, coParentId: _coParentId);
  }

  static bool _emailOk(String? v) {
    final t = (v ?? '').trim();
    return t.isEmpty || RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(t);
  }

  Future<void> _save() async {
    // A second tap can arrive before the button rebuilds as disabled.
    if (_saving) return;
    final g = ref.read(familyGraphProvider).value ?? FamilyGraph.empty();
    final treeId = ref.read(activeTreeIdProvider);
    if (treeId == null) return;
    final plan = _plan(g);
    if (plan != null) {
      if (plan.isBlocked) {
        _toTop();
        showFTToast(context, plan.blockedReason!, error: true);
        return;
      }
      if (plan.needsChoice && _choiceId == null) {
        _toTop();
        showFTToast(context, plan.choicePrompt ?? 'Please choose an option', error: true);
        return;
      }
    }
    if (_useExisting) {
      if (_existingId == null) {
        showFTToast(context, 'Choose the existing person to connect', error: true);
        return;
      }
    } else if (_first.text.trim().isEmpty && _last.text.trim().isEmpty && _full.text.trim().isEmpty) {
      _toTop();
      _form.currentState?.validate();
      showFTToast(context, 'Please enter at least a first or last name', error: true);
      return;
    }
    if (!_useExisting) {
      // Fields under "More details" only validate while shown, so check the
      // email directly and reveal it if it's wrong.
      if (!_emailOk(_email.text)) {
        setState(() => _showMore = true);
        WidgetsBinding.instance.addPostFrameCallback((_) => _form.currentState?.validate());
        showFTToast(context, 'Please enter a valid email address', error: true);
        return;
      }
      if (!(_form.currentState?.validate() ?? true)) {
        showFTToast(context, 'Please check the highlighted fields', error: true);
        return;
      }
    }
    setState(() => _saving = true);
    final repo = ref.read(familyRepoProvider);
    final db = ref.read(databaseProvider);
    try {
      late String personId;
      await db.transaction(() async {
        if (_useExisting) {
          personId = _existingId!;
        } else if (_editing) {
          personId = widget.personId!;
          await repo.updatePerson(personId, _companion(treeId).copyWith(treeId: const Value.absent()));
        } else {
          personId = await repo.createPerson(_companion(treeId).copyWith(id: Value(newId())));
        }
        if (plan != null) {
          final missing = plan.createParentsFor;
          final sharedFromExisting = _sharedParentLinks(g);
          if (missing != null && sharedFromExisting.isNotEmpty) {
            // The existing relative already has parents: share those.
            for (final l in sharedFromExisting) {
              await repo.addParent(childId: missing, parentId: l.parentId, type: l.type);
            }
          } else if (missing != null) {
            for (final parent in await _createSharedParents(repo, treeId, g, missing)) {
              await repo.addParent(childId: missing, parentId: parent);
              await repo.addParent(childId: personId, parentId: parent);
            }
          }
          final already = _useExisting ? g.parentIds(personId).toSet() : const <String>{};
          for (final (parent, type) in plan.parents) {
            if (already.contains(parent)) continue;
            await repo.addParent(childId: personId, parentId: parent, type: type);
          }
          for (final (child, type) in plan.children) {
            await repo.addParent(childId: child, parentId: personId, type: type);
          }
          for (final partner in plan.partners) {
            await repo.addPartnership(
              a: partner,
              b: personId,
              type: _partnerType,
              status: _partnerStatus,
              start: _partnerStart,
              place: _t(_partnerPlace),
            );
          }
        }
        if (!_useExisting) {
          for (final e in _custom.entries) {
            await repo.setCustomValue(personId, e.key, e.value.text);
          }
        }
      });
      // The person is saved now. Extras below must not fail the save, or a
      // retry would create the same person twice.
      String? warning;
      if (!_useExisting && _newPhotoPath != null) {
        try {
          final mid = await ref.read(contentRepoProvider).importMedia(
                File(_newPhotoPath!),
                treeId: treeId,
                kind: MediaKind.photo,
                personIds: [personId],
              );
          await repo.setProfilePhoto(personId, mid);
        } catch (_) {
          warning = 'Saved, but the photo couldn’t be added. Try adding it again from the profile.';
        }
      }
      // First person in a tree becomes its home person.
      final tree = ref.read(activeTreeProvider);
      if (tree != null && tree.homePersonId == null && !_editing) {
        try {
          await repo.updateTree(tree.id, homePersonId: personId);
        } catch (_) {}
      }
      _dirty = false;
      if (!mounted) return;
      showFTToast(context,
          warning ?? (_editing ? 'Changes saved' : (_useExisting ? 'Relationship added' : 'Family member added')),
          error: warning != null);
      if (_editing || _useExisting) {
        context.pop();
      } else {
        context.pushReplacement(Routes.person(personId));
      }
    } catch (e) {
      // Re-enable Save only on failure; after success the screen is leaving
      // and a late second tap must not save again.
      if (mounted) {
        showFTToast(context, friendlyError(e), error: true);
        setState(() => _saving = false);
      }
    }
  }

  /// When connecting an existing person as a sibling of someone with no
  /// parents, that person's own parents become the shared ones.
  List<ParentChildLink> _sharedParentLinks(FamilyGraph g) {
    if (!_useExisting || _existingId == null) return const [];
    return g.parentLinksOf(_existingId!).where((l) => l.type.isLineage).toList();
  }

  /// Creates the parent(s) shared by [childId] and the new relative. Named
  /// parents are created as typed; with no names a single "Unknown parent"
  /// record is added so the two are still connected.
  Future<List<String>> _createSharedParents(
      FamilyRepository repo, String treeId, FamilyGraph g, String childId) async {
    final family = g[childId]?.lastName;
    PersonsCompanion named(String name, Gender gender) {
      final parts = name.split(RegExp(r'\s+'));
      return PersonsCompanion.insert(
        id: newId(),
        treeId: treeId,
        firstName: Value(parts.first),
        lastName: Value(parts.length > 1 ? parts.sublist(1).join(' ') : family),
        gender: Value(gender),
      );
    }

    final ids = <String>[
      for (final (ctrl, gender) in [(_sharedFather, Gender.male), (_sharedMother, Gender.female)])
        if (ctrl.text.trim().isNotEmpty) await repo.createPerson(named(ctrl.text.trim(), gender)),
    ];
    if (ids.length == 2) await repo.addPartnership(a: ids[0], b: ids[1]);
    if (ids.isEmpty) {
      ids.add(await repo.createPerson(PersonsCompanion.insert(
        id: newId(),
        treeId: treeId,
        firstName: const Value('Unknown parent'),
        notes: const Value('Added to connect siblings. Edit to add their name and details.'),
      )));
    }
    return ids;
  }

  void _toTop() {
    FocusScope.of(context).unfocus();
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: Motion.medium, curve: Motion.curve);
    }
  }

  Future<void> _pickPhoto() async {
    final src = await showFTOptions<ImageSource>(context, title: 'Profile photo', options: const [
      FTOption(ImageSource.camera, 'Take a photo', icon: AppIcons.camera),
      FTOption(ImageSource.gallery, 'Choose from library', icon: AppIcons.photos),
    ]);
    if (src == null) return;
    try {
      final x = await ImagePicker().pickImage(source: src, imageQuality: 92, maxWidth: 3000);
      if (x != null) {
        setState(() {
          _newPhotoPath = x.path;
          _dirty = true;
        });
      }
    } catch (_) {
      if (mounted) showFTToast(context, 'Could not access photos. Check permissions.', error: true);
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return showFTConfirm(
      context,
      title: 'Discard changes?',
      message: 'Your edits to this family member haven’t been saved.',
      confirmLabel: 'Discard',
      destructive: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
    final anchor = widget.anchorId == null ? null : g[widget.anchorId!];
    final connecting = _relation != null && widget.anchorId != null;
    final title = _editing
        ? 'Edit family member'
        : (_relation != null && anchor != null ? 'Add ${_relation!.label.toLowerCase()}' : 'Add family member');
    final pad = context.pagePadding;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) context.pop();
      },
      child: FTPage(
        title: title,
        onBack: () async {
          if (await _confirmDiscard() && context.mounted) context.pop();
        },
        body: !_loaded
            ? const LoadingView()
            : Form(
                key: _form,
                child: Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _scroll,
                        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, Gap.xl),
                        child: ContentWidth(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (connecting) ...[
                                _connectSection(g, anchor),
                                const SizedBox(height: Gap.lg),
                              ],
                              if (!_useExisting) ...[
                                _basicSection(),
                                const SizedBox(height: Gap.lg),
                                _moreToggle(),
                                AnimatedSize(
                                  duration: context.reduceMotion ? Duration.zero : Motion.medium,
                                  curve: Motion.curve,
                                  alignment: Alignment.topCenter,
                                  child: _showMore ? _moreSection() : const SizedBox(width: double.infinity),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(pad, 8, pad, MediaQuery.paddingOf(context).bottom + 12),
                      child: ContentWidth(
                        child: FTButton(
                          label: _editing ? 'Save changes' : (_useExisting ? 'Connect' : 'Save'),
                          icon: AppIcons.check,
                          loading: _saving,
                          expand: true,
                          onTap: _saving ? null : _save,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _gap() => const SizedBox(height: Gap.sm);

  Widget _group(String title, IconData icon, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(top: Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: context.ft.accent),
              const SizedBox(width: 8),
              Text(title, style: context.tx.section),
            ]),
            const SizedBox(height: Gap.sm),
            ...children,
          ],
        ),
      );

  // ---------------------------------------------------------------- connect

  Widget _connectSection(FamilyGraph g, Person? anchor) {
    final plan = _plan(g);
    final c = context.ft;
    if (anchor == null || plan == null) {
      return const EmptyState(icon: AppIcons.warning, title: 'That person is no longer in the tree', compact: true);
    }
    final rel = _relation!;
    final isChild = rel.group == 'Children';
    final isPartner = rel.group == 'Partners';
    // Default co-parent: the anchor's single current partner.
    if (isChild && !_coParentTouched && _coParentId == null) {
      final current = g.partnershipsOf(anchor.id).where((s) => s.status == PartnerStatus.current).toList();
      if (current.length == 1) {
        _coParentId = current.first.personAId == anchor.id ? current.first.personBId : current.first.personAId;
      }
    }
    final exclude = {anchor.id, ...g.parentIds(anchor.id), ...g.childIds(anchor.id), ...g.partnerIds(anchor.id)};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTCard(
          padding: const EdgeInsets.all(14),
          shadow: false,
          child: Row(
            children: [
              PersonAvatarFor(anchor, size: 44, ring: true),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${rel.label} of', style: context.tx.caption),
                    Text(anchor.displayName, style: context.tx.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              const IconBadge(icon: AppIcons.link, accent: true, size: 36),
            ],
          ),
        ),
        if (plan.isBlocked) ...[
          const SizedBox(height: Gap.md),
          FTCard(
            padding: const EdgeInsets.all(16),
            shadow: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  IconBadge(icon: AppIcons.info, size: 36, color: c.warning.withValues(alpha: 0.18)),
                  const SizedBox(width: 12),
                  Expanded(child: Text('One more step first', style: context.tx.bodyStrong)),
                ]),
                const SizedBox(height: 10),
                Text(plan.blockedReason!, style: context.tx.body),
                const SizedBox(height: 14),
                FTButton.secondary(
                  label: 'Add ${(_choiceId != null ? g[_choiceId!] : anchor)?.shortName ?? anchor.shortName}’s parent',
                  icon: AppIcons.personAdd,
                  onTap: () async {
                    if (!await _confirmDiscard() || !mounted) return;
                    _dirty = false;
                    context.pushReplacement(
                        Routes.newPerson(relation: RelationKind.parent.name, anchorId: _choiceId ?? anchor.id));
                  },
                ),
              ],
            ),
          ),
        ],
        if (plan.createParentsFor != null && _sharedParentLinks(g).isEmpty) ...[
          const SizedBox(height: Gap.md),
          FTCard(
            padding: const EdgeInsets.all(16),
            shadow: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  const IconBadge(icon: AppIcons.people, size: 36, accent: true),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Their parents', style: context.tx.bodyStrong)),
                ]),
                const SizedBox(height: 8),
                Text(
                  '${g[plan.createParentsFor!]?.shortName ?? anchor.shortName} has no parents recorded yet. '
                  'They’ll be added too, so both are connected. Names are optional.',
                  style: context.tx.caption,
                ),
                const SizedBox(height: 12),
                FTTextField(
                  controller: _sharedFather,
                  label: 'Father’s name',
                  icon: AppIcons.person,
                  textCapitalization: TextCapitalization.words,
                ),
                _gap(),
                FTTextField(
                  controller: _sharedMother,
                  label: 'Mother’s name',
                  icon: AppIcons.person,
                  textCapitalization: TextCapitalization.words,
                ),
              ],
            ),
          ),
        ],
        if (plan.choices.length > 1) ...[
          const SizedBox(height: Gap.md),
          Text(plan.choicePrompt ?? 'Choose', style: context.tx.section),
          const SizedBox(height: Gap.xs),
          for (final id in plan.choices)
            if (g[id] != null)
              PersonTile(
                person: g[id]!,
                selected: _choiceId == id,
                trailing: Icon(_choiceId == id ? AppIcons.checkCircle : AppIcons.forward,
                    color: _choiceId == id ? c.accent : c.text3, size: 20),
                onTap: () => setState(() {
                  _choiceId = id;
                  _dirty = true;
                }),
              ),
        ],
        if (!plan.isBlocked && !_editing) ...[
          const SizedBox(height: Gap.md),
          FTSegmented<bool>(
            values: const [false, true],
            selected: _useExisting,
            labelOf: (v) => v ? 'Already in tree' : 'New person',
            onChanged: (v) => setState(() {
              _useExisting = v;
              _dirty = true;
            }),
          ),
          if (_useExisting) ...[
            const SizedBox(height: Gap.md),
            FTSelectField(
              label: 'Person',
              icon: AppIcons.person,
              value: _existingId == null ? null : g[_existingId!]?.displayName,
              placeholder: 'Choose from your tree',
              onTap: () async {
                final id = await pickPerson(context, title: 'Choose ${rel.label.toLowerCase()}', exclude: exclude);
                if (id != null) {
                  setState(() {
                    _existingId = id;
                    _dirty = true;
                  });
                }
              },
            ),
          ],
        ],
        if (!plan.isBlocked && isChild && plan.coParentChoices.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          FTSelectField(
            label: 'Other parent',
            icon: AppIcons.people,
            value: _coParentId == null ? null : g[_coParentId!]?.displayName,
            placeholder: 'Unknown / not recorded',
            onTap: () async {
              final picked = await showFTOptions<String>(context, title: 'Other parent', options: [
                for (final id in plan.coParentChoices)
                  if (g[id] != null) FTOption(id, g[id]!.displayName, icon: AppIcons.person),
                const FTOption('', 'Unknown / not recorded', icon: AppIcons.remove),
              ]);
              if (picked == null) return;
              setState(() {
                _dirty = true;
                _coParentTouched = true;
                _coParentId = picked.isEmpty ? null : picked;
              });
            },
          ),
        ],
        if (!plan.isBlocked && isPartner) ...[
          const SizedBox(height: Gap.sm),
          Row(
            children: [
              Expanded(
                child: FTSelectField(
                  label: 'Relationship',
                  icon: AppIcons.heart,
                  value: _partnerType.label,
                  onTap: () async {
                    final t = await showFTOptions<PartnerType>(context, title: 'Relationship', options: [
                      for (final t in PartnerType.values) FTOption(t, t.label),
                    ]);
                    if (t != null) {
                      setState(() {
                        _partnerType = t;
                        _dirty = true;
                      });
                    }
                  },
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: FTSelectField(
                  label: 'Status',
                  value: _partnerStatus.label,
                  onTap: () async {
                    final s = await showFTOptions<PartnerStatus>(context, title: 'Status', options: [
                      for (final s in PartnerStatus.values) FTOption(s, s.label),
                    ]);
                    if (s != null) {
                      setState(() {
                        _partnerStatus = s;
                        _dirty = true;
                      });
                    }
                  },
                ),
              ),
            ],
          ),
          _gap(),
          FuzzyDateField(
            label: _partnerType == PartnerType.marriage ? 'Wedding date' : 'Start date',
            value: _partnerStart,
            onChanged: (d) => setState(() {
              _partnerStart = d;
              _dirty = true;
            }),
          ),
        ],
      ],
    );
  }

  // ------------------------------------------------------------------ basic

  Widget _basicSection() {
    final c = context.ft;
    final existingPhoto = ref.watch(avatarPathProvider(_profileMediaId));
    final narrow = MediaQuery.sizeOf(context).width < 360;
    final photo = Pressable(
      onTap: _pickPhoto,
      semanticLabel: 'Choose profile photo',
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: c.chipGradient,
              border: Border.all(color: c.borderStrong),
            ),
            clipBehavior: Clip.antiAlias,
            child: _newPhotoPath != null
                ? Image.file(File(_newPhotoPath!), fit: BoxFit.cover, cacheWidth: 240)
                : existingPhoto != null
                    ? Image.file(File(existingPhoto), fit: BoxFit.cover, cacheWidth: 240)
                    : Icon(AppIcons.camera, size: 26, color: c.text2),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(shape: BoxShape.circle, gradient: c.accentGradient),
              child: Icon(AppIcons.add, size: 15, color: c.onAccent),
            ),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            photo,
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FTTextField(
                    controller: _first,
                    label: 'First name',
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    autofocus: !_editing && _relation == null,
                    validator: (v) => (v ?? '').trim().isEmpty && _last.text.trim().isEmpty && _full.text.trim().isEmpty
                        ? 'Enter a first or last name'
                        : null,
                  ),
                  _gap(),
                  FTTextField(
                    controller: _last,
                    label: 'Last name',
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.md),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final gg in const [Gender.male, Gender.female, Gender.other])
              FTChip(
                label: gg.label,
                icon: narrow ? null : AppIcons.forGender(gg),
                selected: _gender == gg,
                onTap: () => setState(() {
                  _gender = _gender == gg ? Gender.unknown : gg;
                  _dirty = true;
                }),
              ),
            if (_gender == Gender.nonBinary)
              FTChip(
                label: Gender.nonBinary.label,
                selected: true,
                onTap: () => setState(() => _gender = Gender.unknown),
              ),
          ],
        ),
        const SizedBox(height: Gap.md),
        FuzzyDateField(
          label: 'Date of birth',
          value: _birth,
          icon: AppIcons.baby,
          onChanged: (d) => setState(() {
            _birth = d;
            _dirty = true;
          }),
        ),
        _gap(),
        FTTextField(
          controller: _birthPlace,
          label: 'Birthplace',
          icon: AppIcons.location,
          textCapitalization: TextCapitalization.words,
        ),
        _gap(),
        FTCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          shadow: false,
          child: FTSwitchRow(
            title: _living ? 'Living' : 'Passed away',
            icon: _living ? AppIcons.heart : AppIcons.flower,
            value: _living,
            onChanged: (v) => setState(() {
              _living = v;
              _dirty = true;
            }),
          ),
        ),
        if (!_living) ...[
          _gap(),
          FuzzyDateField(
            label: 'Date of death',
            value: _death,
            icon: AppIcons.flower,
            onChanged: (d) => setState(() {
              _death = d;
              _dirty = true;
            }),
          ),
        ],
      ],
    );
  }

  Widget _moreToggle() {
    final c = context.ft;
    return Pressable(
      onTap: () {
        FocusScope.of(context).unfocus();
        setState(() => _showMore = !_showMore);
      },
      semanticLabel: _showMore ? 'Hide more details' : 'More details',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: c.borderStrong),
        ),
        child: Row(
          children: [
            Icon(_showMore ? AppIcons.remove : AppIcons.add, size: 18, color: c.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_showMore ? 'Hide more details' : 'More details', style: context.tx.bodyStrong),
                  if (!_showMore)
                    Text('Other names, work, life story, contact – all optional', style: context.tx.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _moreSection() {
    final fields = ref.watch(customFieldsProvider).value ?? const <CustomField>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _group('Names', AppIcons.id, [
          FTTextField(controller: _middle, label: 'Middle name', textCapitalization: TextCapitalization.words),
          _gap(),
          FTTextField(controller: _birthName, label: 'Birth name / maiden name', textCapitalization: TextCapitalization.words),
          _gap(),
          FTTextField(controller: _nickname, label: 'Nickname', textCapitalization: TextCapitalization.words),
          _gap(),
          FTTextField(
            controller: _full,
            label: 'Full name as written (optional)',
            textCapitalization: TextCapitalization.words,
          ),
          _gap(),
          FTTextField(controller: _pronouns, label: 'Pronouns', hint: 'e.g. she/her'),
        ]),
        _group('Birth', AppIcons.baby, [
          FTTextField(
            controller: _birthCountry,
            label: 'Country of birth',
            icon: AppIcons.globe,
            textCapitalization: TextCapitalization.words,
          ),
          _gap(),
          FTTextField(controller: _birthNotes, label: 'Birth notes', icon: AppIcons.note, maxLines: 4, minLines: 2),
        ]),
        if (!_living)
          _group('Passing', AppIcons.flower, [
            FTTextField(controller: _deathPlace, label: 'Place of death', icon: AppIcons.location),
            _gap(),
            FTTextField(controller: _cause, label: 'Cause of death', icon: AppIcons.info),
            _gap(),
            FTTextField(controller: _burial, label: 'Burial or memorial location', icon: AppIcons.plant),
            _gap(),
            FTTextField(controller: _deathNotes, label: 'Notes', icon: AppIcons.note, maxLines: 4, minLines: 2),
          ]),
        if (_relation?.group == 'Partners')
          _group('Relationship', AppIcons.heart, [
            FTTextField(controller: _partnerPlace, label: 'Where they married / met', icon: AppIcons.location),
          ]),
        _group('Life & story', AppIcons.story, [
          FTTextField(controller: _occupation, label: 'Occupation', icon: AppIcons.briefcase),
          _gap(),
          FTTextField(controller: _education, label: 'Education', icon: AppIcons.graduation),
          _gap(),
          FTTextField(controller: _nationality, label: 'Nationality', icon: AppIcons.globe),
          _gap(),
          FTTextField(controller: _languages, label: 'Languages', icon: AppIcons.language),
          _gap(),
          FTTextField(controller: _bio, label: 'Life story', icon: AppIcons.story, maxLines: 10, minLines: 3),
          _gap(),
          FTTextField(controller: _interests, label: 'Interests', icon: AppIcons.sparkle, maxLines: 3, minLines: 1),
          _gap(),
          FTTextField(controller: _achievements, label: 'Achievements', icon: AppIcons.trophy, maxLines: 3, minLines: 1),
        ]),
        if (fields.isNotEmpty)
          _group('Custom fields', AppIcons.fields, [
            for (final f in fields) ...[
              FTTextField(
                controller: _customCtl(f.id),
                label: f.name,
                icon: f.isPrivate ? AppIcons.eyeOff : null,
                keyboardType: f.fieldType == CustomFieldType.number ? TextInputType.number : null,
                hint: switch (f.fieldType) {
                  CustomFieldType.date => 'e.g. 12 Mar 1950',
                  CustomFieldType.yesNo => 'Yes or No',
                  _ => null,
                },
              ),
              _gap(),
            ],
          ]),
        _group('Contact & privacy', AppIcons.lock, [
          FTTextField(controller: _phone, label: 'Phone', icon: AppIcons.phone, keyboardType: TextInputType.phone),
          _gap(),
          FTTextField(
            controller: _email,
            label: 'Email',
            icon: AppIcons.mail,
            keyboardType: TextInputType.emailAddress,
            textCapitalization: TextCapitalization.none,
            validator: (v) => _emailOk(v) ? null : 'Enter a valid email',
          ),
          _gap(),
          FTTextField(controller: _address, label: 'Address', icon: AppIcons.house, maxLines: 3, minLines: 1),
          _gap(),
          FTTextField(controller: _notes, label: 'Private notes', icon: AppIcons.note, maxLines: 5, minLines: 2),
          _gap(),
          FTCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            shadow: false,
            child: FTSwitchRow(
              title: 'Keep private',
              subtitle: 'Left out of shared exports',
              icon: AppIcons.eyeOff,
              value: _private,
              onChanged: (v) => setState(() {
                _private = v;
                _dirty = true;
              }),
            ),
          ),
        ]),
      ],
    );
  }
}
