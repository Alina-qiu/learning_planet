import 'package:flutter/material.dart';
import '../domain/family.dart';

const childAvatarOptions = {
  'star': ('星星', Icons.star_outline),
  'moon': ('月亮', Icons.nightlight_round),
  'sun': ('太阳', Icons.wb_sunny_outlined),
  'rocket': ('火箭', Icons.rocket_launch_outlined),
  'planet': ('星球', Icons.public),
  'leaf': ('绿叶', Icons.eco_outlined),
};
const textbookSubjects = {'chinese': '语文', 'math': '数学', 'english': '英语'};

class ChildAvatar extends StatelessWidget {
  const ChildAvatar({required this.avatarKey, super.key});
  final String avatarKey;
  @override
  Widget build(BuildContext context) {
    final option = childAvatarOptions[avatarKey] ?? childAvatarOptions['star']!;
    return CircleAvatar(
      child: Icon(option.$2, semanticLabel: '${option.$1}头像'),
    );
  }
}

class ChildProfileInput {
  ChildProfileInput([ChildProfile? child])
    : nickname = TextEditingController(text: child?.nickname ?? ''),
      grade = child?.grade ?? 1,
      avatarKey = child?.avatarKey ?? 'star',
      textbooks = {
        for (final subject in textbookSubjects.keys)
          subject: TextEditingController(
            text: child?.textbookLabels[subject] ?? '',
          ),
      };
  final TextEditingController nickname;
  final Map<String, TextEditingController> textbooks;
  int grade;
  String avatarKey;
  Map<String, String> get labels => {
    for (final entry in textbooks.entries)
      if (entry.value.text.trim().isNotEmpty)
        entry.key: entry.value.text.trim(),
  };
  void dispose() {
    nickname.dispose();
    for (final field in textbooks.values) {
      field.dispose();
    }
  }
}

class ChildProfileFields extends StatefulWidget {
  const ChildProfileFields({required this.input, super.key});
  final ChildProfileInput input;
  @override
  State<ChildProfileFields> createState() => _ChildProfileFieldsState();
}

class _ChildProfileFieldsState extends State<ChildProfileFields> {
  @override
  Widget build(BuildContext context) {
    final input = widget.input;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: input.nickname,
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: '孩子昵称',
            helperText: '不需要填写真实姓名',
          ),
          validator: (value) =>
              value == null || value.trim().isEmpty ? '请输入昵称' : null,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          initialValue: input.grade,
          decoration: const InputDecoration(labelText: '年级'),
          items: [
            for (var grade = 1; grade <= 6; grade++)
              DropdownMenuItem(value: grade, child: Text('$grade 年级')),
          ],
          onChanged: (value) => setState(() => input.grade = value!),
        ),
        const SizedBox(height: 16),
        const Text('选择头像'),
        Wrap(
          spacing: 8,
          children: [
            for (final entry in childAvatarOptions.entries)
              ChoiceChip(
                avatar: Icon(entry.value.$2, size: 18),
                label: Text(entry.value.$1),
                selected: input.avatarKey == entry.key,
                onSelected: (_) => setState(() => input.avatarKey = entry.key),
              ),
          ],
        ),
        const SizedBox(height: 16),
        const Text('教材版本（可选，自定义标签）'),
        for (final entry in textbookSubjects.entries)
          TextFormField(
            controller: input.textbooks[entry.key],
            maxLength: 60,
            decoration: InputDecoration(
              labelText: '${entry.value}教材版本',
              hintText: '例如：人教版、校本教材',
            ),
            validator: (value) =>
                (value?.trim().length ?? 0) > 60 ? '请控制在60字以内' : null,
          ),
      ],
    );
  }
}
