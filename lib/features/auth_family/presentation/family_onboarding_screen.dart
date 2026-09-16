import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/family_providers.dart';

class FamilyOnboardingScreen extends ConsumerStatefulWidget {
  const FamilyOnboardingScreen({super.key});

  @override
  ConsumerState<FamilyOnboardingScreen> createState() =>
      _FamilyOnboardingScreenState();
}

class _FamilyOnboardingScreenState
    extends ConsumerState<FamilyOnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _familyController = TextEditingController();
  final _childController = TextEditingController();
  var _grade = 1;
  var _isSaving = false;

  @override
  void dispose() {
    _familyController.dispose();
    _childController.dispose();
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '此项不能为空' : null;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    try {
      await ref
          .read(familyRepositoryProvider)
          .createFamilyWithChild(
            familyName: _familyController.text.trim(),
            timezone: 'Asia/Shanghai',
            childNickname: _childController.text.trim(),
            grade: _grade,
          );
      ref.invalidate(familiesProvider);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('创建失败：$error')));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('创建家庭')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _familyController,
                      decoration: const InputDecoration(
                        labelText: '家庭名称',
                        border: OutlineInputBorder(),
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _childController,
                      decoration: const InputDecoration(
                        labelText: '孩子昵称',
                        border: OutlineInputBorder(),
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      initialValue: _grade,
                      decoration: const InputDecoration(
                        labelText: '年级',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (var grade = 1; grade <= 6; grade++)
                          DropdownMenuItem(
                            value: grade,
                            child: Text('$grade 年级'),
                          ),
                      ],
                      onChanged: (value) => setState(() => _grade = value ?? 1),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _isSaving ? null : _submit,
                      child: Text(_isSaving ? '创建中…' : '创建并开始'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
