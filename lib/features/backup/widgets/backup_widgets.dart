import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/services/app_paths.dart';
import '../../../core/widgets/widgets.dart';
import '../backup_crypto.dart';
import '../backup_format.dart';
import '../isolate_task.dart';
import 'file_actions.dart';

class _Outcome<T> {
  const _Outcome.ok(this.value)
      : error = null,
        stack = null;
  const _Outcome.err(this.error, this.stack) : value = null;
  final T? value;
  final Object? error;
  final StackTrace? stack;
}

/// Runs [task] while showing a non-dismissible sheet with a striped progress
/// bar. Returns the task's result or rethrows its error.
Future<T> runWithProgressSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  IconData icon = AppIcons.archive,
  required Future<T> Function(ProgressCallback progress) task,
}) async {
  final outcome = await showFTSheet<_Outcome<T>>(
    context,
    isDismissible: false,
    builder: (_) => _ProgressSheet<T>(title: title, subtitle: subtitle, icon: icon, task: task),
  );
  if (outcome == null) throw BackupException('The operation was interrupted.');
  if (outcome.error != null) Error.throwWithStackTrace(outcome.error!, outcome.stack!);
  return outcome.value as T;
}

class _ProgressSheet<T> extends StatefulWidget {
  const _ProgressSheet({required this.title, required this.subtitle, required this.icon, required this.task});
  final String title;
  final String? subtitle;
  final IconData icon;
  final Future<T> Function(ProgressCallback progress) task;

  @override
  State<_ProgressSheet<T>> createState() => _ProgressSheetState<T>();
}

class _ProgressSheetState<T> extends State<_ProgressSheet<T>> {
  final _progress = ValueNotifier<(double, String)>((0, 'Starting…'));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    _Outcome<T> out;
    try {
      final v = await widget.task((f, m) {
        if (mounted) _progress.value = (f, m);
      });
      out = _Outcome.ok(v);
    } catch (e, s) {
      out = _Outcome.err(e, s);
    }
    if (mounted) Navigator.of(context).pop(out);
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return PopScope(
      canPop: false,
      child: Padding(
        padding: const EdgeInsets.only(top: Gap.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconBadge(icon: widget.icon, size: 48, accent: true),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.title, style: context.tx.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                      if (widget.subtitle != null)
                        Text(widget.subtitle!, style: context.tx.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.xl),
            ValueListenableBuilder<(double, String)>(
              valueListenable: _progress,
              builder: (context, v, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StripedProgress(value: v.$1, label: 'Progress'),
                  const SizedBox(height: Gap.xs),
                  Text(v.$2, style: context.tx.body, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(height: Gap.md),
            Row(
              children: [
                Icon(AppIcons.info, size: 16, color: c.text3),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text('Keep Family Tales open until this finishes.', style: context.tx.caption),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Card listing every problem of a failed backup / import.
class ErrorReportCard extends StatelessWidget {
  const ErrorReportCard({super.key, required this.title, required this.message, this.details = const [], this.actions = const []});

  final String title;
  final String message;
  final List<String> details;
  final List<Widget> actions;

  factory ErrorReportCard.of(Object error, {String title = 'This file can’t be used', List<Widget> actions = const []}) {
    if (error is BackupException) {
      return ErrorReportCard(title: title, message: error.message, details: error.details, actions: actions);
    }
    return ErrorReportCard(title: title, message: friendlyError(error), actions: actions);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return FTCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconBadge(icon: AppIcons.warning, size: 44, color: c.danger.withValues(alpha: 0.16)),
              const SizedBox(width: Gap.md),
              Expanded(child: Text(title, style: context.tx.section)),
            ],
          ),
          const SizedBox(height: Gap.md),
          Text(message, style: context.tx.bodyStrong),
          if (details.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: c.danger.withValues(alpha: c.isDark ? 0.08 : 0.06),
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(color: c.danger.withValues(alpha: 0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Details (${details.length})', style: context.tx.label.copyWith(color: c.danger)),
                  const SizedBox(height: Gap.xs),
                  for (final d in details.take(30))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('•  ', style: context.tx.caption),
                          Expanded(child: SelectableText(d, style: context.tx.caption.copyWith(color: c.text2))),
                        ],
                      ),
                    ),
                  if (details.length > 30)
                    Text('…and ${details.length - 30} more', style: context.tx.caption),
                ],
              ),
            ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: Gap.lg),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: actions),
          ],
        ],
      ),
    );
  }
}

/// Shows an error: detailed sheet for [BackupException]s with details,
/// otherwise a toast.
Future<void> showBackupError(BuildContext context, Object error, {String title = 'Something went wrong'}) async {
  if (error is BackupException && error.details.isNotEmpty) {
    await showFTSheet<void>(
      context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ErrorReportCard.of(error, title: title),
          const SizedBox(height: Gap.lg),
          FTButton.secondary(label: 'Close', expand: true, onTap: () => Navigator.of(ctx).pop()),
        ],
      ),
    );
    return;
  }
  if (context.mounted) {
    showFTToast(context, error is BackupException ? error.message : friendlyError(error), error: true);
  }
}

/// Password + confirmation fields with a strength meter.
class PasswordFields extends StatefulWidget {
  const PasswordFields({super.key, required this.password, required this.confirm, this.onChanged});
  final TextEditingController password;
  final TextEditingController confirm;
  final VoidCallback? onChanged;

  @override
  State<PasswordFields> createState() => _PasswordFieldsState();
}

class _PasswordFieldsState extends State<PasswordFields> {
  bool _show = false;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final s = passwordStrength(widget.password.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTTextField(
          controller: widget.password,
          label: 'Backup password',
          icon: AppIcons.key,
          obscure: !_show,
          textCapitalization: TextCapitalization.none,
          textInputAction: TextInputAction.next,
          onChanged: (_) {
            setState(() {});
            widget.onChanged?.call();
          },
          validator: (v) {
            if (v == null || v.isEmpty) return 'Choose a password';
            if (v.length < 6) return 'Use at least 6 characters';
            return null;
          },
          suffix: IconButton(
            tooltip: _show ? 'Hide password' : 'Show password',
            onPressed: () => setState(() => _show = !_show),
            icon: Icon(_show ? AppIcons.eyeOff : AppIcons.eye, size: 20, color: c.text3),
          ),
        ),
        const SizedBox(height: Gap.sm),
        FTTextField(
          controller: widget.confirm,
          label: 'Repeat password',
          icon: AppIcons.lock,
          obscure: !_show,
          textCapitalization: TextCapitalization.none,
          validator: (v) => v != widget.password.text ? 'The passwords don’t match' : null,
        ),
        const SizedBox(height: Gap.sm),
        StripedProgress(
          value: s / 4,
          label: 'Password strength',
          trailing: passwordStrengthLabel(s),
          height: 34,
        ),
        const SizedBox(height: Gap.xs),
        Text(
          'There is no way to recover a forgotten password – keep it somewhere safe. '
          'Longer passphrases (4+ words) are strongest.',
          style: context.tx.caption,
        ),
      ],
    );
  }
}

/// Bottom sheet offering to share or save a freshly created file.
Future<void> showFileReadySheet(
  BuildContext context, {
  required String title,
  required String path,
  required String mimeType,
  String? summary,
  List<String> notes = const [],
  IconData icon = AppIcons.checkCircle,
}) async {
  final size = await _sizeOf(path);
  if (!context.mounted) return;
  await showFTSheet<void>(
    context,
    builder: (ctx) {
      final c = ctx.ft;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconBadge(icon: icon, size: 48, accent: true),
              const SizedBox(width: Gap.md),
              Expanded(child: Text(title, style: ctx.tx.title)),
            ],
          ),
          const SizedBox(height: Gap.lg),
          FTCard(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(
              children: [
                Icon(AppIcons.document, color: c.accent, size: 22),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(path.split(RegExp(r'[\\/]')).last,
                          style: ctx.tx.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
                      Text(formatBytes(size), style: ctx.tx.caption),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (summary != null) ...[
            const SizedBox(height: Gap.sm),
            Text(summary, style: ctx.tx.body),
          ],
          for (final n in notes) ...[
            const SizedBox(height: Gap.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(AppIcons.info, size: 16, color: c.warning),
                const SizedBox(width: Gap.xs),
                Expanded(child: Text(n, style: ctx.tx.caption)),
              ],
            ),
          ],
          const SizedBox(height: Gap.xl),
          Builder(
            builder: (bctx) => FTButton(
              label: 'Share',
              icon: AppIcons.share,
              expand: true,
              onTap: () async {
                final ok = await shareFile(bctx, path, mimeType: mimeType);
                if (!ok && bctx.mounted) showFTToast(bctx, 'Sharing is not available on this device.', error: true);
              },
            ),
          ),
          const SizedBox(height: Gap.sm),
          FTButton.secondary(
            label: 'Save to device',
            icon: AppIcons.download,
            expand: true,
            onTap: () async {
              try {
                final ok = await saveFileToDevice(path, mimeType: mimeType);
                if (ok && ctx.mounted) showFTToast(ctx, 'Saved');
              } catch (e) {
                if (ctx.mounted) showFTToast(ctx, 'The file could not be saved: ${friendlyError(e)}', error: true);
              }
            },
          ),
        ],
      );
    },
  );
}

Future<int> _sizeOf(String path) async {
  try {
    return await File(path).length();
  } catch (_) {
    return 0;
  }
}

/// "3 days ago" style relative time.
String relativeTime(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final d = n.difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays == 1) return 'yesterday';
  if (d.inDays < 30) return '${d.inDays} days ago';
  if (d.inDays < 365) return '${(d.inDays / 30).floor()} months ago';
  return '${(d.inDays / 365).floor()} years ago';
}

String formatDateTime(DateTime t) {
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final l = t.toLocal();
  return '${l.day} ${m[l.month - 1]} ${l.year}, ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// Simple labelled metric used in previews (fixed width for wrapping).
class PreviewMetric extends StatelessWidget {
  const PreviewMetric({super.key, required this.value, required this.label, required this.icon});
  final int value;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 120,
        child: MetricTile(value: '$value', label: label, icon: icon),
      );
}
