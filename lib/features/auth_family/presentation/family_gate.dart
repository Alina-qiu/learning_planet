import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../home/presentation/home_screen.dart';
import '../application/auth_providers.dart';
import '../application/family_providers.dart';
import 'family_management_screen.dart';
import 'family_onboarding_screen.dart';

class FamilyGate extends ConsumerWidget {
  const FamilyGate({super.key});

  Future<void> _enterParentMode(
    BuildContext context,
    WidgetRef ref,
    String familyId,
  ) async {
    final controller = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('输入家长 PIN'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          obscureText: true,
          maxLength: 6,
          decoration: const InputDecoration(labelText: '4 至 6 位数字'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('验证'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (pin == null || pin.isEmpty || !context.mounted) return;

    try {
      final result = await ref.read(familyRepositoryProvider).verifyParentPin(
            familyId: familyId,
            pin: pin,
          );
      if (!context.mounted) return;
      if (result.verified) {
        ref.read(parentModeProvider.notifier).state = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已进入家长模式')),
        );
      } else {
        final message = result.retryAt == null
            ? 'PIN 错误，还可尝试 ${result.remainingAttempts} 次'
            : '尝试次数过多，请稍后再试';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('验证失败：$error')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(familiesProvider).when(
          data: (families) {
            if (families.isEmpty) return const FamilyOnboardingScreen();
            final children =
                families.expand((family) => family.children).toList();
            if (children.isEmpty) return const FamilyOnboardingScreen();
            final selectedId = ref.watch(selectedChildIdProvider);
            final isParentMode = ref.watch(parentModeProvider);
            final child = children.firstWhere(
              (item) => item.id == selectedId,
              orElse: () => children.first,
            );
            return HomeScreen(
              childNickname: child.nickname,
              children: children,
              selectedChildId: child.id,
              onChildSelected: (id) =>
                  ref.read(selectedChildIdProvider.notifier).state = id,
              onManageFamily: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const FamilyManagementScreen(),
                ),
              ),
              isParentMode: isParentMode,
              onParentMode: () => _enterParentMode(
                context,
                ref,
                child.familyId,
              ),
              onSignOut: () => ref.read(authRepositoryProvider).signOut(),
            );
          },
          loading: () => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
          error: (error, stackTrace) => Scaffold(
            body: Center(child: Text('家庭数据读取失败：$error')),
          ),
        );
  }
}
