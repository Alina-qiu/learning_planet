import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/auth_providers.dart';
import '../data/auth_repository.dart';
import '../data/email_otp.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailForm = GlobalKey<FormState>(), _codeForm = GlobalKey<FormState>();
  final _email = TextEditingController(), _code = TextEditingController();
  final _resendWatch = Stopwatch();
  Timer? _resendTimer, _resendTicker;
  String? _targetEmail, _message;
  bool _busy = false, _verifying = false;
  int _revision = 0, _resendSeconds = 0;

  @override
  void dispose() {
    _revision++;
    _resendTimer?.cancel();
    _resendTicker?.cancel();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  bool _current(AuthRepository repository, int revision) =>
      mounted &&
      revision == _revision &&
      identical(ref.read(authRepositoryProvider), repository) &&
      repository.currentSession == null;

  String? _validateEmail(String? value) {
    final email = normalizedLoginEmail(value ?? '');
    if (email.isEmpty) return '请输入邮箱地址';
    return validLoginEmail(email) ? null : '请输入有效的邮箱地址';
  }

  void _startCooldown() {
    _resendTimer?.cancel();
    _resendTicker?.cancel();
    _resendWatch
      ..reset()
      ..start();
    _resendSeconds = 60;
    _resendTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(
          () =>
              _resendSeconds = math.max(1, 60 - _resendWatch.elapsed.inSeconds),
        );
      }
    });
    _resendTimer = Timer(const Duration(seconds: 60), () {
      _resendTicker?.cancel();
      _resendWatch.stop();
      if (mounted) setState(() => _resendSeconds = 0);
    });
  }

  Future<void> _send() async {
    if (_busy || _resendSeconds > 0) return;
    if (_targetEmail == null && !_emailForm.currentState!.validate()) return;
    final repository = ref.read(authRepositoryProvider), revision = _revision;
    if (!_current(repository, revision)) return;
    final email = _targetEmail ?? normalizedLoginEmail(_email.text);
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _targetEmail = email;
      _busy = true;
      _verifying = false;
      _message = null;
      _startCooldown();
    });
    try {
      await repository.sendEmailOtp(email);
      if (_current(repository, revision)) {
        setState(() => _message = '请检查邮箱并输入验证码，也可以查看垃圾邮件文件夹。');
      }
    } catch (error) {
      if (_current(repository, revision)) {
        setState(() => _message = emailOtpError(error, verifying: false));
      }
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    if (_busy || !_codeForm.currentState!.validate()) return;
    final repository = ref.read(authRepositoryProvider), revision = _revision;
    if (!_current(repository, revision)) return;
    final email = _targetEmail!, code = _code.text.trim();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _verifying = true;
      _message = null;
    });
    try {
      await repository.verifyEmailOtp(
        email,
        code,
        isCurrent: () => _current(repository, revision),
      );
      if (mounted && revision == _revision) _code.clear();
      // AuthGate opens the family only after the repository commits a session.
    } catch (error) {
      if (_current(repository, revision)) {
        setState(() => _message = emailOtpError(error, verifying: true));
      }
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '登录学习星球',
                  style: Theme.of(context).textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text('使用家长邮箱接收一次性验证码。', textAlign: TextAlign.center),
                const SizedBox(height: 28),
                if (_targetEmail == null)
                  Form(
                    key: _emailForm,
                    child: TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.email],
                      autocorrect: false,
                      enableSuggestions: false,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: '家长邮箱',
                        border: OutlineInputBorder(),
                      ),
                      validator: _validateEmail,
                      onFieldSubmitted: (_) => _send(),
                    ),
                  )
                else ...[
                  Text(
                    _targetEmail!,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _revision++;
                              _targetEmail = null;
                              _message = null;
                              _code.clear();
                            }),
                      child: const Text('更换邮箱'),
                    ),
                  ),
                  Form(
                    key: _codeForm,
                    child: TextFormField(
                      controller: _code,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      autocorrect: false,
                      enableSuggestions: false,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      maxLength: 10,
                      decoration: const InputDecoration(
                        labelText: '邮箱验证码',
                        helperText: '输入邮件中的6至10位数字',
                        helperMaxLines: 2,
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) => validEmailOtp(value?.trim() ?? '')
                          ? null
                          : '请输入完整的数字验证码',
                      onFieldSubmitted: (_) => _verify(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _verify,
                    child: Text(_busy && _verifying ? '验证中…' : '验证并登录'),
                  ),
                ],
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: _busy || _resendSeconds > 0 ? null : _send,
                  child: Text(
                    _busy && !_verifying
                        ? '发送中…'
                        : _resendSeconds > 0
                        ? '$_resendSeconds秒后可重新发送'
                        : _targetEmail == null
                        ? '发送验证码'
                        : '重新发送验证码',
                  ),
                ),
                if (_targetEmail == null)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            if (_emailForm.currentState!.validate()) {
                              setState(
                                () => _targetEmail = normalizedLoginEmail(
                                  _email.text,
                                ),
                              );
                            }
                          },
                    child: const Text('已有验证码'),
                  ),
                if (_message != null) ...[
                  const SizedBox(height: 16),
                  Semantics(liveRegion: true, child: Text(_message!)),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
