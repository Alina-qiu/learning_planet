import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../application/family_providers.dart';
import '../application/auth_providers.dart';

Future<void> enterParentMode(
  BuildContext context,
  WidgetRef ref,
  String familyId,
) async {
  if (ref.read(signingOutProvider)) return;
  final revision = ref.read(parentAuthorizationRevisionProvider);
  bool current() =>
      context.mounted &&
      !ref.read(signingOutProvider) &&
      ref.read(parentAuthorizationRevisionProvider) == revision;
  var enteredPin = '';
  final pin = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('输入家长 PIN'),
      content: TextField(
        onChanged: (value) => enteredPin = value,
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
          onPressed: () => Navigator.pop(context, enteredPin),
          child: const Text('验证'),
        ),
      ],
    ),
  );
  if (pin == null || pin.isEmpty || !current()) return;

  try {
    final result = await ref
        .read(familyRepositoryProvider)
        .verifyParentPin(familyId: familyId, pin: pin);
    if (!context.mounted || !current()) return;
    if (result.verified) {
      if (result.authorizedUntil == null) {
        throw StateError('请先部署服务端 PIN 授权迁移');
      }
      ref.read(parentAuthorizedUntilProvider.notifier).state =
          result.authorizedUntil;
      ref.read(parentFamilyIdProvider.notifier).state = familyId;
      ref.read(parentModeProvider.notifier).state = true;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已进入家长模式')));
    } else {
      final message = result.retryAt == null
          ? 'PIN 错误，还可尝试 ${result.remainingAttempts} 次'
          : '尝试次数过多，请稍后再试';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  } catch (error) {
    if (!context.mounted || !current()) return;
    if (error is PostgrestException &&
        error.message == 'Parent PIN is not configured' &&
        RegExp(r'^\d{4,6}$').hasMatch(pin)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('首次设置家长 PIN'),
          content: const Text('此家庭尚未设置 PIN。是否将刚输入的数字设为家长 PIN？仅家庭管理员可设置。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认设置'),
            ),
          ],
        ),
      );
      if (confirmed != true || !current()) return;
      try {
        await ref
            .read(familyRepositoryProvider)
            .setParentPin(familyId: familyId, pin: pin);
        if (!current()) return;
        final verified = await ref
            .read(familyRepositoryProvider)
            .verifyParentPin(familyId: familyId, pin: pin);
        if (!verified.verified || verified.authorizedUntil == null) {
          throw StateError('服务端未授予家长授权');
        }
        if (!current()) return;
        ref.read(parentAuthorizedUntilProvider.notifier).state =
            verified.authorizedUntil;
        ref.read(parentFamilyIdProvider.notifier).state = familyId;
        ref.read(parentModeProvider.notifier).state = true;
      } catch (setupError) {
        if (context.mounted && current()) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('设置失败：$setupError')));
        }
      }
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('验证失败：$error')));
  }
}
