import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../auth_family/presentation/app_sign_out.dart';
import '../../auth_family/application/family_providers.dart';
import '../../tasks/data/notification_scheduler.dart';
import '../data/account_deletion_repository.dart';

class AccountDeletionScreen extends ConsumerStatefulWidget {
  const AccountDeletionScreen({super.key, this.initialStatus});
  final Map<String, dynamic>? initialStatus;
  @override
  ConsumerState<AccountDeletionScreen> createState() =>
      _AccountDeletionScreenState();
}

class _AccountDeletionScreenState extends ConsumerState<AccountDeletionScreen> {
  List<Map<String, dynamic>>? _families;
  Map<String, dynamic>? _preview, _submittedScope, _status;
  String? _requestId, _error;
  String _confirmation = '';
  bool _busy = false;
  AccountDeletionRepository get repo =>
      ref.read(accountDeletionRepositoryProvider)!;
  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus;
    if (_status == null) Future.microtask(() => _run(_load));
  }

  @override
  void didUpdateWidget(AccountDeletionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialStatus != null) _status = widget.initialStatus;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    final status = await repo.status();
    if (!mounted) return;
    if (status != null) {
      setState(() => _status = status);
      ref.invalidate(accountDeletionStatusProvider);
      return;
    }
    final families = await repo.context();
    if (mounted) setState(() => _families = families);
  }

  bool _authorized(Map<String, dynamic> family, DateTime now) =>
      family['authorized'] == true &&
      (DateTime.tryParse(
            family['authorized_until'] as String? ?? '',
          )?.isAfter(now) ??
          false);

  Future<void> _verify(Map<String, dynamic> family) async {
    var input = '';
    final pin = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('验证 ${family['name']} 的家长 PIN'),
        content: TextField(
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(labelText: '家长 PIN'),
          onChanged: (value) => input = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input),
            child: const Text('验证'),
          ),
        ],
      ),
    );
    if (pin == null || !mounted) return;
    await _run(() async {
      final result = await ref
          .read(familyRepositoryProvider)
          .verifyParentPin(familyId: family['id'] as String, pin: pin);
      if (!result.verified) {
        throw StateError('PIN 未通过，剩余 ${result.remainingAttempts} 次；锁定后请稍后重试');
      }
      final families = await repo.context();
      if (mounted) {
        setState(() {
          _families = families;
          _preview = null;
        });
      }
    });
  }

  Future<void> _previewScope() async {
    final preview = await repo.preview();
    if (mounted) {
      setState(() {
        _preview = preview;
        _requestId = null;
        _submittedScope = null;
        _confirmation = '';
      });
    }
  }

  Future<void> _request() async {
    _submittedScope ??= Map<String, dynamic>.from(_preview!['scope'] as Map);
    _requestId ??= const Uuid().v4();
    try {
      await repo.request(_requestId!, _submittedScope!);
    } on PostgrestException catch (error) {
      if (error.code == '40001') {
        _requestId = null;
        _submittedScope = null;
        _preview = null;
        _confirmation = '';
      }
      rethrow;
    }
    if (!mounted) return;
    setState(() {
      _status = {'id': _requestId, 'status': 'queued', 'phase': 'files'};
      _preview = null;
      _submittedScope = null;
      _families = null;
    });
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    ref.invalidate(accountDeletionStatusProvider);
    await ref.read(notificationSchedulerProvider).setScope(null);
  }

  Future<void> _refresh({bool retry = false}) async {
    if (retry) await repo.retry();
    final status = await repo.status();
    if (mounted && status != null) setState(() => _status = status);
    ref.invalidate(accountDeletionStatusProvider);
  }

  @override
  Widget build(BuildContext context) {
    final now =
        ref.watch(authorizationClockProvider).valueOrNull ?? DateTime.now();
    final authorized =
        _families != null &&
        _families!.every((family) => _authorized(family, now));
    final scope = _preview?['scope'] as Map?;
    final status = _status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('注销我的账号'),
        automaticallyImplyLeading: status == null,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('操作未确认：$_error'),
            ),
          if (status != null) ...[
            Text(switch (status['status']) {
              'completed' => '账号注销已完成',
              'failed' => '清理未完成，系统将继续重试',
              'unknown' => '已受理注销，暂时无法确认最新进度',
              _ => '注销已受理，正在清理',
            }, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            const Text('账号已停止读写学习数据。关闭应用或退出登录不会取消注销。只有文件和登录账号均确认删除后，才显示完成。'),
            Text('申请编号：${status['id']}'),
            if (status['phase'] == 'auth') const Text('图片和 PDF 已清理，正在删除登录账号。'),
            if (status['target_at'] != null)
              Text(
                '预计完成时间：${DateTime.parse(status['target_at'] as String).toLocal()}',
              ),
            if (status['target_at'] != null &&
                status['status'] != 'completed' &&
                DateTime.parse(status['target_at'] as String).isBefore(now))
              const Text('已超过预计完成时间，清理仍未完成，请联系应用支持并提供申请编号。'),
            if (status['error_code'] != null)
              Text(_failureLabel(status['error_code'] as String)),
            Wrap(
              spacing: 12,
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : () => _run(() => _refresh()),
                  child: const Text('查询最新状态'),
                ),
                if (status['status'] != 'completed')
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() => _refresh(retry: true)),
                    child: const Text('重试处理'),
                  ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() => signOutOfApp(context, ref)),
                  child: const Text('退出登录'),
                ),
              ],
            ),
          ] else ...[
            const Text('请先导出需要保留的数据。注销不可恢复，且会丢弃本机尚未同步的操作。'),
            const SizedBox(height: 12),
            const Text(
              '本人创建的家庭：删除所有孩子、任务、错题、余额、奖励和家庭成员关系。其他家长的登录账号保留。\n加入的其他家庭：退出家庭，删除本人上传的图片、OCR 来源和 PDF；保留家庭的学习记录，解除记录与本人账号的关联。',
            ),
            const SizedBox(height: 12),
            const Text(
              '文件清理至少等待 10 分钟，并等待已在生成的 PDF 进程结束。预计 24 小时内完成；异常会持续重试并显示状态。注销记录保留 30 天。已保存到其他位置的导出文件需自行删除。',
            ),
            for (final family in _families ?? <Map<String, dynamic>>[])
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(family['name'] as String),
                subtitle: Text(
                  family['owned'] == true ? '将解散并删除所有孩子数据' : '退出并保留家庭学习记录',
                ),
                trailing: TextButton(
                  onPressed: _busy ? null : () => _verify(family),
                  child: Text(_authorized(family, now) ? 'PIN 已验证' : '验证 PIN'),
                ),
              ),
            OutlinedButton(
              onPressed: _busy ? null : () => _run(_load),
              child: const Text('刷新家庭与注销状态'),
            ),
            FilledButton(
              onPressed: _busy || !authorized
                  ? null
                  : () => _run(_previewScope),
              child: const Text('预览注销范围'),
            ),
            if (!authorized && _families != null)
              const Text('请验证每个家庭的家长 PIN；授权到期后需重新验证。'),
            if (scope != null && authorized) ...[
              const Divider(),
              Text(
                '将解散 ${(scope['owned_family_ids'] as List).length} 个家庭，删除 ${(scope['child_ids'] as List).length} 个孩子，共 ${scope['files']} 个文件。',
              ),
              for (final child in scope['children'] as List)
                Text(
                  '${child['nickname']}：${(child['counts'] as Map).entries.map((entry) => '${_countLabel(entry.key as String)} ${entry.value}').join('，')}',
                ),
              Text(
                '其他家庭：删除本人 ${scope['shared_uploads']} 份 OCR 来源、${scope['shared_worksheets']} 份 PDF。',
              ),
              TextField(
                key: ValueKey(_preview),
                onChanged: (value) => setState(() => _confirmation = value),
                decoration: const InputDecoration(labelText: '输入“永久注销我的账号”确认'),
              ),
              FilledButton(
                onPressed: _busy || _confirmation != '永久注销我的账号'
                    ? null
                    : () => _run(_request),
                child: Text(_requestId == null ? '永久注销我的账号' : '重试同一注销申请'),
              ),
              if (_requestId != null)
                const Text('上次结果未确认。查询状态或重试会沿用同一申请，不会重复删除。'),
            ],
          ],
        ],
      ),
    );
  }

  String _countLabel(String key) =>
      const {
        'tasks': '任务',
        'templates': '模板',
        'questions': '错题',
        'ocr_drafts': 'OCR 来源',
        'worksheets': 'PDF',
        'redemptions': '兑换',
        'ledger_entries': '账本',
        'coins': '金币',
        'frozen_coins': '冻结金币',
        'xp': '经验',
        'files': '文件',
      }[key] ??
      key;

  String _failureLabel(String code) =>
      const {
        'WAITING_FILE_JOBS': '正在等待相关孩子的文件清理完成。',
        'STORAGE_REMOVE_FAILED': '文件服务暂时不可用，将自动重试删除。',
        'STORAGE_VERIFY_FAILED': '尚未确认所有文件均已删除，将继续核查。',
        'AUTH_DELETE_FAILED': '登录账号暂未删除，将自动重试。',
      }[code] ??
      '清理尚未完成，系统将继续重试；如超过预计时间，请提供申请编号联系支持。';
}
