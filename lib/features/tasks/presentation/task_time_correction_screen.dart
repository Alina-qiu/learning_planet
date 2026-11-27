import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../auth_family/application/auth_providers.dart';
import '../../auth_family/application/family_providers.dart';
import '../data/task_time_corrections.dart';

class TaskTimeCorrectionScreen extends ConsumerStatefulWidget {
  const TaskTimeCorrectionScreen({
    required this.scope,
    required this.title,
    super.key,
  });
  final TaskTimeScope scope;
  final String title;
  @override
  ConsumerState<TaskTimeCorrectionScreen> createState() =>
      _TaskTimeCorrectionScreenState();
}

class _TaskTimeCorrectionScreenState
    extends ConsumerState<TaskTimeCorrectionScreen> {
  final _minutes = TextEditingController(),
      _seconds = TextEditingController(),
      _reason = TextEditingController();
  final _form = GlobalKey<FormState>();
  TaskTimeCorrections? _repository;
  TimeAccess? _access;
  TaskTimeContext? _current;
  TaskTimeRequest? _request;
  bool _busy = false, _saved = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _minutes.dispose();
    _seconds.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _setCurrent(TaskTimeContext value) {
    _current = value;
    _minutes.text = '${value.seconds ~/ 60}';
    _seconds.text = '${value.seconds % 60}';
  }

  Future<void> _load() async {
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    try {
      final repository = ref.read(taskTimeCorrectionsProvider);
      if (repository == null) throw StateError('请先配置并登录服务');
      final access = repository.capture(widget.scope);
      _repository = repository;
      _access = access;
      final value = await repository.load(widget.scope, access: access);
      if (!mounted) return;
      setState(() {
        _setCurrent(value);
        _error = null;
        _saved = false;
        _request = null;
        _reason.clear();
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _current = null;
          _error = error is StateError
              ? error.message.toString()
              : '未能读取服务器计时，请联网后重试。';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy || _current == null || _current!.running) return;
    if (_request == null && !_form.currentState!.validate()) return;
    final total =
        (int.tryParse(_minutes.text) ?? 0) * 60 +
        (int.tryParse(_seconds.text) ?? 0);
    if (_request == null && total == _current!.seconds) {
      setState(() => _error = '时长未变化，请填写纠正后的实际时长。');
      return;
    }
    final repository = _repository!;
    _request ??= TaskTimeRequest(
      id: const Uuid().v4(),
      expectedVersion: _current!.version,
      seconds: total,
      reason: _reason.text.trim(),
      access: _access!,
    );
    setState(() {
      _busy = true;
      _saved = false;
      _error = null;
    });
    try {
      final value = await repository.correct(widget.scope, _request!);
      if (!mounted) return;
      setState(() {
        _setCurrent(value);
        _request = null;
        _reason.clear();
        _saved = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (error is StateError ||
            error is PostgrestException &&
                const ['42501', '40001', '22023'].contains(error.code)) {
          _request = null;
          _current = null;
          _error = error is StateError
              ? error.message.toString()
              : error is PostgrestException && error.code == '40001'
              ? '任务已被更新，请重新读取后核对时长。'
              : '任务状态或家长授权已变化，请重新读取核对。';
        } else {
          _error = '保存结果尚未确认。可重试原请求；若离开此页，请刷新任务核对实际时长。';
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _validScope(TaskTimeCorrections? repository) {
    if (repository == null ||
        !identical(repository, _repository) ||
        _access == null) {
      return false;
    }
    try {
      return repository.capture(widget.scope) == _access;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(activeParentFamilyProvider);
    ref.watch(parentAuthorizationRevisionProvider);
    ref.watch(signingOutProvider);
    final repository = ref.watch(taskTimeCorrectionsProvider);
    final current = _validScope(repository) ? _current : null;
    return Scaffold(
      appBar: AppBar(title: const Text('家长纠正计时')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (current == null) ...[
                  Text(_error ?? '请在家长授权有效时读取服务器计时。'),
                  FilledButton(
                    onPressed: _busy ? null : _load,
                    child: const Text('重新读取'),
                  ),
                ] else ...[
                  Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '当前累计：${current.seconds ~/ 60}分${current.seconds % 60}秒',
                  ),
                  const Text(
                    '填写实际累计时长和原因。纠正记录会保留前后时长及操作者，学习报告按纠正后的时长统计。完成状态和已有金币、XP保持原值。',
                  ),
                  if (current.running)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('任务仍在计时，请返回暂停并完成同步，再重新打开纠正。'),
                    ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _minutes,
                    readOnly: _busy || _request != null || current.running,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(8),
                    ],
                    decoration: const InputDecoration(labelText: '实际累计分钟'),
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null ||
                              n < 0 ||
                              n * 60 + (int.tryParse(_seconds.text) ?? 0) >
                                  2147483647
                          ? '请输入有效分钟数'
                          : null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _seconds,
                    readOnly: _busy || _request != null || current.running,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(2),
                    ],
                    decoration: const InputDecoration(labelText: '剩余秒数（0–59）'),
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null || n < 0 || n > 59 ? '请输入0至59秒' : null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _reason,
                    readOnly: _busy || _request != null || current.running,
                    maxLines: 3,
                    maxLength: 500,
                    decoration: const InputDecoration(labelText: '纠正原因（必填）'),
                    validator: (v) =>
                        v == null || v.trim().isEmpty || v.runes.length > 500
                        ? '请填写500字符以内的原因'
                        : null,
                  ),
                  if (_saved) const Text('纠正已受理，当前显示服务器最新时长。'),
                  if (_error != null) Text(_error!),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _busy || current.running ? null : _save,
                    child: Text(_request == null ? '确认纠正计时' : '重试原纠正请求'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
