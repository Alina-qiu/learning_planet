import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/offline/network_failure.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/application/task_start_provider.dart';
import '../../tasks/domain/task_start_origin.dart';
import '../../tasks/domain/task.dart';
import '../../tasks/presentation/task_presentation.dart';
import '../../tasks/presentation/task_sync_banner.dart';
import '../data/review_repository.dart';
import '../data/question_catalog.dart';
import '../domain/review_rewards.dart';
import '../domain/review_confidence.dart';
import '../../growth/presentation/task_feedback.dart';
import '../../growth/data/feedback_preferences.dart';

class ReviewSessionScreen extends ConsumerStatefulWidget {
  const ReviewSessionScreen({
    required this.taskId,
    required this.childId,
    this.familyId,
    super.key,
  });
  final String taskId, childId;
  final String? familyId;
  @override
  ConsumerState<ReviewSessionScreen> createState() =>
      _ReviewSessionScreenState();
}

class _ReviewSessionScreenState extends ConsumerState<ReviewSessionScreen> {
  bool _busy = false;
  bool _completionShown = false;
  final _controllers = <String, TextEditingController>{};
  final _commandIds = <String, String>{};
  final _confidence = <String, ReviewConfidence>{};
  String _answerKey(String questionId) => '${widget.taskId}:$questionId';
  final _completionKey = 'review:${const Uuid().v4()}';

  void _showCompletion(ReviewRepository repository, {required bool pending}) {
    if (!mounted ||
        _completionShown ||
        !identical(repository, ref.read(reviewRepositoryProvider))) {
      return;
    }
    _completionShown = true;
    showTaskCompletionFeedback(context, ref, pending: pending, review: true);
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('复习操作失败：$error')));
      }
    } finally {
      if (mounted) {
        ref.invalidate(reviewTaskProvider(widget.taskId));
        ref.invalidate(reviewQuestionsProvider(widget.childId));
        ref.invalidate(questionCatalogRepositoryProvider);
        ref.invalidate(reviewOverviewProvider(widget.childId));
        ref.invalidate(tasksProvider(widget.childId));
        ref.invalidate(walletProvider(widget.childId));
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('自动错题与拼音复习'),
      actions: [
        IconButton(
          tooltip: '刷新复习',
          onPressed: _busy
              ? null
              : () => ref.invalidate(reviewTaskProvider(widget.taskId)),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ref
        .watch(reviewTaskProvider(widget.taskId))
        .when(
          data: (data) {
            ref.watch(feedbackPreferencesProvider);
            final task = data['task'] as Map<String, dynamic>;
            final items = (data['items'] as List).cast<Map<String, dynamic>>();
            final answered = items
                .where((item) => item['result'] != null)
                .length;
            final completed = task['status'] == 'completed';
            final pendingCompletion = data['local_completion'] == true;
            final pendingAnswers = items
                .where((item) => item['pending_answer'] != null)
                .length;
            final locallyAbandoned =
                ref
                    .watch(tasksProvider(widget.childId))
                    .valueOrNull
                    ?.any(
                      (t) =>
                          t.id == widget.taskId &&
                          t.status == TaskStatus.abandoned,
                    ) ??
                false;
            final abandoned = task['status'] == 'abandoned' || locallyAbandoned;
            final skipped =
                task['status'] == 'skipped' || task['status'] == 'expired';
            final offline = data['offline_cache'] == true;
            final unavailable =
                (offline && data['offline_enabled'] != true) ||
                data['sync_conflict'] == true;
            final active = task['status'] == 'in_progress' && !abandoned;
            return ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                16 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                if (_busy) const LinearProgressIndicator(),
                TaskSyncBanner(childId: widget.childId),
                Text(
                  '已判定 $answered / ${items.length} 题；正确 ${items.where((item) => item['result'] == true).length} 题',
                ),
                if (pendingAnswers > 0)
                  Text('本机已保存 $pendingAnswers 题，联网后由服务端判题。'),
                if (offline)
                  Text(
                    data['offline_enabled'] == true &&
                            !completed &&
                            !abandoned &&
                            !skipped
                        ? '离线缓存：作答会保存在本机，联网后自动同步。'
                        : '离线缓存：可查看题目及已提交记录，作答与结算须联网。',
                  ),
                if (pendingCompletion) const Text('完成操作已保存在本机，等待服务端判题与结算。'),
                if (task['review_auto_complete'] == true &&
                    !completed &&
                    !abandoned &&
                    !skipped)
                  const Text('提交最后一题后自动完成，奖励由服务端确认。'),
                if (abandoned)
                  const Text('这次复习已放弃，不发放完成奖励。已提交题目的判定和排期保留，未作答的题仍待复习。'),
                if (skipped) const Text('这次复习已跳过，不发放完成奖励。已提交题目的判定和排期保留。'),
                if (completed && !pendingCompletion)
                  Card(
                    child: ListTile(
                      title: const Text('复习已完成，奖励已由服务端确认'),
                      subtitle: Text(
                        '${task['coin_reward']} 金币 · ${task['xp_reward']} XP',
                      ),
                    ),
                  ),
                if (completed && !pendingCompletion)
                  const Text('超出每日软上限的金币待家长确认；已入账金额以钱包和账本为准。'),
                if (!completed &&
                    !abandoned &&
                    task['status'] != 'skipped' &&
                    task['status'] != 'expired')
                  FilledButton.tonal(
                    onPressed: _busy || unavailable
                        ? null
                        : () => _run(
                            () => task['status'] == 'paused' || active
                                ? ref
                                      .read(reviewRepositoryProvider)
                                      .transition(
                                        widget.taskId,
                                        active ? 'pause' : 'resume',
                                      )
                                : startReviewWithOrigin(
                                    ref.read(reviewRepositoryProvider),
                                    widget.taskId,
                                    ref.read(
                                      taskStartOriginProvider(widget.familyId),
                                    ),
                                  ),
                          ),
                    child: Text(
                      task['status'] == 'paused'
                          ? '继续复习'
                          : active
                          ? '暂停复习'
                          : ref.watch(
                                  taskStartOriginProvider(widget.familyId),
                                ) ==
                                TaskStartOrigin.parentAssisted
                          ? '家长代开始复习'
                          : '开始复习',
                    ),
                  ),
                if (!completed &&
                    !abandoned &&
                    task['status'] != 'skipped' &&
                    task['status'] != 'expired')
                  TextButton.icon(
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('放弃这次复习'),
                    onPressed: _busy || unavailable
                        ? null
                        : () => _run(() async {
                            if (!await confirmTaskAbandon(
                                  context,
                                  review: true,
                                ) ||
                                !mounted) {
                              return;
                            }
                            final tasks = ref.read(taskRepositoryProvider);
                            await tasks.loadTasks(widget.childId);
                            await tasks.abandon(widget.taskId);
                          }),
                  ),
                for (final item in items)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${item['sequence']}. ${item['prompt'] ?? '旧任务无题目快照'}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (item['review_kind'] == 'pinyin') ...[
                            Text('语境：${item['pronunciation_context']}'),
                            const Text('写出拼音：支持声调符号或数字声调，音节用空格分隔。'),
                          ],
                          if (item['knowledge_point'] != null)
                            Text('知识点：${item['knowledge_point']}'),
                          if (usesReviewMilestones(task))
                            Text(reviewItemReward(item)),
                          if (item['conflict_answer'] != null) ...[
                            Text('发生冲突的本机答案：${item['conflict_answer']}（尚未采用）'),
                            Text(
                              '当时的把握：${ReviewConfidence.fromWire(item['conflict_answer_confidence'])?.label ?? '未记录'}',
                            ),
                          ],
                          if (item['result'] == null &&
                              item['pending_answer'] != null) ...[
                            Text('你的答案：${item['pending_answer']}'),
                            Text(
                              '作答把握：${ReviewConfidence.fromWire(item['pending_answer_confidence'])?.label ?? '未记录'}',
                            ),
                            const Text('已保存本机 · 待服务端判定'),
                          ] else if (item['result'] == null &&
                              (completed || abandoned || skipped)) ...[
                            const Text('本题未作答'),
                          ] else if (item['result'] == null) ...[
                            TextField(
                              key: ValueKey(
                                'answer-${item['wrong_question_id']}',
                              ),
                              controller: _controllers.putIfAbsent(
                                _answerKey(item['wrong_question_id'] as String),
                                TextEditingController.new,
                              ),
                              enabled: !_busy && !unavailable && active,
                              decoration: const InputDecoration(
                                labelText: '你的答案',
                              ),
                              maxLength: 500,
                            ),
                            const Text('提交前，你有多大把握？'),
                            Wrap(
                              spacing: 8,
                              children: [
                                for (final level in ReviewConfidence.values)
                                  ChoiceChip(
                                    label: Text(level.label),
                                    selected:
                                        _confidence[_answerKey(
                                          item['wrong_question_id'] as String,
                                        )] ==
                                        level,
                                    onSelected: _busy || unavailable || !active
                                        ? null
                                        : (_) => setState(() {
                                            _confidence[_answerKey(
                                                  item['wrong_question_id']
                                                      as String,
                                                )] =
                                                level;
                                          }),
                                  ),
                              ],
                            ),
                            const Text('把握程度用于安排后续复习，不影响这次判题和奖励。'),
                            FilledButton(
                              onPressed: _busy || unavailable || !active
                                  ? null
                                  : () => _run(() async {
                                      final id =
                                          item['wrong_question_id'] as String;
                                      final answer =
                                          _controllers[_answerKey(id)]!.text
                                              .trim();
                                      if (answer.isEmpty) {
                                        throw StateError('请先填写答案');
                                      }
                                      final confidence =
                                          _confidence[_answerKey(id)];
                                      if (confidence == null) {
                                        throw StateError('请选择这次作答的把握程度');
                                      }
                                      final command = _commandIds.putIfAbsent(
                                        _answerKey(id),
                                        () => const Uuid().v4(),
                                      );
                                      final repository = ref.read(
                                        reviewRepositoryProvider,
                                      );
                                      final saved = await repository.answer(
                                        widget.taskId,
                                        id,
                                        answer,
                                        command,
                                        confidence: confidence,
                                      );
                                      if ((saved['task'] as Map)['status'] ==
                                          'completed') {
                                        _showCompletion(
                                          repository,
                                          pending:
                                              saved['local_completion'] == true,
                                        );
                                      }
                                    }),
                              child: const Text('提交答案'),
                            ),
                          ] else ...[
                            Text(
                              item['result'] == true ? '回答正确 ✓' : '回答错误，请查看解析',
                            ),
                            Text('你的答案：${item['answer_text']}'),
                            Text(
                              '作答把握：${ReviewConfidence.fromWire(item['answer_confidence'])?.label ?? '未记录'}',
                            ),
                            Text(
                              '标准答案：${(item['accepted_answers'] as List?)?.join(' / ') ?? '无'}',
                            ),
                            if ((item['explanation'] as String?)?.isNotEmpty ==
                                true)
                              Text('解析：${item['explanation']}'),
                          ],
                        ],
                      ),
                    ),
                  ),
                if (!completed &&
                    !abandoned &&
                    items.isNotEmpty &&
                    answered + pendingAnswers == items.length &&
                    (active || task['status'] == 'paused'))
                  FilledButton.icon(
                    onPressed: _busy || unavailable
                        ? null
                        : () => _run(() async {
                            final repository = ref.read(
                              reviewRepositoryProvider,
                            );
                            await repository.complete(
                              widget.taskId,
                              _completionKey,
                            );
                            _showCompletion(
                              repository,
                              pending:
                                  repository is CachedReviewRepository &&
                                  repository.tasks != null,
                            );
                          }),
                    icon: const Icon(Icons.task_alt),
                    label: const Text('完成复习并结算'),
                    style: const ButtonStyle(enableFeedback: false),
                  ),
                Text(reviewRewardRules(task)),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    isNetworkFailure(error)
                        ? '暂时无法连接服务，且本机没有可用的这次复习记录。请联网后重试。'
                        : '暂时无法读取这次复习，请返回首页刷新后重试。',
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      ref.invalidate(reviewTaskProvider(widget.taskId)),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
  );
}
