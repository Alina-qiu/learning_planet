import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/offline/network_failure.dart';
import '../application/auth_providers.dart';
import 'app_sign_out.dart';

enum EntryCheck { session, family, account }

/// Entry failures offer recovery without rendering server or storage payloads.
/// Retrying only reloads the failed check; leaving uses the shared safe logout.
class EntryRecoveryScreen extends ConsumerWidget {
  const EntryRecoveryScreen({
    required this.check,
    required this.error,
    required this.onRetry,
    this.retrying = false,
    super.key,
  });

  final EntryCheck check;
  final Object error;
  final VoidCallback onRetry;
  final bool retrying;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = isNetworkFailure(error);
    final needsLogin = !network && _needsLogin(error);
    final title = network
        ? '暂时无法连接服务'
        : needsLogin
        ? '请重新登录'
        : switch (check) {
            EntryCheck.session => '登录状态暂时无法读取',
            EntryCheck.family => '家庭资料暂时无法读取',
            EntryCheck.account => '账号状态暂时无法确认',
          };
    final message = network
        ? '请检查网络后重试。若仍无法进入，可以退出后重新登录。'
        : needsLogin
        ? '当前登录状态无法继续使用。退出后可通过邮箱验证码重新登录。'
        : '请重试。若仍无法进入，可以退出后重新登录。';
    return Scaffold(
      appBar: AppBar(title: const Text('学习星球')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    network ? Icons.cloud_off_outlined : Icons.lock_outline,
                    size: 40,
                  ),
                  const SizedBox(height: 16),
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: retrying || ref.watch(signingOutProvider)
                        ? null
                        : onRetry,
                    child: Text(retrying ? '正在重试…' : '重试'),
                  ),
                  const SizedBox(height: 8),
                  const AppSignOutButton(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

bool _needsLogin(Object error) =>
    error is AuthSessionMissingException ||
    error is AuthException &&
        const {
          'bad_jwt',
          'invalid_jwt',
          'session_not_found',
          'session_expired',
          'refresh_token_not_found',
          'refresh_token_already_used',
          'user_not_found',
        }.contains(error.code) ||
    error is PostgrestException &&
        const {'401', 'PGRST301', 'PGRST303'}.contains(error.code);
