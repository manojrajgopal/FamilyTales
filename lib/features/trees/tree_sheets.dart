import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/database/app_database.dart';
import '../../core/widgets/widgets.dart';
import '../settings/widgets/settings_widgets.dart';
import 'tree_logic.dart';

/// Name + description entered in [showTreeFormSheet].
typedef TreeFormResult = ({String name, String? description});

/// Create / edit form for a family tree.
Future<TreeFormResult?> showTreeFormSheet(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String? initialName,
  String? initialDescription,
}) {
  return showFTSheet<TreeFormResult>(
    context,
    title: title,
    builder: (_) => _TreeForm(
      initialName: initialName,
      initialDescription: initialDescription,
      confirmLabel: confirmLabel,
    ),
  );
}

class _TreeForm extends StatefulWidget {
  const _TreeForm({this.initialName, this.initialDescription, required this.confirmLabel});
  final String? initialName;
  final String? initialDescription;
  final String confirmLabel;

  @override
  State<_TreeForm> createState() => _TreeFormState();
}

class _TreeFormState extends State<_TreeForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initialName);
  late final _desc = TextEditingController(text: widget.initialDescription);

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    final d = _desc.text.trim();
    Navigator.of(context).pop<TreeFormResult>(
      (name: _name.text.trim(), description: d.isEmpty ? null : d),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FTTextField(
            controller: _name,
            label: 'Tree name',
            hint: 'e.g. The Almeida family',
            icon: AppIcons.tree,
            autofocus: widget.initialName == null,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            maxLength: TreeActions.maxNameLength,
            validator: (v) {
              final n = v?.trim() ?? '';
              if (n.isEmpty) return 'Please give the tree a name';
              if (n.length > TreeActions.maxNameLength) {
                return 'Keep the name under ${TreeActions.maxNameLength} characters';
              }
              return null;
            },
          ),
          const SizedBox(height: Gap.sm),
          FTTextField(
            controller: _desc,
            label: 'Description (optional)',
            hint: 'Whose family is this? Which branch or region?',
            icon: AppIcons.note,
            minLines: 2,
            maxLines: 4,
            textInputAction: TextInputAction.newline,
          ),
          const SizedBox(height: Gap.lg),
          FTButton(label: widget.confirmLabel, expand: true, onTap: _submit),
        ],
      ),
    );
  }
}

/// Source and target chosen in [showMergeTreesSheet].
typedef MergeChoice = ({String sourceId, String targetId});

/// Lets the user choose which tree to merge into which, previews what will
/// move and explains the consequences. Returns the choice; the caller still
/// asks for a final destructive confirmation.
Future<MergeChoice?> showMergeTreesSheet(
  BuildContext context, {
  String? initialSourceId,
  String? initialTargetId,
  VoidCallback? onBackupFirst,
}) {
  return showFTSheet<MergeChoice>(
    context,
    title: 'Merge family trees',
    builder: (_) => _MergeSheet(
      initialSourceId: initialSourceId,
      initialTargetId: initialTargetId,
      onBackupFirst: onBackupFirst,
    ),
  );
}

class _MergeSheet extends ConsumerStatefulWidget {
  const _MergeSheet({this.initialSourceId, this.initialTargetId, this.onBackupFirst});
  final String? initialSourceId;
  final String? initialTargetId;
  final VoidCallback? onBackupFirst;

  @override
  ConsumerState<_MergeSheet> createState() => _MergeSheetState();
}

class _MergeSheetState extends ConsumerState<_MergeSheet> {
  String? _source;
  String? _target;

  @override
  void initState() {
    super.initState();
    _source = widget.initialSourceId;
    _target = widget.initialTargetId;
  }

  Future<void> _choose({required bool source, required List<FamilyTree> trees}) async {
    final other = source ? _target : _source;
    final stats = ref.read(treeStatsProvider).value ?? const {};
    final id = await showFTOptions<String>(
      context,
      title: source ? 'Move everything from…' : 'Into…',
      options: [
        for (final t in trees)
          if (t.id != other)
            FTOption(
              t.id,
              t.name,
              icon: AppIcons.tree,
              subtitle: plural(stats[t.id]?.people ?? 0, 'person', 'people'),
              selected: t.id == (source ? _source : _target),
            ),
      ],
    );
    if (id == null || !mounted) return;
    setState(() {
      if (source) {
        _source = id;
      } else {
        _target = id;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final trees = ref.watch(treesProvider).value ?? const <FamilyTree>[];
    final stats = ref.watch(treeStatsProvider).value ?? const <String, TreeStats>{};
    FamilyTree? byId(String? id) {
      for (final t in trees) {
        if (t.id == id) return t;
      }
      return null;
    }

    final source = byId(_source);
    final target = byId(_target);
    final s = source == null ? null : (stats[source.id] ?? TreeStats.empty);
    final ready = source != null && target != null && source.id != target.id;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Combine two trees into one – for example after importing a relative’s GEDCOM file.',
          style: context.tx.body,
        ),
        const SizedBox(height: Gap.lg),
        FTSelectField(
          label: 'Move everything from',
          value: source?.name,
          placeholder: 'Choose a tree',
          icon: AppIcons.tree,
          onTap: () => _choose(source: true, trees: trees),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Center(child: Icon(AppIcons.arrowDown, size: 20, color: c.text3)),
        ),
        FTSelectField(
          label: 'Into',
          value: target?.name,
          placeholder: 'Choose a tree',
          icon: AppIcons.tree,
          onTap: () => _choose(source: false, trees: trees),
        ),
        if (ready && s != null) ...[
          const SizedBox(height: Gap.lg),
          Text('What will move', style: context.tx.section),
          const SizedBox(height: Gap.xs),
          Wrap(
            spacing: Gap.xs,
            runSpacing: Gap.xs,
            children: [
              FTTag(plural(s.people, 'person', 'people'), icon: AppIcons.people, accent: true),
              FTTag(plural(s.events, 'event'), icon: AppIcons.event),
              FTTag(plural(s.photos, 'photo'), icon: AppIcons.photo),
              if (s.documents > 0) FTTag(plural(s.documents, 'document'), icon: AppIcons.document),
              if (s.stories > 0) FTTag(plural(s.stories, 'story', 'stories'), icon: AppIcons.story),
              if (s.sources > 0) FTTag(plural(s.sources, 'source'), icon: AppIcons.source),
            ],
          ),
          const SizedBox(height: Gap.xs),
          Text(
            'Relationships, albums, branches, tags, custom fields and reminders move too. '
            '“${source.name}” is removed once it’s empty.',
            style: context.tx.caption,
          ),
        ],
        const SizedBox(height: Gap.lg),
        Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: c.warning.withValues(alpha: c.isDark ? 0.08 : 0.10),
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: c.warning.withValues(alpha: 0.25)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(AppIcons.info, size: 20, color: c.warning),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  'People are not merged automatically. If someone appears in both trees '
                  'they will be listed twice – use “Find duplicates” afterwards to combine them. '
                  'A merge can’t be undone, so consider a backup first.',
                  style: context.tx.body.copyWith(color: c.text),
                ),
              ),
            ],
          ),
        ),
        if (widget.onBackupFirst != null)
          Align(
            alignment: Alignment.centerLeft,
            child: FTTextAction(
              'Create a backup first',
              accent: true,
              onTap: () {
                Navigator.of(context).pop();
                widget.onBackupFirst!();
              },
            ),
          ),
        const SizedBox(height: Gap.md),
        FTButton(
          label: 'Review merge',
          icon: AppIcons.merge,
          kind: FTButtonKind.danger,
          expand: true,
          onTap: ready
              ? () => Navigator.of(context)
                  .pop<MergeChoice>((sourceId: source.id, targetId: target.id))
              : null,
        ),
      ],
    );
  }
}
