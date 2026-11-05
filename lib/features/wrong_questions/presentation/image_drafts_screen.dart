import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/application/family_providers.dart';
import '../../auth_family/presentation/parent_mode_prompt.dart';
import '../data/question_media_repository.dart';
import '../data/offline_question_media_repository.dart';
import 'question_ocr_screen.dart';

class ImageDraftsScreen extends ConsumerStatefulWidget {
  const ImageDraftsScreen({
    required this.childId,
    required this.familyId,
    super.key,
  });
  final String childId, familyId;
  @override
  ConsumerState<ImageDraftsScreen> createState() => _ImageDraftsScreenState();
}

class _ImageDraftsScreenState extends ConsumerState<ImageDraftsScreen> {
  bool _busy = false;
  Future<void> _import(
    OfflineQuestionMediaRepository repo, {
    bool recover = false,
  }) => _run(() async {
    final service = ref.read(questionImageServiceProvider);
    final childInput = ref.read(activeParentFamilyProvider) != widget.familyId;
    final ids = await repo.importImages(
      widget.childId,
      widget.familyId,
      () async {
        final images = await (recover ? service.recover() : service.pickMany());
        if (!mounted) throw StateError('已离开图片导入页面，本次未导入');
        if (!childInput &&
            ref.read(activeParentFamilyProvider) != widget.familyId) {
          throw StateError('家长授权已到期，本次未导入');
        }
        return images;
      },
      childInput: childInput,
    );
    if (ids.isEmpty && recover) throw StateError('没有可恢复的图片选择');
    if (ids.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入${ids.length}张本机草稿，请逐张校对；尚未上传。')),
      );
    }
  });
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('草稿操作失败：$error')));
      }
    } finally {
      if (mounted) {
        ref.invalidate(
          imageDraftsProvider((child: widget.childId, family: widget.familyId)),
        );
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final parent = ref.watch(activeParentFamilyProvider) == widget.familyId;
    final repo = ref.watch(questionMediaRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('本机图片草稿与上传')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '草稿仅保存在本机。孩子校对并同意上传后，联网时提交给家长确认；家长模式录入需授权有效才能上传。上传确认后清除本机图片和答案副本。',
          ),
          if (repo is OfflineQuestionMediaRepository)
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await enterParentMode(context, ref, widget.familyId);
                      if (ref.read(activeParentFamilyProvider) ==
                          widget.familyId) {
                        await repo.synchronize(
                          retryBlocked: true,
                          childId: widget.childId,
                        );
                      }
                    }),
              child: Text(parent ? '重新验证家长 PIN' : '验证家长 PIN 并继续'),
            ),
          if (repo is OfflineQuestionMediaRepository) ...[
            if (_busy) const LinearProgressIndicator(),
            const Text('可一次导入最多10张JPEG/PNG，每张不超过10MB。每张分别裁剪、识别和校对后再上传。'),
            const Text('选择前请检查姓名、学校、班级和人脸。后续同意上传时会保存原图，单独裁剪处理图不会移除原图中的信息。'),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _import(repo),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('多图导入（每次最多10张）'),
            ),
            TextButton(
              onPressed: _busy ? null : () => _import(repo, recover: true),
              child: const Text('恢复中断的图片选择（Android）'),
            ),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                      () => repo.synchronize(
                        retryBlocked: true,
                        childId: widget.childId,
                      ),
                    ),
              child: const Text('立即重试上传'),
            ),
            ref
                .watch(
                  imageDraftsProvider((
                    child: widget.childId,
                    family: widget.familyId,
                  )),
                )
                .when(
                  loading: () => const LinearProgressIndicator(),
                  error: (error, _) => Text('读取失败：$error'),
                  data: (rows) => Column(
                    children: [
                      if (rows.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('没有待处理的本机草稿'),
                        ),
                      for (final row in rows.where(
                        (row) => parent || row['requires_parent_review'] == 1,
                      ))
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (row['import_index'] is int &&
                                    row['import_count'] is int)
                                  Text(
                                    '批量导入 · 第${row['import_index']}/${row['import_count']}张',
                                  ),
                                Text(switch (row['stage']) {
                                  'editing' => '待校对 · 尚未加入上传队列',
                                  'uploading' => '正在上传',
                                  'needs_authorization' =>
                                    row['requires_parent_review'] == 1
                                        ? '请确认登录和家庭权限后重试'
                                        : '待重新验证家长授权',
                                  'blocked' => '上传未被接受',
                                  _ => '已保存本机 · 等待上传',
                                }),
                                if (row['requires_parent_review'] == 1)
                                  const Text('提交给家长确认标准答案，确认前不参与奖励复习'),
                                if (row['error'] != null)
                                  Text(row['error'] as String),
                                Text(
                                  '本机保存时间：${DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int).toLocal().toString().split('.').first}',
                                ),
                                Wrap(
                                  spacing: 12,
                                  children: [
                                    if (row['stage'] == 'editing')
                                      TextButton(
                                        onPressed: _busy
                                            ? null
                                            : () => _run(() async {
                                                await Navigator.of(
                                                  context,
                                                ).push(
                                                  MaterialPageRoute<void>(
                                                    builder: (_) =>
                                                        QuestionOcrScreen(
                                                          childInput:
                                                              row['requires_parent_review'] ==
                                                              1,
                                                          childId:
                                                              widget.childId,
                                                          familyId:
                                                              widget.familyId,
                                                          draftId:
                                                              row['draft_id']
                                                                  as String,
                                                        ),
                                                  ),
                                                );
                                              }),
                                        child: const Text('继续校对'),
                                      ),
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _run(() async {
                                              final yes = await showDialog<bool>(
                                                context: context,
                                                builder: (context) => AlertDialog(
                                                  title: const Text('删除本机草稿？'),
                                                  content: const Text(
                                                    '将清除本机图片、校对文字和待上传操作。已发出的网络请求可能已在云端保存；本操作不删除云端记录，请在错题本的永久清理中处理。',
                                                  ),
                                                  actions: [
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                            context,
                                                            false,
                                                          ),
                                                      child: const Text('取消'),
                                                    ),
                                                    FilledButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                            context,
                                                            true,
                                                          ),
                                                      child: const Text(
                                                        '删除本机草稿',
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              );
                                              if (yes == true) {
                                                await repo.discard(
                                                  row['draft_id'] as String,
                                                  widget.familyId,
                                                  childInput:
                                                      row['requires_parent_review'] ==
                                                      1,
                                                );
                                              }
                                            }),
                                      child: const Text('删除本机草稿'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
          ],
        ],
      ),
    );
  }
}
