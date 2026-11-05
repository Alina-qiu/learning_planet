import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/family_providers.dart';
import 'child_profile_fields.dart';
import 'family_creation_screen.dart';
import 'app_sign_out.dart';
import '../../data_management/presentation/account_deletion_screen.dart';

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
  final _childInput = ChildProfileInput();
  var _isSaving = false;

  @override
  void dispose() {
    _familyController.dispose();
    _childInput.dispose();
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '此项不能为空' : null;

  Future<void> _submit() async {
    if (_isSaving || !_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    try {
      await ref
          .read(familyRepositoryProvider)
          .createFamilyWithChild(
            familyName: _familyController.text.trim(),
            timezone: 'Asia/Shanghai',
            childNickname: _childInput.nickname.text.trim(),
            grade: _childInput.grade,
            textbookLabels: _childInput.labels,
            avatarKey: _childInput.avatarKey,
          );
      if (mounted) ref.invalidate(familiesProvider);
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
    if (ref.watch(familyCreationRepositoryProvider) != null) {
      return const FamilyCreationScreen();
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('创建家庭'),
        actions: [
          const AppSignOutButton(),
          IconButton(
            tooltip: '注销我的账号',
            icon: const Icon(Icons.person_remove_outlined),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => const AccountDeletionScreen()),
            ),
          ),
        ],
      ),
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
                    ChildProfileFields(input: _childInput),
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
