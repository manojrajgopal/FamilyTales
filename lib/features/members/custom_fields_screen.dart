import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/widgets/widgets.dart';
import '../search/text_normalize.dart';

/// Example fields offered to get started.
const customFieldIdeas = <String>[
  'Family nickname',
  'Village',
  'Community tradition',
  'Historical reference',
];

IconData _typeIcon(CustomFieldType t) => switch (t) {
      CustomFieldType.text => AppIcons.textSize,
      CustomFieldType.number => AppIcons.stats,
      CustomFieldType.date => AppIcons.calendar,
      CustomFieldType.yesNo => AppIcons.checkSquare,
    };

bool _nameTaken(Iterable<CustomField> fields, String name, {String? exceptId}) {
  final k = normalizeKey(name);
  return fields.any((f) => f.id != exceptId && normalizeKey(f.name) == k);
}

class CustomFieldsScreen extends ConsumerWidget {
  const CustomFieldsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fieldsAsync = ref.watch(customFieldsProvider);
    return FTPage(
      title: 'Custom fields',
      actions: [
        FTIconButton(
          icon: AppIcons.add,
          tooltip: 'Add custom field',
          onTap: () => _addField(context, ref),
        ),
      ],
      body: fieldsAsync.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(customFieldsProvider)),
        data: (fields) {
          final ideas = customFieldIdeas.where((i) => !_nameTaken(fields, i)).toList();
          final items = <Widget>[
            const _IntroCard(),
            SectionHeader(
              'Fields',
              trailing: fields.isEmpty
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(right: Gap.xs),
                      child: FTTag('${fields.length}', accent: true),
                    ),
              action: 'Add',
              onAction: () => _addField(context, ref),
            ),
            if (fields.isEmpty)
              FTCard(
                child: EmptyState(
                  icon: AppIcons.fields,
                  title: 'No custom fields yet',
                  message: 'Add your first field, or start from one of the ideas below.',
                  compact: true,
                  actionLabel: 'Add a field',
                  onAction: () => _addField(context, ref),
                ),
              )
            else
              for (final f in fields)
                _FieldCard(field: f, onTap: () => _fieldOptions(context, ref, f, fields)),
            if (ideas.isNotEmpty) ...[
              const SectionHeader('Ideas'),
              Wrap(
                spacing: Gap.xs,
                runSpacing: Gap.xs,
                children: [
                  for (final idea in ideas)
                    FTChip(
                      label: idea,
                      icon: AppIcons.add,
                      selected: false,
                      onTap: () => _addField(context, ref, initialName: idea),
                    ),
                ],
              ),
            ],
          ];
          return ListView.builder(
            padding: EdgeInsets.fromLTRB(
                context.pagePadding, Gap.xs, context.pagePadding, FTPage.bottomInset(context)),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final header = items[i] is SectionHeader;
              return ContentWidth(
                child: Padding(
                  padding: EdgeInsets.only(top: header ? Gap.sm : 0, bottom: header ? Gap.xxs : Gap.sm),
                  child: FadeSlideIn(index: i, child: items[i]),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _addField(BuildContext context, WidgetRef ref, {String? initialName}) async {
    final treeId = ref.read(activeTreeIdProvider);
    if (treeId == null) {
      showFTToast(context, 'Create a family tree first.', error: true);
      return;
    }
    final name = await showFTSheet<String>(
      context,
      title: 'New custom field',
      builder: (_) => _FieldForm(treeId: treeId, initialName: initialName),
    );
    if (name != null && context.mounted) showFTToast(context, '“$name” added');
  }

  Future<void> _fieldOptions(
      BuildContext context, WidgetRef ref, CustomField f, List<CustomField> fields) async {
    final choice = await showFTOptions<String>(
      context,
      title: f.name,
      options: [
        const FTOption('rename', 'Rename', icon: AppIcons.edit),
        FTOption(
          'private',
          f.isPrivate ? 'Make public' : 'Make private',
          icon: f.isPrivate ? AppIcons.eye : AppIcons.lock,
          subtitle: f.isPrivate
              ? 'Include this field in public exports'
              : 'Hide this field from public exports',
        ),
        const FTOption('delete', 'Delete field',
            icon: AppIcons.delete, danger: true, subtitle: 'Also removes the values saved on profiles'),
      ],
    );
    if (choice == null || !context.mounted) return;
    final repo = ref.read(familyRepoProvider);
    try {
      switch (choice) {
        case 'rename':
          final name = await showFTTextPrompt(
            context,
            title: 'Rename field',
            label: 'Field name',
            initial: f.name,
          );
          if (name == null || name.trim().isEmpty || name.trim() == f.name || !context.mounted) return;
          if (_nameTaken(fields, name, exceptId: f.id)) {
            showFTToast(context, 'A field called “${name.trim()}” already exists.', error: true);
            return;
          }
          await repo.updateCustomField(f.id, name: name.trim());
          if (context.mounted) showFTToast(context, 'Field renamed');
        case 'private':
          await repo.updateCustomField(f.id, isPrivate: !f.isPrivate);
          if (context.mounted) {
            showFTToast(
              context,
              f.isPrivate ? '“${f.name}” is now included in exports' : '“${f.name}” is now private',
              actionLabel: 'Undo',
              onAction: () => repo.updateCustomField(f.id, isPrivate: f.isPrivate),
            );
          }
        case 'delete':
          final ok = await showFTConfirm(
            context,
            title: 'Delete “${f.name}”?',
            message: 'The field and every value saved for it on people’s profiles will be '
                'permanently removed. This can’t be undone.',
            confirmLabel: 'Delete',
            destructive: true,
          );
          if (!ok) return;
          await repo.deleteCustomField(f.id);
          if (context.mounted) showFTToast(context, '“${f.name}” deleted');
      }
    } catch (e) {
      if (context.mounted) showFTToast(context, friendlyError(e), error: true);
    }
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard();

  @override
  Widget build(BuildContext context) {
    return FTCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const IconBadge(icon: AppIcons.fields, size: 44, accent: true),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Record what matters to your family', style: context.tx.section),
                const SizedBox(height: Gap.xxs),
                Text(
                  'Custom fields appear on every member’s profile in this tree. '
                  'Private fields stay on this device and are left out of public exports.',
                  style: context.tx.caption,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldCard extends StatelessWidget {
  const _FieldCard({required this.field, required this.onTap});
  final CustomField field;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final f = field;
    return FTCard(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, Gap.sm),
      radius: Radii.md,
      child: FTListRow(
        icon: _typeIcon(f.fieldType),
        title: f.name,
        subtitle: f.isPrivate
            ? '${f.fieldType.label} · Private – hidden from public exports'
            : '${f.fieldType.label} · Included in exports',
        onTap: onTap,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (f.isPrivate) ...[
              const FTTag('Private', icon: AppIcons.lock),
              const SizedBox(width: Gap.xxs),
            ],
            FTIconButton(
              icon: AppIcons.moreHoriz,
              tooltip: 'Options for ${f.name}',
              size: 36,
              onTap: onTap,
            ),
          ],
        ),
      ),
    );
  }
}

class _FieldForm extends ConsumerStatefulWidget {
  const _FieldForm({required this.treeId, this.initialName});
  final String treeId;
  final String? initialName;

  @override
  ConsumerState<_FieldForm> createState() => _FieldFormState();
}

class _FieldFormState extends ConsumerState<_FieldForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initialName);
  CustomFieldType _type = CustomFieldType.text;
  bool _private = false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String? _validate(String? v) {
    final name = (v ?? '').trim();
    if (name.isEmpty) return 'Please enter a name';
    if (name.length > 60) return 'Please keep the name under 60 characters';
    final fields = ref.read(customFieldsProvider).value ?? const <CustomField>[];
    if (_nameTaken(fields, name)) return 'A field with this name already exists';
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final name = _name.text.trim();
    try {
      await ref.read(familyRepoProvider).addCustomField(widget.treeId, name, _type, isPrivate: _private);
      if (mounted) Navigator.of(context).pop(name);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showFTToast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final fields = ref.watch(customFieldsProvider).value ?? const <CustomField>[];
    final ideas = customFieldIdeas.where((i) => !_nameTaken(fields, i)).toList();
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FTTextField(
            controller: _name,
            label: 'Field name',
            hint: 'e.g. Village',
            icon: AppIcons.fields,
            autofocus: widget.initialName == null,
            textCapitalization: TextCapitalization.sentences,
            validator: _validate,
            onChanged: (_) => setState(() {}), // keeps the idea chips in sync
          ),
          if (ideas.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Wrap(
              spacing: Gap.xs,
              runSpacing: Gap.xs,
              children: [
                for (final idea in ideas)
                  FTChip(
                    label: idea,
                    selected: _name.text.trim() == idea,
                    onTap: () => setState(() {
                      _name.text = idea;
                      _type = CustomFieldType.text;
                    }),
                  ),
              ],
            ),
          ],
          const SizedBox(height: Gap.lg),
          Text('Type', style: context.tx.label.copyWith(color: c.text2)),
          const SizedBox(height: Gap.xs),
          Wrap(
            spacing: Gap.xs,
            runSpacing: Gap.xs,
            children: [
              for (final t in CustomFieldType.values)
                FTChip(
                  label: t.label,
                  icon: _typeIcon(t),
                  selected: _type == t,
                  onTap: () => setState(() => _type = t),
                ),
            ],
          ),
          const SizedBox(height: Gap.xs),
          Text('The type can’t be changed after the field is created.', style: context.tx.caption),
          const SizedBox(height: Gap.md),
          FTSwitchRow(
            title: 'Private field',
            subtitle: 'Hidden from public exports such as shared PDFs and GEDCOM files.',
            icon: AppIcons.lock,
            value: _private,
            onChanged: (v) => setState(() => _private = v),
          ),
          const SizedBox(height: Gap.xl),
          FTButton(
            label: 'Add field',
            expand: true,
            loading: _saving,
            onTap: _save,
          ),
        ],
      ),
    );
  }
}
