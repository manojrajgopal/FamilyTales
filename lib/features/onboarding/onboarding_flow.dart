import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme/app_theme.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/repositories/family_repository.dart';
import '../../core/widgets/widgets.dart';

/// First-launch experience: Welcome → Introduction → Create tree → About you
/// → First family members → Privacy. Everything is created locally when the
/// user finishes; every optional step can be skipped.
class OnboardingFlow extends ConsumerStatefulWidget {
  const OnboardingFlow({super.key});

  @override
  ConsumerState<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends ConsumerState<OnboardingFlow> {
  final _pages = PageController();
  int _page = 0;
  bool _busy = false;
  static const _count = 6;

  // Collected data
  final _treeName = TextEditingController(text: 'My Family Tree');
  final _treeDesc = TextEditingController();
  final _first = TextEditingController();
  final _last = TextEditingController();
  FuzzyDate? _birth;
  Gender _gender = Gender.unknown;
  String? _photoPath;
  final Map<String, TextEditingController> _relatives = {};
  final List<TextEditingController> _children = [];
  final Set<String> _chosen = {};
  final _treeForm = GlobalKey<FormState>();
  final _meForm = GlobalKey<FormState>();

  @override
  void dispose() {
    _pages.dispose();
    for (final c in [_treeName, _treeDesc, _first, _last, ..._relatives.values, ..._children]) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _rel(String key) => _relatives[key] ??= TextEditingController();

  void _go(int page) {
    FocusScope.of(context).unfocus();
    setState(() => _page = page);
    if (context.reduceMotion) {
      _pages.jumpToPage(page);
    } else {
      _pages.animateToPage(page, duration: Motion.slow, curve: Motion.emphasized);
    }
  }

  void _next() {
    if (_page == 2 && !_treeForm.currentState!.validate()) return;
    if (_page == 3 && !_meForm.currentState!.validate()) return;
    if (_page < _count - 1) {
      _go(_page + 1);
    } else {
      _finish();
    }
  }

  Future<void> _finish() async {
    setState(() => _busy = true);
    final repo = ref.read(familyRepoProvider);
    try {
      // All-or-nothing, so retrying after an error never leaves a second,
      // half-filled tree behind.
      String? meId;
      final treeId = await ref.read(databaseProvider).transaction(() async {
        final treeId = await repo.createTree(
          _treeName.text.trim().isEmpty ? 'My Family Tree' : _treeName.text.trim(),
          description: _treeDesc.text.trim().isEmpty ? null : _treeDesc.text.trim(),
        );
        if (_first.text.trim().isNotEmpty || _last.text.trim().isNotEmpty) {
          meId = await repo.createPerson(
            PersonsCompanion.insert(
              id: newId(),
              treeId: treeId,
              firstName: Value(_first.text.trim()),
              lastName: Value(_last.text.trim().isEmpty ? null : _last.text.trim()),
              gender: Value(_gender),
              birthDate: Value(_birth?.serialize()),
            ),
          );
          await repo.updateTree(treeId, homePersonId: meId);
          await _createRelatives(repo, treeId, meId!);
        }
        return treeId;
      });
      if (meId != null && _photoPath != null) {
        try {
          final mid = await ref
              .read(contentRepoProvider)
              .importMedia(
                File(_photoPath!),
                treeId: treeId,
                kind: MediaKind.photo,
                personIds: [meId!],
                caption: 'Profile photo',
              );
          await repo.setProfilePhoto(meId!, mid);
        } catch (_) {
          if (mounted) showFTToast(context, 'Your tree was created, but the photo couldn’t be added.', error: true);
        }
      }
      await ref.read(settingsProvider.notifier).update((p) => p.copyWith(onboardingDone: true, activeTreeId: treeId));
      if (mounted) context.go(Routes.home);
    } catch (e) {
      if (!mounted) return;
      showFTToast(context, friendlyError(e), error: true);
      setState(() => _busy = false);
    }
  }

  /// Skipping "About you" also skips the relatives page (they'd have no one
  /// to be connected to); skipping either never creates relatives.
  void _skip() {
    setState(_chosen.clear);
    _go(5);
  }

  Future<void> _createRelatives(FamilyRepository repo, String treeId, String meId) async {
    final last = _last.text.trim().isEmpty ? null : _last.text.trim();
    Future<String?> make(String key, Gender g, {String? fallbackLast}) async {
      final name = _relatives[key]?.text.trim() ?? '';
      if (!_chosenKey(key) || name.isEmpty) return null;
      final parts = name.split(RegExp(r'\s+'));
      final first = parts.first;
      final rest = parts.length > 1 ? parts.sublist(1).join(' ') : fallbackLast;
      return repo.createPerson(
        PersonsCompanion.insert(
          id: newId(),
          treeId: treeId,
          firstName: Value(first),
          lastName: Value(rest),
          gender: Value(g),
        ),
      );
    }

    final father = await make('father', Gender.male, fallbackLast: last);
    final mother = await make('mother', Gender.female);
    final spouse = await make('spouse', Gender.unknown);
    if (father != null) await repo.addParent(childId: meId, parentId: father);
    if (mother != null) await repo.addParent(childId: meId, parentId: mother);
    if (father != null && mother != null) await repo.addPartnership(a: father, b: mother);
    if (spouse != null) await repo.addPartnership(a: meId, b: spouse);
    if (_chosen.contains('children')) {
      for (final c in _children) {
        final n = c.text.trim();
        if (n.isEmpty) continue;
        final parts = n.split(RegExp(r'\s+'));
        final kid = await repo.createPerson(
          PersonsCompanion.insert(
            id: newId(),
            treeId: treeId,
            firstName: Value(parts.first),
            lastName: Value(parts.length > 1 ? parts.sublist(1).join(' ') : last),
          ),
        );
        await repo.addParent(childId: kid, parentId: meId);
        if (spouse != null) await repo.addParent(childId: kid, parentId: spouse);
      }
    }
    if (_chosen.contains('grandparents')) {
      Future<void> gp(String key, Gender g, String? parentId) async {
        if (parentId == null) return;
        final id = await make(key, g);
        if (id != null) await repo.addParent(childId: parentId, parentId: id);
      }

      await gp('pgf', Gender.male, father);
      await gp('pgm', Gender.female, father);
      await gp('mgf', Gender.male, mother);
      await gp('mgm', Gender.female, mother);
    }
  }

  bool _chosenKey(String key) {
    if (['pgf', 'pgm', 'mgf', 'mgm'].contains(key)) return _chosen.contains('grandparents');
    return _chosen.contains(key);
  }

  Future<void> _pickPhoto() async {
    final src = await showFTOptions<ImageSource>(
      context,
      title: 'Profile photo',
      options: const [
        FTOption(ImageSource.camera, 'Take a photo', icon: AppIcons.camera),
        FTOption(ImageSource.gallery, 'Choose from library', icon: AppIcons.photos),
      ],
    );
    if (src == null) return;
    try {
      final x = await ImagePicker().pickImage(source: src, imageQuality: 92, maxWidth: 2000);
      if (x != null) setState(() => _photoPath = x.path);
    } catch (_) {
      if (mounted) showFTToast(context, 'Could not access photos. Check permissions in system settings.', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final pad = context.pagePadding;
    final labels = ['Get started', 'Continue', 'Continue', 'Continue', 'Continue', 'Create my family tree'];
    // System back steps back through onboarding instead of closing the app.
    return PopScope(
      canPop: _page == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _page > 0 && !_busy) _go(_page - 1);
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.overlayStyle(c.isDark),
        child: Scaffold(
          backgroundColor: c.bg0,
          body: Stack(
            children: [
              const Positioned.fill(child: FTBackground()),
              SafeArea(
                child: Column(
                  children: [
                    SizedBox(
                      height: 64,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: pad - 4),
                        child: Row(
                          children: [
                            AnimatedOpacity(
                              opacity: _page > 0 ? 1 : 0,
                              duration: Motion.fast,
                              child: IgnorePointer(
                                ignoring: _page == 0,
                                child: FTIconButton(icon: AppIcons.back, tooltip: 'Back', onTap: () => _go(_page - 1)),
                              ),
                            ),
                            const Spacer(),
                            _Dots(count: _count, index: _page),
                            const Spacer(),
                            AnimatedOpacity(
                              opacity: _page >= 3 && _page < 5 ? 1 : 0,
                              duration: Motion.fast,
                              child: IgnorePointer(
                                ignoring: !(_page >= 3 && _page < 5),
                                child: FTTextAction('Skip', onTap: _skip),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: PageView(
                        controller: _pages,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          const _WelcomePage(),
                          const _IntroPage(),
                          _CreateTreePage(formKey: _treeForm, name: _treeName, desc: _treeDesc),
                          _AboutYouPage(
                            formKey: _meForm,
                            first: _first,
                            last: _last,
                            birth: _birth,
                            gender: _gender,
                            photoPath: _photoPath,
                            onBirth: (d) => setState(() => _birth = d),
                            onGender: (g) => setState(() => _gender = g),
                            onPhoto: _pickPhoto,
                            onRemovePhoto: () => setState(() => _photoPath = null),
                          ),
                          _FirstMembersPage(
                            chosen: _chosen,
                            controllerFor: _rel,
                            children: _children,
                            onToggle: (k) => setState(() {
                              if (!_chosen.remove(k)) {
                                _chosen.add(k);
                                if (k == 'children' && _children.isEmpty) _children.add(TextEditingController());
                              }
                            }),
                            onAddChild: () => setState(() => _children.add(TextEditingController())),
                            onLater: _skip,
                          ),
                          const _PrivacyPage(),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 18, top: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FTRingButton(
                            onTap: _busy ? null : _next,
                            progress: (_page + 1) / _count,
                            semanticLabel: labels[_page],
                            icon: _page == _count - 1 ? Icons.check_rounded : Icons.arrow_forward_rounded,
                          ),
                          const SizedBox(height: 8),
                          AnimatedSwitcher(
                            duration: Motion.fast,
                            child: _busy
                                ? Text(
                                    'Creating your family tree…',
                                    key: const ValueKey('b'),
                                    style: context.tx.caption,
                                  )
                                : Text(labels[_page], key: ValueKey(_page), style: context.tx.caption),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});
  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Semantics(
      label: 'Step ${index + 1} of $count',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: Motion.medium,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == index ? 22 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == index ? c.accent : c.text.withValues(alpha: i < index ? 0.4 : 0.15),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shared scrolling body for onboarding pages (keyboard-safe, centred on
/// tablets).
class _OnbPage extends StatelessWidget {
  const _OnbPage({required this.children, this.center = false});
  final List<Widget> children;
  final bool center;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, cons) {
        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: context.pagePadding + 4, vertical: 8),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: center ? cons.maxHeight - 16 : 0),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisAlignment: center ? MainAxisAlignment.center : MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------------ welcome

class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, cons) {
        final heroH = math.min(cons.maxHeight * 0.52, 420.0);
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: cons.maxHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(height: heroH, child: const _GenerationsHero()),
                const SizedBox(height: 8),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: context.pagePadding + 8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Column(
                      children: [
                        FadeSlideIn(
                          index: 2,
                          child: Text(
                            'Your family. Your story.\nYour roots.',
                            textAlign: TextAlign.center,
                            style: context.tx.display,
                          ),
                        ),
                        const SizedBox(height: 14),
                        FadeSlideIn(
                          index: 3,
                          child: Text(
                            'Preserve your family’s history, connect generations, and keep your memories alive in one beautiful place.',
                            textAlign: TextAlign.center,
                            style: context.tx.body,
                          ),
                        ),
                      ],
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

/// Layered, slightly rotated generation cards over a large circle and a
/// floor shadow – the reference's hero composition, told as a family story.
class _GenerationsHero extends StatelessWidget {
  const _GenerationsHero();

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return LayoutBuilder(
      builder: (context, cons) {
        final w = math.min(cons.maxWidth, 460.0);
        final h = cons.maxHeight;
        final cardW = w * 0.62;
        return Center(
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Backdrop circle
                Positioned(
                  right: w * 0.04,
                  top: h * 0.02,
                  child: Container(
                    width: w * 0.62,
                    height: w * 0.62,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        center: const Alignment(-0.3, -0.4),
                        colors: c.isDark
                            ? [const Color(0xFF3A3B40), const Color(0xFF1B1C20)]
                            : [Colors.white, const Color(0xFFE3E5E8)],
                      ),
                    ),
                  ),
                ),
                // Floor shadow: a soft blurred ellipse beneath the cards.
                Positioned(
                  left: w * 0.14,
                  right: w * 0.14,
                  bottom: h * 0.03,
                  child: Container(
                    height: 14,
                    decoration: ShapeDecoration(
                      shape: const OvalBorder(),
                      color: Colors.black.withValues(alpha: c.isDark ? 0.55 : 0.10),
                      shadows: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: c.isDark ? 0.7 : 0.15),
                          blurRadius: 18,
                          spreadRadius: 6,
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: w * 0.05,
                  top: h * 0.14,
                  child: FadeSlideIn(
                    index: 0,
                    child: Transform.rotate(
                      angle: -0.07,
                      child: _HeroCard(
                        width: cardW,
                        // Illustration only: generic labels, no example people.
                        year: 'Your ancestors',
                        title: 'Where it began',
                        subtitle: 'The first generation',
                        people: const [('Grand Father', null), ('Grand Mother', null)],
                        total: 2,
                        progressLabel: 'Generation 1',
                        progress: 0.25,
                        icon: AppIcons.leaf,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: w * 0.03,
                  top: h * 0.34,
                  child: FadeSlideIn(
                    index: 1,
                    child: Transform.rotate(
                      angle: 0.045,
                      child: _HeroCard(
                        width: cardW,
                        year: 'Every generation',
                        title: 'Your family',
                        subtitle: 'Stories, photos & roots',
                        people: const [
                          ('Father', null),
                          ('Mother', null),
                          ('Son', null),
                          ('Daughter', null),
                        ],
                        total: 4,
                        progressLabel: 'Family history',
                        progress: 0.7,
                        icon: AppIcons.family,
                        accent: true,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: w * 0.5 - 30,
                  top: 0,
                  child: Image.asset('assets/branding/emblem.png', width: 60, height: 60),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.width,
    required this.year,
    required this.title,
    required this.subtitle,
    required this.people,
    required this.total,
    required this.progressLabel,
    required this.progress,
    required this.icon,
    this.accent = false,
  });

  final double width;
  final String year;
  final String title;
  final String subtitle;
  final List<(String, String?)> people;
  final int total;
  final String progressLabel;
  final double progress;
  final IconData icon;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return ExcludeSemantics(
      child: FTCard(
        width: width,
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconBadge(icon: icon, size: 32),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          year,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textScaler: TextScaler.noScaling,
                          style: context.tx.micro,
                        ),
                      ),
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(shape: BoxShape.circle, gradient: c.accentGradient),
                        child: Icon(AppIcons.arrowUpRight, size: 15, color: c.onAccent),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    textScaler: TextScaler.noScaling,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.tx.bodyStrong.copyWith(fontSize: 15),
                  ),
                  Text(
                    subtitle,
                    textScaler: TextScaler.noScaling,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.tx.caption,
                  ),
                  const SizedBox(height: 10),
                  AvatarStack(people: people, total: total, size: 26),
                ],
              ),
            ),
            MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
              child: StripedProgress(value: progress, label: progressLabel, height: 30),
            ),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------- intro

class _IntroPage extends StatelessWidget {
  const _IntroPage();

  @override
  Widget build(BuildContext context) {
    final items = [
      (
        AppIcons.tree,
        'An interactive family tree',
        'Zoom, pan and explore every generation – parents, partners, children, cousins and more.',
      ),
      (
        AppIcons.story,
        'Stories, photos & events',
        'Keep the memories behind the names: albums, timelines, birthdays and family stories.',
      ),
      (
        AppIcons.path,
        'Know how you’re related',
        'Find the relationship between any two people, from second cousins to in-laws.',
      ),
      (
        AppIcons.shield,
        'Private by design',
        'Works completely offline. No account, no cloud – your history stays on this device.',
      ),
    ];
    return _OnbPage(
      center: true,
      children: [
        Text('Everything your family is,\nin one place', style: context.tx.headline),
        const SizedBox(height: Gap.xl),
        for (var i = 0; i < items.length; i++)
          FadeSlideIn(
            index: i,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FTCard(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IconBadge(icon: items[i].$1, accent: i == 0, size: 44),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(items[i].$2, style: context.tx.bodyStrong),
                          const SizedBox(height: 4),
                          Text(items[i].$3, style: context.tx.caption.copyWith(fontSize: 12.5)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// --------------------------------------------------------------- create tree

class _CreateTreePage extends StatelessWidget {
  const _CreateTreePage({required this.formKey, required this.name, required this.desc});
  final GlobalKey<FormState> formKey;
  final TextEditingController name;
  final TextEditingController desc;

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: _OnbPage(
        children: [
          const SizedBox(height: Gap.md),
          const Center(child: IconBadge(icon: AppIcons.tree, accent: true, size: 72)),
          const SizedBox(height: Gap.xl),
          Text('Create your family tree', style: context.tx.headline, textAlign: TextAlign.center),
          const SizedBox(height: Gap.xs),
          Text(
            'Give it a name – you can create more trees later, for example one for each side of the family.',
            style: context.tx.body,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Gap.xl),
          FTTextField(
            controller: name,
            label: 'Family tree name',
            hint: 'My Family Tree',
            icon: AppIcons.tree,
            textCapitalization: TextCapitalization.words,
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Please name your family tree' : null,
            maxLength: 120,
          ),
          const SizedBox(height: Gap.sm),
          FTTextField(
            controller: desc,
            label: 'Description (optional)',
            hint: 'e.g. The Sharma family',
            icon: AppIcons.note,
            maxLines: 3,
            minLines: 1,
          ),
          const SizedBox(height: Gap.sm),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: name,
            builder: (context, v, _) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in ['My Family Tree', 'Father’s family', 'Mother’s family', 'Our family history'])
                  FTChip(label: s, selected: v.text == s, onTap: () => name.text = s),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- about you

class _AboutYouPage extends StatelessWidget {
  const _AboutYouPage({
    required this.formKey,
    required this.first,
    required this.last,
    required this.birth,
    required this.gender,
    required this.photoPath,
    required this.onBirth,
    required this.onGender,
    required this.onPhoto,
    required this.onRemovePhoto,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController first;
  final TextEditingController last;
  final FuzzyDate? birth;
  final Gender gender;
  final String? photoPath;
  final ValueChanged<FuzzyDate?> onBirth;
  final ValueChanged<Gender> onGender;
  final VoidCallback onPhoto;
  final VoidCallback onRemovePhoto;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return Form(
      key: formKey,
      child: _OnbPage(
        children: [
          Text('Start with you', style: context.tx.headline, textAlign: TextAlign.center),
          const SizedBox(height: Gap.xs),
          Text(
            'You’ll be the centre of your tree. Only your name is needed.',
            style: context.tx.body,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Gap.xl),
          Center(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Pressable(
                  onTap: onPhoto,
                  semanticLabel: 'Choose profile photo',
                  child: Container(
                    width: 112,
                    height: 112,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: c.chipGradient,
                      boxShadow: c.cardShadow,
                      border: Border.all(color: c.borderStrong),
                    ),
                    child: photoPath == null
                        ? Icon(AppIcons.camera, size: 34, color: c.text2)
                        : ClipOval(child: Image.file(File(photoPath!), fit: BoxFit.cover, cacheWidth: 300)),
                  ),
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: photoPath == null
                      ? IgnorePointer(
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(shape: BoxShape.circle, gradient: c.accentGradient),
                            child: Icon(AppIcons.add, size: 18, color: c.onAccent),
                          ),
                        )
                      : FTIconButton(icon: AppIcons.close, tooltip: 'Remove photo', size: 36, onTap: onRemovePhoto),
                ),
              ],
            ),
          ),
          const SizedBox(height: Gap.sm),
          Center(child: Text('Profile photo (optional)', style: context.tx.caption)),
          const SizedBox(height: Gap.xl),
          FTTextField(
            controller: first,
            label: 'First name',
            icon: AppIcons.person,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            validator: (v) => (v == null || v.trim().isEmpty) && last.text.trim().isEmpty
                ? 'Please enter your name (or skip this step)'
                : null,
          ),
          const SizedBox(height: Gap.sm),
          FTTextField(
            controller: last,
            label: 'Last name',
            icon: AppIcons.id,
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: Gap.sm),
          FuzzyDateField(label: 'Birth date (optional)', value: birth, onChanged: onBirth),
          const SizedBox(height: Gap.lg),
          Text('Gender (optional)', style: context.tx.caption),
          const SizedBox(height: Gap.xs),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final g in Gender.values) FTChip(label: g.label, selected: gender == g, onTap: () => onGender(g)),
            ],
          ),
          const SizedBox(height: Gap.xl),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- first members

class _FirstMembersPage extends StatelessWidget {
  const _FirstMembersPage({
    required this.chosen,
    required this.controllerFor,
    required this.children,
    required this.onToggle,
    required this.onAddChild,
    required this.onLater,
  });

  final Set<String> chosen;
  final TextEditingController Function(String) controllerFor;
  final List<TextEditingController> children;
  final ValueChanged<String> onToggle;
  final VoidCallback onAddChild;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    final options = [
      ('father', 'Add father', AppIcons.male),
      ('mother', 'Add mother', AppIcons.female),
      ('spouse', 'Add spouse', AppIcons.heart),
      ('children', 'Add children', AppIcons.baby),
      ('grandparents', 'Add grandparents', AppIcons.leaf),
    ];
    Widget field(String key, String label) => Padding(
      padding: const EdgeInsets.only(top: Gap.sm),
      child: FTTextField(
        controller: controllerFor(key),
        label: label,
        hint: 'Full name',
        textCapitalization: TextCapitalization.words,
      ),
    );
    return _OnbPage(
      children: [
        Text('Add your first family members', style: context.tx.headline, textAlign: TextAlign.center),
        const SizedBox(height: Gap.xs),
        Text(
          'Choose who to add now. Everything is optional – you can add more people at any time.',
          style: context.tx.body,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Gap.xl),
        LayoutBuilder(
          builder: (context, cons) {
            final cols = cons.maxWidth > 480 ? 3 : 2;
            final w = (cons.maxWidth - (cols - 1) * 10) / cols;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final o in options)
                  SizedBox(
                    width: w,
                    child: FTCard(
                      padding: const EdgeInsets.all(14),
                      highlighted: chosen.contains(o.$1),
                      shadow: false,
                      onTap: () => onToggle(o.$1),
                      semanticLabel: o.$2,
                      child: Row(
                        children: [
                          IconBadge(icon: o.$3, size: 36, accent: chosen.contains(o.$1)),
                          const SizedBox(width: 10),
                          Expanded(child: Text(o.$2, style: context.tx.label, maxLines: 2)),
                        ],
                      ),
                    ),
                  ),
                SizedBox(
                  width: w,
                  child: FTCard(
                    padding: const EdgeInsets.all(14),
                    shadow: false,
                    onTap: onLater,
                    semanticLabel: 'Add later',
                    child: Row(
                      children: [
                        const IconBadge(icon: AppIcons.clock, size: 36),
                        const SizedBox(width: 10),
                        Expanded(child: Text('Add later', style: context.tx.label)),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        if (chosen.contains('father')) field('father', 'Father’s name'),
        if (chosen.contains('mother')) field('mother', 'Mother’s name'),
        if (chosen.contains('spouse')) field('spouse', 'Spouse’s name'),
        if (chosen.contains('children')) ...[
          for (var i = 0; i < children.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: FTTextField(
                controller: children[i],
                label: 'Child ${i + 1}',
                hint: 'Full name',
                textCapitalization: TextCapitalization.words,
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: FTTextAction('+ Add another child', accent: true, onTap: onAddChild),
          ),
        ],
        if (chosen.contains('grandparents')) ...[
          Padding(
            padding: const EdgeInsets.only(top: Gap.md),
            child: Text(
              chosen.contains('father') || chosen.contains('mother')
                  ? 'Grandparents are linked to the parents you add above.'
                  : 'Add a father or mother first to connect grandparents.',
              style: context.tx.caption,
            ),
          ),
          if (chosen.contains('father')) ...[
            field('pgf', 'Paternal grandfather'),
            field('pgm', 'Paternal grandmother'),
          ],
          if (chosen.contains('mother')) ...[
            field('mgf', 'Maternal grandfather'),
            field('mgm', 'Maternal grandmother'),
          ],
        ],
        const SizedBox(height: Gap.xl),
      ],
    );
  }
}

// ------------------------------------------------------------------- privacy

class _PrivacyPage extends StatelessWidget {
  const _PrivacyPage();

  @override
  Widget build(BuildContext context) {
    final points = [
      (AppIcons.person, 'No account required'),
      (AppIcons.database, 'No online database'),
      (AppIcons.backup, 'No automatic cloud uploads'),
      (AppIcons.storage, 'No server-side storage'),
      (AppIcons.key, 'You control your data'),
      (AppIcons.archive, 'Manual backup and restore'),
    ];
    return _OnbPage(
      children: [
        const SizedBox(height: Gap.sm),
        const Center(child: IconBadge(icon: AppIcons.shield, accent: true, size: 72)),
        const SizedBox(height: Gap.xl),
        Text('Your family data stays on your device.', style: context.tx.headline, textAlign: TextAlign.center),
        const SizedBox(height: Gap.xs),
        Text(
          'Family Tales works completely offline. Your tree is stored in an encrypted database on this device, '
          'and it only leaves when you choose to export or share it.',
          style: context.tx.body,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Gap.xl),
        FTCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              for (var i = 0; i < points.length; i++) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      IconBadge(icon: points[i].$1, size: 36),
                      const SizedBox(width: 12),
                      Expanded(child: Text(points[i].$2, style: context.tx.bodyStrong)),
                      Icon(AppIcons.checkCircle, color: context.ft.accent, size: 20),
                    ],
                  ),
                ),
                if (i < points.length - 1) const HairLine(vertical: 0),
              ],
            ],
          ),
        ),
        const SizedBox(height: Gap.xl),
      ],
    );
  }
}
