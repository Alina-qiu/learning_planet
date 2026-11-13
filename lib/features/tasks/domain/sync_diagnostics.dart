import 'task_item.dart';

/// Only known explanations may reach the UI or a diagnostic copy. Old outboxes
/// can contain raw PostgREST errors, including user content and identifiers.
String syncExplanation(Object? reason) {
  const known = {
    '离线缓存授权已过期，请联网刷新后处理',
    '操作时间不在服务端允许范围内，请联网校准',
    '前序命令缺失或操作时间顺序错误',
    '任务已跳过或过期，不能重放离线打卡',
    '另一台设备已修改任务，请采用服务端状态',
    '另一台设备已修改复习，请采用服务端状态',
    '自动复习任务需要完成题目作答，不支持普通离线打卡',
    '长期计划已经结算，请联系家长处理',
    '复习已结束或题目已清理，请采用服务端状态',
    '题目快照已改变，请重新加载复习',
    '操作时间早于上次开始时间',
    '尚未达到最低有效时长',
    '任务状态不允许此操作',
    '复习当前状态不允许此操作',
    '家庭访问权限已失效',
    '本地快照缺失，请联网采用服务端状态',
    '网络中断，将自动重试',
    '离线：操作已保存在本机，联网后自动同步',
  };
  if (known.contains(reason)) return reason as String;
  return '服务端未接受此操作，请联网核对任务状态；本机操作仍保留。';
}

class SyncOperation {
  SyncOperation.fromRow(Map<String, dynamic> row)
    : kind = (row['command'] as Map)['kind'] as String,
      at = DateTime.tryParse(
        (row['command'] as Map)['occurred_at'] as String? ?? '',
      ),
      attempts = row['attempts'] as int,
      nextAttempt = (row['next_attempt'] as int) == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row['next_attempt'] as int),
      conflict = row['state'] == 'conflict',
      explanation = row['error'] == null ? null : syncExplanation(row['error']);
  final String kind;
  final DateTime? at, nextAttempt;
  final int attempts;
  final bool conflict;
  final String? explanation;
  String get label => switch (kind) {
    'start' || 'review_start' => '开始',
    'pause' || 'review_pause' => '暂停',
    'resume' || 'review_resume' => '继续',
    'complete' || 'review_complete' => '完成',
    'abandon' => '放弃',
    'review_answer' => '提交复习答案',
    _ => '待核对操作',
  };
}

class TaskSyncGroup {
  const TaskSyncGroup({
    required this.taskId,
    required this.operations,
    this.confirmed,
  });
  final String taskId;
  final TaskItem? confirmed;
  final List<SyncOperation> operations;
  bool get conflict => operations.any((o) => o.conflict);
  bool get review => operations.any((o) => o.kind.startsWith('review_'));
  int get answers => operations.where((o) => o.kind == 'review_answer').length;
}

class SyncDiagnostics {
  const SyncDiagnostics({
    required this.owner,
    required this.childId,
    required this.groups,
    required this.otherChildOperations,
    this.confirmedAt,
    this.leaseExpiresAt,
  });
  final String owner, childId;
  final List<TaskSyncGroup> groups;
  final int otherChildOperations;
  final DateTime? confirmedAt, leaseExpiresAt;
  int get pending =>
      groups.expand((g) => g.operations).where((o) => !o.conflict).length;
  int get conflicts => groups.where((g) => g.conflict).length;
  int get answers => groups.fold(0, (sum, g) => sum + g.answers);

  /// A user can deliberately copy this summary. Never include titles, UUIDs,
  /// answer bodies, cached rows, or untrusted exception strings.
  String summary({required String phase, Map<String, int>? imageCounts}) => [
    '学习星球 · 本机同步诊断 v1',
    '范围：当前孩子 / 当前设备',
    '任务通道：${const {'synced', 'syncing', 'offline', 'conflict'}.contains(phase) ? phase : 'unknown'}',
    '待确认操作：$pending；冲突任务：$conflicts；未确认复习答案：$answers',
    '最近任务快照（UTC）：${confirmedAt?.toUtc().toIso8601String() ?? '无'}',
    if (imageCounts != null)
      for (final stage in const [
        'editing',
        'queued',
        'uploading',
        'retry',
        'blocked',
        'needs_authorization',
      ])
        '图片 $stage：${imageCounts[stage] ?? 0}',
    '计数不含题目、答案、账号、孩子姓名或标识；不代表云端全量数据。',
  ].join('\n');
}
