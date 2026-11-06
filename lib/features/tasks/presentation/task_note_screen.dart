import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/task_notes.dart';

class TaskNoteScreen extends ConsumerStatefulWidget {
  const TaskNoteScreen({required this.scope, required this.title, super.key});
  final TaskNoteScope scope;
  final String title;
  @override
  ConsumerState<TaskNoteScreen> createState() => _TaskNoteScreenState();
}

class _TaskNoteScreenState extends ConsumerState<TaskNoteScreen> {
  final _text = TextEditingController();
  TaskNoteState? _state;
  bool _busy = true, _localSaving = false, _offline = false, _leaving = false;
  String? _error, _localError;
  int _editRevision = 0;
  Future<void> _draftWrite = Future.value();
  TaskNotes get _notes => ref.read(taskNotesProvider)!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _show(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _accept(TaskNoteState state) {
    _state = state;
    _text.text = state.editing;
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await _draftWrite;
    try {
      if (_localError != null) throw StateError('Draft not saved');
      final state = await _notes.load(widget.scope);
      if (mounted) {
        setState(() {
          _accept(state);
          _offline = state.offline;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法读取说明，请检查登录和家庭权限后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _edit(String text) {
    final revision = ++_editRevision;
    if (text.runes.length > 500) {
      setState(() {
        _localError = '说明最多 500 个字符，超出部分尚未保存';
        _localSaving = false;
      });
      return;
    }
    setState(() {
      _localSaving = true;
      _localError = null;
    });
    // Each edit is persisted before a remote request can be prepared.
    _draftWrite = () async {
      try {
        final state = await _notes.edit(widget.scope, text);
        if (mounted && revision == _editRevision) {
          setState(() => _state = state);
        }
      } catch (_) {
        if (mounted && revision == _editRevision) {
          setState(() => _localError = '草稿未能保存，请保留文字并重试');
        }
      } finally {
        if (mounted && revision == _editRevision) {
          setState(() => _localSaving = false);
        }
      }
    }();
  }

  Future<void> _resolve(String operation) async {
    setState(() => _busy = true);
    await _draftWrite;
    try {
      if (_localError != null) {
        _show(_localError!);
        return;
      }
      final prepared = await _notes.prepare(widget.scope);
      if (!mounted) return;
      setState(() => _state = prepared);
      final result = await _notes.resolve(
        widget.scope,
        prepared.requestId!,
        operation,
      );
      if (!mounted) return;
      setState(() {
        _accept(result.state);
        _offline = false;
      });
      _show(switch (result.status) {
        'applied' =>
          result.state.version > result.appliedVersion!
              ? '原保存已完成；下方显示家人后来更新的说明'
              : '说明已共享给家人',
        'abandoned' => '未执行的保存已停止，草稿仍保留在本机',
        _ => '尚未查到保存结果，可重试原保存或停止等待',
      });
    } catch (error) {
      if (error is StateError ||
          error is PostgrestException && error.code == '42501') {
        if (mounted) {
          setState(() {
            _state = null;
            _text.clear();
            _error = '该任务暂不可访问，请重新打开任务列表。';
          });
        }
      } else {
        _show(
          _state?.pending == true
              ? '暂未确认保存结果。原请求已保留，请核对后再继续编辑。'
              : '保存未完成，请保留草稿并重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _back() async {
    if (_busy || _localSaving) {
      _show('正在保存，请稍候再返回');
      return;
    }
    if (_localError == null || _leaving) return;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('离开说明？'),
        content: const Text('有文字尚未保存，离开后这些修改会丢失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃未保存修改'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) {
      setState(() => _leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state, pending = state?.pending ?? false;
    return PopScope(
      canPop: _leaving || !_busy && !_localSaving && _localError == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('补充说明'),
          actions: [
            IconButton(
              tooltip: '刷新说明',
              onPressed: _busy || _localSaving || _localError != null
                  ? null
                  : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: _busy && state == null
              ? const Center(child: CircularProgressIndicator())
              : _error != null || state == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error ?? '暂时无法读取说明'),
                        TextButton(
                          onPressed: _busy ? null : _load,
                          child: const Text('重新读取'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text('记录阅读书目、学习困难或需要家长帮忙的地方。共享后家人都能查看和编辑，以最后一次保存为准。'),
                    const SizedBox(height: 16),
                    if (_offline)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text('当前离线 · 可编辑本机草稿，联网后点击“共享说明”。'),
                      ),
                    if (state.current != null) ...[
                      Text(
                        '最近同步的说明',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      SelectableText(state.body.isEmpty ? '尚无说明' : state.body),
                      if (state.current!['updated_at']
                          case final String updated)
                        Text(
                          '更新于 ${DateTime.parse(updated).toLocal().toString().substring(0, 16)}',
                        ),
                      const SizedBox(height: 20),
                    ],
                    TextField(
                      controller: _text,
                      enabled: !_busy,
                      readOnly: pending,
                      minLines: 4,
                      maxLines: 10,
                      onChanged: _edit,
                      decoration: InputDecoration(
                        labelText: pending ? '等待核对的原说明' : '编辑说明',
                        alignLabelWithHint: true,
                        hintText: '例如：今天读了第三章，有一段没有理解……',
                        border: const OutlineInputBorder(),
                        errorText: _localError,
                        counterText: '${_text.text.runes.length}/500',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _localSaving
                          ? '正在保存本机草稿…'
                          : pending
                          ? '上次保存结果待核对。原内容暂时锁定，防止重复或覆盖新的说明。'
                          : state.draft != null
                          ? '草稿已保存本机，尚未共享。清空文字并共享可移除原说明。'
                          : '输入后自动保存本机草稿；点击下方按钮才会共享。',
                    ),
                    const SizedBox(height: 16),
                    if (pending)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton(
                            onPressed: _busy ? null : () => _resolve('inspect'),
                            child: const Text('核对保存结果'),
                          ),
                          OutlinedButton(
                            onPressed: _busy ? null : () => _resolve('submit'),
                            child: const Text('重试原保存'),
                          ),
                          TextButton(
                            onPressed: _busy ? null : () => _resolve('cancel'),
                            child: const Text('停止未执行的保存'),
                          ),
                        ],
                      )
                    else
                      FilledButton(
                        onPressed:
                            _busy ||
                                _localSaving ||
                                _localError != null ||
                                state.draft == null
                            ? null
                            : () => _resolve('submit'),
                        child: const Text('共享说明'),
                      ),
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator(),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}
