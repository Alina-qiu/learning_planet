import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data_management/presentation/account_deletion_screen.dart';
import '../application/family_providers.dart';
import '../data/family_creation_repository.dart';
import 'child_profile_fields.dart';
import 'app_sign_out.dart';
import 'parent_mode_prompt.dart';

class FamilyCreationScreen extends ConsumerStatefulWidget {
  const FamilyCreationScreen({this.familyId, super.key});
  final String? familyId;
  @override
  ConsumerState<FamilyCreationScreen> createState() =>
      _FamilyCreationScreenState();
}

class _FamilyCreationScreenState extends ConsumerState<FamilyCreationScreen> {
  final _form = GlobalKey<FormState>();
  final _familyName = TextEditingController();
  final _input = ChildProfileInput();
  FamilyCreationDraft? _draft;
  bool _loading = true, _busy = false;
  String? _error;
  FamilyCreationRepository get _repository =>
      ref.read(familyCreationRepositoryProvider)!;
  bool get _authorized =>
      widget.familyId == null ||
      ref.read(activeParentFamilyProvider) == widget.familyId;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final draft = await _repository.pending(widget.familyId);
      if (!mounted) return;
      setState(() {
        _draft = draft;
        if (draft != null) _fill(draft);
        _error = null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '待确认请求读取失败，请重试。');
    }
  }

  void _fill(FamilyCreationDraft draft) {
    final command = draft.command,
        preferences = draft.command['preferences'] as Map;
    _familyName.text = command['family_name'] as String? ?? '';
    _input.nickname.text = command['nickname'] as String;
    _input.grade = command['grade'] as int;
    _input.avatarKey = preferences['avatar_key'] as String;
    for (final entry in _input.textbooks.entries) {
      entry.value.text =
          (preferences['textbook_labels'] as Map)[entry.key] as String? ?? '';
    }
  }

  @override
  void dispose() {
    _familyName.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _perform(Future<void> Function() operation) async {
    if (_busy || !_authorized) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = _draft == null
              ? '提交未完成，请重试或重新打开核对：$error'
              : _draft!.status == 'created'
              ? '档案已创建，暂时无法打开，请联网刷新：$error'
              : '尚未确认结果，原请求已保留。请联网核对后继续：$error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (_busy || !_authorized || !_form.currentState!.validate()) return;
    FocusManager.instance.primaryFocus?.unfocus();
    await _perform(() async {
      final draft = await _repository.prepare(
        familyId: widget.familyId,
        familyName: _familyName.text,
        nickname: _input.nickname.text,
        grade: _input.grade,
        textbookLabels: _input.labels,
        avatarKey: _input.avatarKey,
      );
      if (!mounted) return;
      setState(() {
        _draft = draft;
        _fill(draft);
      });
      await _resolve('submit');
    });
  }

  Future<void> _resolve(String operation) async {
    final draft = _draft!;
    final result = await _repository.resolve(
      widget.familyId,
      draft.requestId,
      operation,
    );
    if (!mounted) return;
    setState(() {
      _draft = result;
      if (result.status == 'unavailable') {
        _familyName.clear();
        _input.nickname.clear();
        for (final field in _input.textbooks.values) {
          field.clear();
        }
        _input.grade = 1;
        _input.avatarKey = 'star';
      }
    });
  }

  Future<void> _retry() => _perform(() async {
    await _resolve('inspect');
    if (mounted && _authorized && _draft?.status == 'pending') {
      await _resolve('submit');
    }
  });

  Future<void> _edit() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('先核对创建结果'),
        content: const Text('尚未创建时，会取消原请求再允许修改。如果服务器已经创建成功，会保留现有档案并引导你查看。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('核对并修改'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _perform(() async {
      await _resolve('cancel');
      if (mounted && _draft?.status == 'cancelled') await _dismiss();
    });
  }

  Future<void> _dismiss() async {
    await _repository.dismiss(widget.familyId, _draft!.requestId);
    if (mounted) setState(() => _draft = null);
  }

  Future<void> _continue() => _perform(() async {
    // A confirmed receipt is retained until the family list can actually show
    // the created child. A failed refresh cannot return to an empty create form.
    final families = await ref.read(familyRepositoryProvider).loadFamilies();
    final draft = _draft!;
    if (!families.any(
      (family) =>
          family.id == draft.familyId &&
          family.children.any((child) => child.id == draft.childId),
    )) {
      await _resolve('inspect');
      if (_draft?.status == 'created') throw StateError('家庭列表暂未更新，请联网刷新');
      return;
    }
    await _repository.dismiss(widget.familyId, draft.requestId);
    if (!mounted) return;
    ref.invalidate(familiesProvider);
    if (widget.familyId != null) Navigator.pop(context, true);
  });

  @override
  Widget build(BuildContext context) {
    final authorized =
        widget.familyId == null ||
        ref.watch(activeParentFamilyProvider) == widget.familyId;
    final draft = _draft;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.familyId == null ? '创建家庭' : '添加孩子'),
        actions: [
          if (widget.familyId == null) const AppSignOutButton(),
          if (widget.familyId == null)
            IconButton(
              tooltip: '注销我的账号',
              icon: const Icon(Icons.person_remove_outlined),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => const AccountDeletionScreen(),
                ),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!authorized) ...[
                    const Text('请验证家长 PIN 后添加孩子或查看待确认请求。'),
                    FilledButton(
                      onPressed: () =>
                          enterParentMode(context, ref, widget.familyId!),
                      child: const Text('验证家长 PIN'),
                    ),
                  ] else if (_loading) ...[
                    if (_error == null)
                      const Center(child: CircularProgressIndicator()),
                    if (_error != null) Text(_error!),
                    if (_error != null)
                      FilledButton(
                        onPressed: _restore,
                        child: const Text('重新读取'),
                      ),
                  ] else ...[
                    if (draft == null)
                      Form(
                        key: _form,
                        child: Column(
                          children: [
                            if (widget.familyId == null)
                              TextFormField(
                                controller: _familyName,
                                maxLength: 80,
                                decoration: const InputDecoration(
                                  labelText: '家庭名称',
                                ),
                                validator: (value) =>
                                    value == null || value.trim().isEmpty
                                    ? '请输入家庭名称'
                                    : null,
                              ),
                            AbsorbPointer(
                              absorbing: _busy,
                              child: ChildProfileFields(input: _input),
                            ),
                            const SizedBox(height: 20),
                            FilledButton(
                              onPressed: _busy ? null : _submit,
                              child: Text(
                                _busy
                                    ? '提交中…'
                                    : widget.familyId == null
                                    ? '创建并开始'
                                    : '保存',
                              ),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      Text(switch (draft.status) {
                        'created' => '创建成功，已保留服务器回执',
                        'cancelled' => '原创建请求已取消，可以重新填写',
                        'unavailable' => '原档案已删除或你已失去访问权限，不会重新创建',
                        _ => '有一条待确认的创建请求',
                      }, style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 16),
                      if (draft.status != 'unavailable') ...[
                        if (widget.familyId == null)
                          Text('家庭：${_familyName.text}'),
                        Text('孩子：${_input.nickname.text} · ${_input.grade} 年级'),
                        for (final label in _input.labels.entries)
                          Text(
                            '${textbookSubjects[label.key]}教材：${label.value}',
                          ),
                      ],
                      const SizedBox(height: 16),
                      if (draft.status == 'pending') ...[
                        const Text('重试会继续同一次创建。离开或重启后仍可在这里恢复。'),
                        FilledButton(
                          onPressed: _busy ? null : _retry,
                          child: const Text('核对并重试'),
                        ),
                        TextButton(
                          onPressed: _busy ? null : _edit,
                          child: const Text('修改填写内容'),
                        ),
                      ],
                      if (draft.status == 'created')
                        FilledButton(
                          onPressed: _busy ? null : _continue,
                          child: const Text('查看已创建的档案'),
                        ),
                      if (draft.status == 'cancelled' ||
                          draft.status == 'unavailable')
                        FilledButton(
                          onPressed: _busy ? null : () => _perform(_dismiss),
                          child: const Text('关闭这次请求'),
                        ),
                    ],
                    if (_busy) const LinearProgressIndicator(),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(_error!),
                      ),
                    if (_error != null && widget.familyId != null)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => enterParentMode(
                                context,
                                ref,
                                widget.familyId!,
                              ),
                        child: const Text('重新验证家长 PIN'),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
