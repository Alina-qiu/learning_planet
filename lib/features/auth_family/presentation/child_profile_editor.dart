import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/family_providers.dart';
import '../domain/family.dart';
import 'child_profile_fields.dart';
import 'family_creation_screen.dart';

class ChildProfileEditor extends ConsumerStatefulWidget {
  const ChildProfileEditor({required this.familyId, this.child, super.key});
  final String familyId;
  final ChildProfile? child;
  @override
  ConsumerState<ChildProfileEditor> createState() => _ChildProfileEditorState();
}

class _ChildProfileEditorState extends ConsumerState<ChildProfileEditor> {
  final _form = GlobalKey<FormState>();
  late final _input = ChildProfileInput(widget.child);
  bool _busy = false;
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final repository = ref.read(familyRepositoryProvider);
      if (widget.child case final child?) {
        await repository.updateChild(
          childId: child.id,
          nickname: _input.nickname.text.trim(),
          grade: _input.grade,
          textbookLabels: _input.labels,
          avatarKey: _input.avatarKey,
          expectedVersion: child.profileVersion,
        );
      } else {
        await repository.createChild(
          familyId: widget.familyId,
          nickname: _input.nickname.text.trim(),
          grade: _input.grade,
          textbookLabels: _input.labels,
          avatarKey: _input.avatarKey,
        );
      }
      if (!mounted) return;
      ref.invalidate(familiesProvider);
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('档案尚未保存：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      widget.child == null &&
          ref.watch(familyCreationRepositoryProvider) != null
      ? FamilyCreationScreen(familyId: widget.familyId)
      : Scaffold(
          appBar: AppBar(title: Text(widget.child == null ? '添加孩子' : '编辑孩子档案')),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AbsorbPointer(
                    absorbing: _busy,
                    child: ChildProfileFields(input: _input),
                  ),
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    child: Text(_busy ? '保存中…' : '保存'),
                  ),
                ],
              ),
            ),
          ),
        );
}
