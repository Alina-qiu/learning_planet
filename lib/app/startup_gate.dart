import 'package:flutter/material.dart';

import '../core/security/device_secrets.dart';
import 'theme.dart';

class StartupGate extends StatefulWidget {
  const StartupGate({required this.load, this.onFailure, super.key});
  final Future<Widget> Function() load;
  final void Function(Object error)? onFailure;
  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  Widget? _app;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final app = await widget.load();
      if (mounted) setState(() => _app = app);
    } catch (error) {
      try {
        widget.onFailure?.call(error);
      } catch (_) {
        /* Keep recovery available. */
      }
      if (mounted) {
        setState(() {
          _error = error is LocalDataException
              ? error.message
              : '应用暂时无法启动，请稍后重试。本机资料会继续保留。';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      _app ??
      MaterialApp(
        title: '学习星球',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_outline, size: 48),
                      const SizedBox(height: 16),
                      Text(_error == null ? '正在打开学习星球' : '暂时无法打开本机资料'),
                      const SizedBox(height: 16),
                      if (_loading) const CircularProgressIndicator(),
                      if (_error != null) ...[
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: _start,
                          child: const Text('重试'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
