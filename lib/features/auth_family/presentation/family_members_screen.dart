import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../application/auth_providers.dart';
import '../application/family_providers.dart';
import '../data/family_members_repository.dart';
import 'parent_mode_prompt.dart';

class FamilyMembersScreen extends ConsumerStatefulWidget {
  const FamilyMembersScreen({required this.familyId, super.key});
  final String familyId;
  @override
  ConsumerState<FamilyMembersScreen> createState() =>
      _FamilyMembersScreenState();
}

class _FamilyMembersScreenState extends ConsumerState<FamilyMembersScreen> {
  final _email = TextEditingController();
  final _form = GlobalKey<FormState>();
  FamilyMembers? _members;
  FamilyInvitationRequest? _request;
  String? _error, _viewer;
  int _sequence = 0, _revision = -1;
  bool _busy = false;
  FamilyMembersRepository? get _repository =>
      ref.read(familyMembersRepositoryProvider);
  bool get _authorized =>
      ref.read(activeParentFamilyProvider) == widget.familyId &&
      !ref.read(signingOutProvider) &&
      (ref.read(parentAuthorizedUntilProvider)?.isAfter(DateTime.now()) ??
          false);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _hide() {
    _sequence++;
    _email.clear();
    setState(() {
      _members = null;
      _request = null;
      _error = null;
      _busy = false;
    });
  }

  Future<void> _run(
    Future<void> Function(FamilyMembersRepository, bool Function()) action,
  ) async {
    if (_busy || !_authorized) return;
    final repository = _repository;
    if (repository == null) return;
    final auth = ref.read(authRepositoryProvider);
    final owner = auth.currentSession?.userId;
    final revision = ref.read(parentAuthorizationRevisionProvider);
    final sequence = ++_sequence;
    bool current() =>
        mounted &&
        sequence == _sequence &&
        _authorized &&
        owner != null &&
        identical(ref.read(authRepositoryProvider), auth) &&
        auth.currentSession?.userId == owner &&
        identical(_repository, repository) &&
        ref.read(parentAuthorizationRevisionProvider) == revision;
    if (!current()) return;
    setState(() {
      _busy = true;
      _error = null;
      _viewer = owner;
      _revision = revision;
    });
    try {
      await action(repository, current);
    } catch (_) {
      if (current()) {
        setState(
          () => _error = _request?.status == 'pending'
              ? '结果尚未确认，原请求已保留。联网后可核对、重试或停止这次请求。'
              : '暂时无法读取最新结果，请联网刷新。',
        );
      }
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  Future<void> _reload() => _run((repository, current) async {
    final request = await repository.pending(widget.familyId);
    if (!current()) return;
    setState(() {
      _request = request;
      _members = null;
    });
    final members = await repository.load(widget.familyId);
    if (current()) setState(() => _members = members);
  });

  Future<void> _change(Map<String, dynamic> command, {String? displayLabel}) =>
      _run((repository, current) async {
        final request = await repository.prepare(
          widget.familyId,
          command,
          displayLabel: displayLabel,
        );
        if (!current()) return;
        setState(() {
          _request = request;
          _email.clear();
        });
        final result = await repository.resolve(
          widget.familyId,
          request.requestId,
          'submit',
        );
        if (!current()) return;
        setState(() {
          _request = result;
          _members = null;
        });
        final members = await repository.load(widget.familyId);
        if (current()) setState(() => _members = members);
      });

  Future<void> _resolve(String operation) => _run((repository, current) async {
    final request = _request;
    if (request == null) return;
    // Retrying always inspects first. A known terminal result is never resubmitted.
    var result = await repository.resolve(
      widget.familyId,
      request.requestId,
      'inspect',
    );
    if (!current()) return;
    setState(() => _request = result);
    if (result.status == 'pending' && operation != 'inspect') {
      result = await repository.resolve(
        widget.familyId,
        request.requestId,
        operation,
      );
      if (!current()) return;
      setState(() => _request = result);
    }
    final members = await repository.load(widget.familyId);
    if (current()) setState(() => _members = members);
  });

  Future<void> _dismiss() => _run((repository, current) async {
    final request = _request;
    if (request == null) return;
    await repository.dismiss(widget.familyId, request.requestId);
    if (!current()) return;
    setState(() => _request = null);
    final members = await repository.load(widget.familyId);
    if (current()) setState(() => _members = members);
  });

  Future<void> _confirm(
    FamilyInvitation invitation,
    String kind,
  ) => _confirmAction(
    kind == 'revoke' ? '撤销邀请' : '续期邀请',
    '${invitation.email}\n${kind == 'revoke' ? '撤销后，对方不能凭此邀请加入。已加入的成员不会被移除。' : '将此过期邀请延长至操作成功后的7天。'}',
    {
      'kind': kind,
      'invitation_id': invitation.id,
      'version': invitation.version,
    },
  );

  Future<void> _confirmMember(FamilyMember member) => _confirmAction(
    '移除家长',
    '${member.email}\n移除后，对方不能访问这个家庭。孩子、任务和奖励仍会保留；对方打开应用并联网后，会清理相关本机资料，离线设备无法即时清理。',
    {'kind': 'remove', 'user_id': member.userId, 'version': member.version},
    displayLabel: member.email,
  );

  Future<void> _confirmAction(
    String title,
    String description,
    Map<String, dynamic> command, {
    String? displayLabel,
  }) async {
    if (_busy || !_authorized || _request != null) return;
    final revision = ref.read(parentAuthorizationRevisionProvider),
        sequence = _sequence;
    final owner = ref.read(authRepositoryProvider).currentSession?.userId;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          ref.watch(authSessionProvider);
          final allowed =
              ref.watch(activeParentFamilyProvider) == widget.familyId &&
              ref.watch(parentAuthorizationRevisionProvider) == revision &&
              ref.watch(authRepositoryProvider).currentSession?.userId ==
                  owner &&
              _sequence == sequence &&
              !ref.watch(signingOutProvider);
          return AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
              child: Text(!allowed ? '请重新验证家长 PIN。' : description),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('返回'),
              ),
              FilledButton(
                onPressed: allowed ? () => Navigator.pop(context, true) : null,
                child: const Text('确认'),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted ||
        yes != true ||
        !_authorized ||
        _sequence != sequence ||
        ref.read(parentAuthorizationRevisionProvider) != revision ||
        ref.read(authRepositoryProvider).currentSession?.userId != owner) {
      return;
    }
    await _change(command, displayLabel: displayLabel);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeParentFamilyProvider, (_, next) {
      if (next != widget.familyId) _hide();
    });
    ref.listen(parentAuthorizationRevisionProvider, (_, _) => _hide());
    ref.listen(authSessionProvider, (_, next) {
      if (next.valueOrNull?.userId != _viewer) _hide();
    });
    final authorized =
        ref.watch(activeParentFamilyProvider) == widget.familyId &&
        !ref.watch(signingOutProvider);
    final owner = ref.watch(authRepositoryProvider).currentSession?.userId;
    final visible =
        authorized &&
        owner != null &&
        _viewer == owner &&
        _revision == ref.watch(parentAuthorizationRevisionProvider);
    final repository = ref.watch(familyMembersRepositoryProvider);
    final members = visible ? _members : null,
        request = visible ? _request : null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('家庭成员与邀请'),
        actions: [
          IconButton(
            tooltip: '刷新成员',
            onPressed: authorized && !_busy ? _reload : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: !authorized
          ? Center(
              child: FilledButton(
                onPressed: () async {
                  await enterParentMode(context, ref, widget.familyId);
                  if (mounted && _authorized) await _reload();
                },
                child: const Text('验证家长 PIN'),
              ),
            )
          : repository == null
          ? const Center(child: Text('当前环境暂不支持成员管理'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (visible && _error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(_error!),
                  ),
                if (request != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(switch (request.status) {
                            'applied' => '操作已确认，请以最新成员和邀请列表为准。',
                            'abandoned' => '这次请求已停止，不会继续执行。',
                            'already_member' => '该邮箱对应的账号已是家庭成员。',
                            'conflict' => '成员或邀请状态已变化，本次操作未执行。请刷新后重新选择。',
                            _ => '有一项成员或邀请操作待确认',
                          }),
                          const SizedBox(height: 8),
                          Text(switch (request.command['kind']) {
                            'invite' => '创建邀请：${request.command['email']}',
                            'renew' => '续期过期邀请',
                            'remove' =>
                              '移除成员：${request.displayLabel ?? '待核对的成员'}',
                            _ => '撤销邀请',
                          }),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: request.status == 'pending'
                                ? [
                                    FilledButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _resolve('inspect'),
                                      child: const Text('核对结果'),
                                    ),
                                    OutlinedButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _resolve('submit'),
                                      child: const Text('重试原请求'),
                                    ),
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _resolve('cancel'),
                                      child: const Text('停止这次请求'),
                                    ),
                                  ]
                                : [
                                    FilledButton(
                                      onPressed: _busy ? null : _dismiss,
                                      child: const Text('继续'),
                                    ),
                                  ],
                          ),
                          if (request.status == 'pending')
                            const Text('停止只会取消尚未执行的请求；已完成的操作会返回原结果。'),
                        ],
                      ),
                    ),
                  ),
                if (members != null) ...[
                  Text(
                    '家庭成员（${members.members.length}）',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  for (final member in members.members)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              member.email,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text(
                              '${member.isOwner ? '家庭创建者 · ' : ''}${member.role == 'admin' ? '管理员' : '普通家长'}${member.isSelf ? ' · 我' : ''}',
                            ),
                            if (members.canManage &&
                                member.canRemove &&
                                member.version > 0 &&
                                !member.isSelf &&
                                !member.isOwner &&
                                member.role == 'parent')
                              TextButton(
                                onPressed: _busy || request != null
                                    ? null
                                    : () => _confirmMember(member),
                                child: const Text('移除家长'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (!members.canManage)
                    const Text('邀请由家庭管理员管理。其他成员的邮箱已作隐藏处理。'),
                  if (members.canManage) ...[
                    Text('邀请家长', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    const Text('邀请有效期7天，对方使用此邮箱登录后自动加入。本页不会发送邮件，请自行告知对方。'),
                    const SizedBox(height: 12),
                    Form(
                      key: _form,
                      child: TextFormField(
                        controller: _email,
                        enabled: !_busy && request == null,
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: '家长邮箱',
                          errorMaxLines: 2,
                        ),
                        validator: (value) =>
                            (value ?? '').trim().length <= 254 &&
                                RegExp(
                                  r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                                ).hasMatch((value ?? '').trim())
                            ? null
                            : '请输入有效邮箱',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: _busy || request != null
                            ? null
                            : () {
                                if (_form.currentState!.validate()) {
                                  FocusManager.instance.primaryFocus?.unfocus();
                                  _change({
                                    'kind': 'invite',
                                    'email': _email.text.trim().toLowerCase(),
                                  });
                                }
                              },
                        icon: const Icon(Icons.person_add_alt_1),
                        label: const Text('创建邀请'),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '待加入的邀请（${members.invitations.length}）',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (members.invitations.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('暂无待加入的邀请'),
                      ),
                    for (final invitation in members.invitations)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                invitation.email,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                '${invitation.expired ? '已过期' : '待加入'} · ${DateFormat('yyyy-MM-dd HH:mm').format(invitation.expiresAt.toLocal())}到期（本机时间）',
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if (invitation.expired)
                                    OutlinedButton(
                                      onPressed: _busy || request != null
                                          ? null
                                          : () => _confirm(invitation, 'renew'),
                                      child: const Text('续期7天'),
                                    ),
                                  TextButton(
                                    onPressed: _busy || request != null
                                        ? null
                                        : () => _confirm(invitation, 'revoke'),
                                    child: const Text('撤销邀请'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ] else if (!_busy && request == null)
                  OutlinedButton(
                    onPressed: _reload,
                    child: const Text('重新加载成员'),
                  ),
              ],
            ),
    );
  }
}
