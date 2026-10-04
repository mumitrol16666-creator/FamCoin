import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../budget/sheets.dart';
import '../widgets/common.dart';

/// S33 — категории: встроенные и свои. Свою можно переименовать, сменить
/// значок и удалить, пока она не использована в операциях.
class CategoriesScreen extends StatelessWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final own = state.ownCategories;
        return Scaffold(
          appBar: AppBar(title: Text(l.categories)),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => showCategorySheet(context),
            icon: const Icon(Icons.add),
            label: Text(l.ownCategory),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
            children: [
              SectionHeader(l.ownCategories),
              if (own.isEmpty)
                EmptyHint(l.noOwnCategories, icon: Icons.label_outline)
              else
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(children: [
                    for (final c in own)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CategoryAvatar.of(c),
                        title: Text(c.name!),
                        subtitle: Text(c.isIncome ? l.income : l.expense, style: TextStyle(fontSize: 12, color: fam.text2)),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'edit') {
                              await showCategorySheet(context, initial: c);
                            } else if (state.categoryInUse(c.id)) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.categoryInUse)));
                            } else if (await confirm(context, title: l.deleteCategory, action: l.delete) && context.mounted) {
                              await runAction(context, () => state.delete('category', c.id));
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(value: 'edit', child: Text(l.edit)),
                            PopupMenuItem(value: 'delete', child: Text(l.delete)),
                          ],
                        ),
                        onTap: () => showCategorySheet(context, initial: c),
                      ),
                  ]),
                ),
              SectionHeader(l.builtInCategories),
              AppCard(
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final c in categories.where((c) => c.id != 'interest' && c.id != 'fees'))
                    if (c.id == 'other' || c.id == 'otherIncome')
                      Chip(avatar: CategoryGlyph(c, size: 16), label: Text(categoryName(l, c.id)))
                    else
                      FilterChip(
                        avatar: CategoryGlyph(c, size: 16, color: state.hiddenCategories.contains(c.id) ? fam.text2 : null),
                        label: Text(categoryName(l, c.id), style: state.hiddenCategories.contains(c.id) ? TextStyle(color: fam.text2, decoration: TextDecoration.lineThrough) : null),
                        selected: !state.hiddenCategories.contains(c.id),
                        onSelected: (visible) => runAction(context, () => state.setCategoryHidden(c.id, !visible)),
                      ),
                ]),
              ),
              Text(l.builtInNote, style: TextStyle(fontSize: 12, color: fam.text2)),
              const SizedBox(height: 4),
              Text(l.builtInHideNote, style: TextStyle(fontSize: 12, color: fam.text2)),
            ],
          ),
        );
      },
    );
  }
}

/// Q07 — форма своей категории. Возвращает id созданной или изменённой.
Future<String?> showCategorySheet(BuildContext context, {CategoryDef? initial, bool income = false}) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final name = TextEditingController(text: initial?.name ?? '');
  var icon = initial?.iconIndex ?? 0;
  // Свой смайлик вместо значка (D107): один символ, заменяет значок везде.
  final emoji = TextEditingController(text: initial?.hasEmoji == true ? initial!.emoji : '');
  var isIncome = initial?.isIncome ?? income;
  // Тип расхода можно задать и поменять (F12) — иначе своя категория всегда
  // молча считалась свободной, а владелец мог не знать, что это вообще
  // настраивается.
  var expenseType = initial?.expenseType ?? ExpenseType.discretionary;
  return showFormSheet<String>(
    context,
    title: initial == null ? l.ownCategory : l.editCategory,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: name, autofocus: initial == null, maxLength: 30, decoration: InputDecoration(labelText: l.categoryNameLabel, hintText: l.categoryNameHint, counterText: '')),
        const SizedBox(height: 8),
        if (initial == null)
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [ButtonSegment(value: false, label: Text(l.expense)), ButtonSegment(value: true, label: Text(l.income))],
            selected: {isIncome},
            onSelectionChanged: (s) => set(() => isIncome = s.first),
          ),
        if (!isIncome) ...[
          const SizedBox(height: 12),
          Text(l.categoryExpenseType, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
          const SizedBox(height: 6),
          SegmentedButton<ExpenseType>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: ExpenseType.mandatory, label: Text(l.typeMandatory)),
              ButtonSegment(value: ExpenseType.regular, label: Text(l.typeRegular)),
              ButtonSegment(value: ExpenseType.discretionary, label: Text(l.typeDiscretionary)),
            ],
            selected: {expenseType},
            onSelectionChanged: (s) => set(() => expenseType = s.first),
          ),
        ],
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: emoji,
              maxLength: 1,
              onChanged: (_) => set(() {}),
              decoration: InputDecoration(labelText: l.categoryEmoji, hintText: l.categoryEmojiHint, counterText: ''),
            ),
          ),
          const SizedBox(width: 12),
          CategoryAvatar(customIcons[icon], emoji: emoji.text.trim().isEmpty ? null : emoji.text.trim(), color: ctx.scheme.primary),
        ]),
        Text(l.categoryEmojiNote, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
        const SizedBox(height: 12),
        Text(l.categoryIcon, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
        const SizedBox(height: 6),
        Opacity(
          opacity: emoji.text.trim().isEmpty ? 1 : .45,
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (var i = 0; i < customIcons.length; i++)
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => set(() {
                  icon = i;
                  emoji.clear();
                }),
                child: CategoryAvatar(customIcons[i], color: icon == i ? ctx.scheme.primary : null),
              ),
          ]),
        ),
        const SizedBox(height: 20),
        SubmitButton(
          label: l.save,
          onSubmit: () async {
            final n = name.text.trim();
            if (n.isEmpty) return false;
            String? id = initial?.id;
            final ok = await runAction(ctx, () async {
              if (initial == null) {
                id = await state.addCategory(name: n, iconIndex: icon, income: isIncome, expenseType: isIncome ? null : expenseType, emoji: emoji.text);
              } else {
                final e = emoji.text.trim();
                await state.upsert('category', initial.id, {'name': n, 'icon': icon, 'income': initial.isIncome, if (!initial.isIncome) 'expenseType': expenseType.name, if (e.isNotEmpty) 'emoji': e});
              }
            });
            if (ok && ctx.mounted) Navigator.of(ctx).pop(id);
            return false; // закрываем сами, чтобы вернуть id
          },
        ),
      ]),
    ),
  );
}
