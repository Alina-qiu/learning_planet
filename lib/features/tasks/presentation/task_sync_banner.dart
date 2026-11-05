import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/task_providers.dart';
import '../data/offline_task_repository.dart';
import '../domain/task_sync_state.dart';
import '../domain/sync_diagnostics.dart';
import 'sync_center_screen.dart';

class TaskSyncBanner extends ConsumerWidget {
  const TaskSyncBanner({required this.childId, super.key});
  final String childId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(taskRepositoryProvider);
    if (repository is! OfflineTaskRepository) return const SizedBox.shrink();
    final state =
        ref.watch(taskSyncStateProvider).valueOrNull ?? repository.state;
    final label = switch (state.phase) {
      TaskSyncPhase.synced => state.pending == 0 ? '已同步' : '操作已保存本机 · 待同步',
      TaskSyncPhase.syncing => '同步中 · 操作已保存本机',
      TaskSyncPhase.offline => '离线 · 联网后自动同步',
      TaskSyncPhase.conflict => '存在同步冲突 · 请处理',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$label${state.pending == 0 ? '' : ' · 本账号${state.pending}项待同步'}',
            ),
            const Text('钱包仅显示服务端已确认余额；离线完成不会提前发奖。'),
            if (state.message != null) Text(syncExplanation(state.message)),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: state.phase == TaskSyncPhase.syncing
                      ? null
                      : () async {
                          try {
                            await repository.synchronize(childId);
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('暂时无法同步，请在同步中心查看处理方式'),
                                ),
                              );
                            }
                          }
                        },
                  child: const Text('立即同步'),
                ),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => SyncCenterScreen(childId: childId),
                    ),
                  ),
                  child: const Text('同步中心'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
