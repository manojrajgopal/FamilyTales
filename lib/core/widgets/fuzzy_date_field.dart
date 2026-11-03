import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../app/theme/tokens.dart';
import '../models/fuzzy_date.dart';
import 'app_icons.dart';
import 'ft_buttons.dart';
import 'ft_inputs.dart';
import 'ft_sheets.dart';

/// Form field for historical dates. Opens an editor that supports exact
/// dates, month/year, year only, approximate, before, after, ranges and
/// free-text phrases – without ever inventing missing parts.
class FuzzyDateField extends StatelessWidget {
  const FuzzyDateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.icon = AppIcons.calendarBlank,
  });

  final String label;
  final FuzzyDate? value;
  final ValueChanged<FuzzyDate?> onChanged;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return FTSelectField(
      label: label,
      icon: icon,
      value: value?.format(long: true),
      placeholder: 'Unknown',
      onClear: () => onChanged(null),
      onTap: () async {
        final r = await showFuzzyDateEditor(context, title: label, initial: value);
        if (r != null) onChanged(r.date);
      },
    );
  }
}

/// Result wrapper so "cleared" (null date) can be distinguished from
/// "dismissed" (null result).
class FuzzyDateResult {
  const FuzzyDateResult(this.date);
  final FuzzyDate? date;
}

Future<FuzzyDateResult?> showFuzzyDateEditor(
  BuildContext context, {
  required String title,
  FuzzyDate? initial,
}) {
  return showFTSheet<FuzzyDateResult>(
    context,
    title: title,
    builder: (_) => _FuzzyDateEditor(initial: initial),
  );
}

enum _Mode { exact, about, before, after, between, text }

class _FuzzyDateEditor extends StatefulWidget {
  const _FuzzyDateEditor({this.initial});
  final FuzzyDate? initial;

  @override
  State<_FuzzyDateEditor> createState() => _FuzzyDateEditorState();
}

class _FuzzyDateEditorState extends State<_FuzzyDateEditor> {
  final _form = GlobalKey<FormState>();
  late _Mode _mode;
  late final TextEditingController _y, _d, _y2, _d2, _phrase;
  int? _m, _m2;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _mode = switch (i?.qualifier) {
      DateQualifier.about => _Mode.about,
      DateQualifier.before => _Mode.before,
      DateQualifier.after => _Mode.after,
      DateQualifier.between => _Mode.between,
      DateQualifier.text => _Mode.text,
      _ => _Mode.exact,
    };
    _y = TextEditingController(text: i?.year?.toString() ?? '');
    _d = TextEditingController(text: i?.day?.toString() ?? '');
    _y2 = TextEditingController(text: i?.year2?.toString() ?? '');
    _d2 = TextEditingController(text: i?.day2?.toString() ?? '');
    _phrase = TextEditingController(text: i?.phrase ?? '');
    _m = i?.month;
    _m2 = i?.month2;
  }

  @override
  void dispose() {
    for (final c in [_y, _d, _y2, _d2, _phrase]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _validateYear(String? v, {bool required = true}) {
    if (v == null || v.trim().isEmpty) return required ? 'Year is required' : null;
    final y = int.tryParse(v);
    if (y == null || y < 1 || y > DateTime.now().year + 100) {
      return 'Enter a valid year';
    }
    return null;
  }

  String? _validateDay(String? v, int? month, String year) {
    if (v == null || v.trim().isEmpty) return null;
    if (month == null) return 'Choose a month first';
    final d = int.tryParse(v);
    final y = int.tryParse(year) ?? 2000;
    final max = DateUtils.getDaysInMonth(y, month);
    if (d == null || d < 1 || d > max) return '1–$max';
    return null;
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    FuzzyDate date;
    if (_mode == _Mode.text) {
      date = FuzzyDate.text(_phrase.text.trim());
    } else {
      final y = int.parse(_y.text);
      final d = _m == null ? null : int.tryParse(_d.text);
      final q = switch (_mode) {
        _Mode.about => DateQualifier.about,
        _Mode.before => DateQualifier.before,
        _Mode.after => DateQualifier.after,
        _Mode.between => DateQualifier.between,
        _ => DateQualifier.exact,
      };
      if (q == DateQualifier.between) {
        final y2 = int.parse(_y2.text);
        final d2 = _m2 == null ? null : int.tryParse(_d2.text);
        date = FuzzyDate(
            qualifier: q,
            year: y,
            month: _m,
            day: d,
            year2: y2,
            month2: _m2,
            day2: d2);
        if (date.year! > y2) {
          showFTToast(context, 'The range end must be after its start',
              error: true);
          return;
        }
      } else {
        date = FuzzyDate(qualifier: q, year: y, month: _m, day: d);
      }
    }
    Navigator.of(context).pop(FuzzyDateResult(date));
  }

  Future<void> _pickCalendar() async {
    final now = DateTime.now();
    final init = DateTime(
      int.tryParse(_y.text) ?? now.year,
      _m ?? now.month,
      int.tryParse(_d.text) ?? 1,
    );
    final picked = await showDatePicker(
      context: context,
      initialDate: init.isAfter(DateTime(2200)) ? now : init,
      firstDate: DateTime(1000),
      lastDate: DateTime(now.year + 100),
    );
    if (picked != null) {
      setState(() {
        _y.text = '${picked.year}';
        _m = picked.month;
        _d.text = '${picked.day}';
      });
    }
  }

  Widget _dateRow(TextEditingController y, int? month,
      ValueChanged<int?> onMonth, TextEditingController d,
      {String prefix = ''}) {
    final months = List.generate(12, (i) => DateFormat.MMM().format(DateTime(2000, i + 1)));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: FTTextField(
            controller: d,
            label: '${prefix}Day',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 2,
            validator: (v) => _validateDay(v, month, y.text),
          ),
        ),
        const SizedBox(width: Gap.xs),
        Expanded(
          flex: 4,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 22),
            child: FTSelectField(
              label: '${prefix}Month',
              value: month == null ? null : months[month - 1],
              placeholder: '—',
              onClear: () => onMonth(null),
              onTap: () async {
                final r = await showFTOptions<int>(
                  context,
                  title: 'Month',
                  options: [
                    for (var i = 0; i < 12; i++)
                      FTOption(i + 1, DateFormat.MMMM().format(DateTime(2000, i + 1)),
                          selected: month == i + 1),
                  ],
                );
                if (r != null) onMonth(r);
              },
            ),
          ),
        ),
        const SizedBox(width: Gap.xs),
        Expanded(
          flex: 4,
          child: FTTextField(
            controller: y,
            label: '${prefix}Year',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 4,
            validator: (v) => _validateYear(v),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const labels = {
      _Mode.exact: 'Exact',
      _Mode.about: 'About',
      _Mode.before: 'Before',
      _Mode.after: 'After',
      _Mode.between: 'Between',
      _Mode.text: 'In words',
    };
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: Gap.xs,
            runSpacing: Gap.xs,
            children: [
              for (final m in _Mode.values)
                FTChip(
                  label: labels[m]!,
                  selected: _mode == m,
                  onTap: () => setState(() => _mode = m),
                ),
            ],
          ),
          const SizedBox(height: Gap.md),
          Text(
            _mode == _Mode.text
                ? 'Describe the date in words, e.g. "Spring, before the war".'
                : 'Fill in only what you know. Day and month are optional.',
            style: context.tx.caption,
          ),
          const SizedBox(height: Gap.md),
          if (_mode == _Mode.text)
            FTTextField(
              controller: _phrase,
              label: 'Date description',
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Please describe the date' : null,
            )
          else ...[
            _dateRow(_y, _m, (v) => setState(() => _m = v), _d,
                prefix: _mode == _Mode.between ? 'From ' : ''),
            if (_mode == _Mode.between) ...[
              const SizedBox(height: Gap.xs),
              _dateRow(_y2, _m2, (v) => setState(() => _m2 = v), _d2,
                  prefix: 'To '),
            ],
            if (_mode != _Mode.between)
              Align(
                alignment: Alignment.centerLeft,
                child: FTTextAction('Pick from calendar',
                    accent: true, onTap: _pickCalendar),
              ),
          ],
          const SizedBox(height: Gap.lg),
          Row(
            children: [
              Expanded(
                child: FTButton.secondary(
                  label: 'Unknown',
                  expand: true,
                  onTap: () =>
                      Navigator.of(context).pop(const FuzzyDateResult(null)),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: FTButton(label: 'Save date', expand: true, onTap: _save),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
