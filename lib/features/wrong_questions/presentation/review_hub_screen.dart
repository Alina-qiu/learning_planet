import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:uuid/uuid.dart';
import '../../auth_family/application/family_providers.dart';
import '../../auth_family/presentation/parent_mode_prompt.dart';
import '../../tasks/application/task_providers.dart';
import '../data/review_repository.dart';
import '../data/question_media_repository.dart';
import '../data/question_catalog.dart';
import 'question_ocr_screen.dart';
import 'question_detail_screen.dart';
import 'review_question_editor.dart';
import 'review_session_screen.dart';
import 'review_reminder_dialog.dart';
import '../../ai/presentation/similar_questions_screen.dart';
import 'cleanup_screen.dart';
import 'pinyin_import_screen.dart';
import 'image_drafts_screen.dart';
import 'child_question_submissions_screen.dart';
import '../../worksheets/presentation/worksheet_screen.dart';

class ReviewHubScreen extends ConsumerStatefulWidget {
  const ReviewHubScreen({
    required this.childId,
    required this.familyId,
    super.key,
  });
  final String childId, familyId;

  static Future<void> open(
    BuildContext context,
    WidgetRef ref, {
    required String childId,
    required String familyId,
  }) async {
    final firstPage = ref.listenManual(
      questionCatalogProvider(
        questionCatalogScope(child: childId, family: familyId),
      ),
      (_, _) {},
    );
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) {
            // The default tab takes over this subscription in its first frame.
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => firstPage.close(),
            );
            return ReviewHubScreen(childId: childId, familyId: familyId);
          },
        ),
      );
    } finally {
      firstPage.close();
    }
  }

  @override
  ConsumerState<ReviewHubScreen> createState() => _ReviewHubScreenState();
}

class _ReviewHubScreenState extends ConsumerState<ReviewHubScreen> {
  bool _busy = false;
  bool _catalogPainted = false;
  ModalRoute<dynamic>? _overviewRoute;
  Timer? _searchDebounce;
  @override
  void didUpdateWidget(ReviewHubScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.childId != widget.childId ||
        oldWidget.familyId != widget.familyId) {
      _catalogPainted = false;
      _searchDebounce?.cancel();
      _keyword = '';
      _subject = _mastery = _archive = 'all';
      _selected.clear();
      _dismissOverviewAfterFrame(_overviewRoute);
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  String _keyword = '', _subject = 'all', _mastery = 'all', _archive = 'all';
  final _selected = <String>{};
  Future<void> _photo() => _run(() async {
    final childInput = ref.read(activeParentFamilyProvider) != widget.familyId;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => QuestionOcrScreen(
          childInput: childInput,
          childId: widget.childId,
          familyId: widget.familyId,
        ),
      ),
    );
  });
  Future<void> _bulk(bool archive) => _run(() async {
    if (ref.read(activeParentFamilyProvider) != widget.familyId) {
      throw StateError('请先验证 PIN');
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(archive ? '批量归档' : '批量恢复'),
        content: Text('将处理已选的${_selected.length}道题。归档不删除图片及历史复习快照，也不改变掌握状态。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (ref.read(activeParentFamilyProvider) != widget.familyId) {
      throw StateError('家长授权已到期');
    }
    await ref
        .read(questionMediaRepositoryProvider)
        .archiveMany(widget.childId, _selected.toList(), archive);
    if (mounted) setState(_selected.clear);
  });
  Future<void> _cleanup() => _run(() async {
    if (ref.read(activeParentFamilyProvider) != widget.familyId) {
      throw StateError('请先验证 PIN');
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CleanupScreen(
          childId: widget.childId,
          familyId: widget.familyId,
          questionIds: _selected.toList(),
        ),
      ),
    );
    if (mounted) setState(_selected.clear);
  });
  void _refresh() {
    ref.invalidate(questionCatalogRepositoryProvider);
    ref.invalidate(reviewQuestionsProvider(widget.childId));
    ref.invalidate(reviewOverviewProvider(widget.childId));
    ref.invalidate(tasksProvider(widget.childId));
    ref.invalidate(walletProvider(widget.childId));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) _refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(
    bool pinyin, {
    String? questionId,
    bool convert = false,
  }) => _run(() async {
    final familyId = widget.familyId;
    final childId = widget.childId;
    if (ref.read(activeParentFamilyProvider) != familyId) {
      throw StateError('请先在首页验证家长 PIN');
    }
    final revision = ref.read(parentAuthorizationRevisionProvider);
    final requestId = const Uuid().v4();
    final repository = ref.read(reviewRepositoryProvider);
    final initial = questionId == null
        ? null
        : await repository.editor(questionId);
    if (!mounted) return;
    await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => Consumer(
          builder: (context, ref, _) {
            if (ref.watch(parentAuthorizationRevisionProvider) != revision) {
              return const Scaffold(
                body: Center(child: Text('登录状态已变化，请返回错题本')),
              );
            }
            final authorized =
                ref.watch(activeParentFamilyProvider) == familyId;
            return ReviewQuestionEditor(
              familyId: familyId,
              childId: childId,
              pinyin: pinyin,
              fromQuestion: convert,
              onReauthorize: authorized
                  ? null
                  : () => enterParentMode(context, ref, familyId),
              onSave: (config) async {
                if (ref.read(parentAuthorizationRevisionProvider) != revision ||
                    ref.read(activeParentFamilyProvider) != familyId) {
                  throw StateError('家长授权已到期，请重新验证');
                }
                final authorizedUntil = ref.read(parentAuthorizedUntilProvider);
                try {
                  await repository.save(
                    childId,
                    config,
                    questionId: questionId,
                    requestId: requestId,
                  );
                } on PostgrestException catch (error) {
                  if (error.code == '42501' &&
                      const {
                        'Parent authorization required or expired',
                        'Parent authorization expired',
                      }.contains(error.message) &&
                      context.mounted &&
                      ref.read(parentAuthorizationRevisionProvider) ==
                          revision &&
                      ref.read(parentFamilyIdProvider) == familyId &&
                      ref.read(parentAuthorizedUntilProvider) ==
                          authorizedUntil) {
                    ref.read(parentAuthorizedUntilProvider.notifier).state =
                        null;
                  }
                  rethrow;
                }
              },
              initial: convert
                  ? {
                      ...initial!,
                      'final_text': '',
                      'pronunciation_context': initial['final_text'],
                      'answers': <String>[],
                    }
                  : initial,
            );
          },
        ),
      ),
    );
  });
  Future<void> _practice(String taskId) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReviewSessionScreen(
          taskId: taskId,
          childId: widget.childId,
          familyId: widget.familyId,
        ),
      ),
    );
    if (mounted) _refresh();
  }

  void _dismissOverviewAfterFrame(ModalRoute<dynamic>? route) {
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) route.navigator?.removeRoute(route);
    });
  }

  Future<void> _openOverview() async {
    final child = widget.childId, family = widget.familyId;
    // An overlay may build before the underlying hub receives its new child.
    final scopeFrame = WidgetsBinding.instance.endOfFrame;
    final choice = await showModalBottomSheet<({String task, bool remind})>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final route = _overviewRoute = ModalRoute.of(sheetContext);
        return FutureBuilder<void>(
          future: scopeFrame,
          builder: (_, frame) {
            if (!mounted ||
                widget.childId != child ||
                widget.familyId != family) {
              _dismissOverviewAfterFrame(route);
              return const SizedBox.shrink();
            }
            if (frame.connectionState != ConnectionState.done) {
              return const SizedBox.shrink();
            }
            return _ReviewOverviewSheet(childId: child);
          },
        );
      },
    );
    _overviewRoute = null;
    if (choice == null ||
        !mounted ||
        widget.childId != child ||
        widget.familyId != family) {
      return;
    }
    if (!choice.remind) {
      await _practice(choice.task);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => ReviewReminderDialog(
        childId: child,
        familyId: family,
        taskId: choice.task,
      ),
    );
    if (mounted && widget.childId == child && widget.familyId == family) {
      _refresh();
    }
  }

  QuestionCatalogScope _scope(bool pinyin) => questionCatalogScope(
    child: widget.childId,
    family: widget.familyId,
    kind: pinyin ? 'pinyin' : 'question',
    subject: _subject,
    mastery: _mastery,
    archive: _archive,
    keyword: _keyword,
  );
  void _afterCatalogFrame(QuestionCatalogScope scope) {
    // The summary can refresh and write its own cache. Give the visible catalog its first frame.
    if (_catalogPainted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !_catalogPainted &&
          scope.child == widget.childId &&
          scope.family == widget.familyId) {
        setState(() => _catalogPainted = true);
      }
    });
  }

  Widget _catalogList(WidgetRef tabRef, bool pinyin, bool authorized) {
    final scope = _scope(pinyin);
    return tabRef
        .watch(questionCatalogProvider(scope))
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) {
            _afterCatalogFrame(scope);
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('错题读取失败：$error'),
                OutlinedButton(
                  onPressed: () =>
                      ref.read(questionCatalogProvider(scope).notifier).load(),
                  child: const Text('重试读取'),
                ),
              ],
            );
          },
          data: (page) {
            _afterCatalogFrame(scope);
            final header = <Widget>[
              if (!pinyin)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _photo,
                  icon: const Icon(Icons.document_scanner),
                  label: const Text('拍照 / 相册 OCR 录入'),
                ),
              if (!pinyin)
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          await Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChildQuestionSubmissionsScreen(
                                childId: widget.childId,
                                familyId: widget.familyId,
                              ),
                            ),
                          );
                        }),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('孩子提交与家长确认'),
                ),
              if (authorized)
                FilledButton.icon(
                  onPressed: _busy ? null : () => _edit(pinyin),
                  icon: const Icon(Icons.add),
                  label: Text(pinyin ? '新增拼音词语' : '手工录入错题'),
                ),
              if (authorized && pinyin)
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          await Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => PinyinImportScreen(
                                childId: widget.childId,
                                familyId: widget.familyId,
                              ),
                            ),
                          );
                        }),
                  icon: const Icon(Icons.file_upload_outlined),
                  label: const Text('导入生词库'),
                ),

              if (page.offline)
                Text(
                  '离线查看：仅包含该筛选最近同步的首批记录（最多50条）。同步时间：${page.syncedAt.toLocal().toString().split('.').first}',
                ),
              if (page.items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('暂无匹配记录，可调整筛选条件或录入新题。'),
                ),
            ];
            return ListView.builder(
              key: PageStorageKey(scope),
              padding: const EdgeInsets.all(16),
              itemCount:
                  header.length +
                  page.items.length +
                  (page.next == null ? 0 : 1),
              itemBuilder: (context, index) {
                if (index < header.length) return header[index];
                final rowIndex = index - header.length;
                if (rowIndex < page.items.length) {
                  return _questionCard(
                    page.items[rowIndex],
                    pinyin,
                    authorized,
                  );
                }
                return Column(
                  children: [
                    if (page.error != null) Text(page.error!),
                    if (page.loadingMore) const LinearProgressIndicator(),
                    OutlinedButton(
                      onPressed: page.loadingMore
                          ? null
                          : () => ref
                                .read(questionCatalogProvider(scope).notifier)
                                .load(more: true),
                      child: Text(
                        page.error == null
                            ? '继续查看（已加载${page.items.length}条）'
                            : '重试加载更多',
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
  }

  Widget _questionCard(
    Map<String, dynamic> row,
    bool pinyin,
    bool authorized,
  ) => Card(
    child: Column(
      children: [
        ListTile(
          title: Text(
            '${row['ai_generated'] == true ? '【AI生成·家长已审核】' : ''}${row['final_text']}${row['archived'] == true ? '（已归档）' : ''}',
          ),
          subtitle: Text(
            '${pinyin ? '${row['pronunciation_context']}\n' : ''}'
            '${const {'unmastered': '未掌握', 'practicing': '练习中', 'review_due': '待复习', 'mastered': '已掌握'}[row['mastery_status']] ?? row['mastery_status']}'
            ' · 错误${row['wrong_count']}次 · 复习${row['review_attempts']}次\n'
            '下次复习时点：${row['review_due_at'] ?? '无（已掌握/待配置）'}',
          ),
          onTap: _busy
              ? null
              : () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => QuestionDetailScreen(question: row),
                  ),
                ),
        ),
        if (authorized)
          Wrap(
            alignment: WrapAlignment.end,
            children: [
              Checkbox(
                semanticLabel: '选择此题',
                value: _selected.contains(row['id']),
                onChanged: _busy
                    ? null
                    : (checked) => setState(() {
                        final id = row['id'] as String;
                        if (checked == true && _selected.length < 100) {
                          _selected.add(id);
                        } else {
                          _selected.remove(id);
                        }
                      }),
              ),
              if (!pinyin)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => SimilarQuestionsScreen(
                                childId: widget.childId,
                                familyId: widget.familyId,
                                sourceId: row['id'] as String,
                              ),
                            ),
                          );
                        }),
                  child: const Text('相似题'),
                ),
              IconButton(
                tooltip: '编辑',
                icon: const Icon(Icons.edit_outlined),
                onPressed: _busy
                    ? null
                    : () => _edit(pinyin, questionId: row['id'] as String),
              ),
              if (!pinyin && row['subject'] == 'chinese')
                IconButton(
                  tooltip: '转为拼音词条',
                  icon: const Icon(Icons.spellcheck),
                  onPressed: _busy
                      ? null
                      : () => _edit(
                          true,
                          questionId: row['id'] as String,
                          convert: true,
                        ),
                ),
              IconButton(
                tooltip: row['archived'] == true ? '恢复' : '归档',
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        if (ref.read(activeParentFamilyProvider) !=
                            widget.familyId) {
                          throw StateError('家长授权已到期');
                        }
                        await ref
                            .read(reviewRepositoryProvider)
                            .archive(
                              row['id'] as String,
                              row['archived'] != true,
                            );
                      }),
                icon: Icon(
                  row['archived'] == true
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                ),
              ),
            ],
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final authorized = ref.watch(activeParentFamilyProvider) == widget.familyId;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('错题与拼音复习'),
          actions: [
            IconButton(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '错题本'),
              Tab(text: '拼音词库'),
            ],
          ),
        ),
        body: NestedScrollView(
          headerSliverBuilder: (context, innerScrolled) => [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  if (_busy) const LinearProgressIndicator(),
                  _ReviewOverviewEntry(
                    childId: widget.childId,
                    loadSummary: _catalogPainted,
                    onOpen: _busy ? null : _openOverview,
                  ),
                  if (!authorized)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('可以录入错题交给家长确认。编辑已入库题目及归档需家长验证 PIN。'),
                    ),
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => ImageDraftsScreen(
                                  childId: widget.childId,
                                  familyId: widget.familyId,
                                ),
                              ),
                            );
                          }),
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: const Text('本机图片草稿与上传'),
                  ),
                  if (authorized)
                    TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await Navigator.of(context).push<void>(
                                MaterialPageRoute(
                                  builder: (_) => WorksheetScreen(
                                    childId: widget.childId,
                                    familyId: widget.familyId,
                                    initialQuestionIds: _selected.toList(),
                                  ),
                                ),
                              );
                            }),
                      icon: const Icon(Icons.picture_as_pdf),
                      label: const Text('A4组卷与PDF'),
                    ),
                  if (authorized)
                    TextButton.icon(
                      onPressed: _busy ? null : _cleanup,
                      icon: const Icon(Icons.delete_forever),
                      label: const Text('永久清理 / 清理记录'),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      key: ValueKey((widget.familyId, widget.childId)),
                      decoration: const InputDecoration(
                        labelText: '搜索题目、知识点或语境',
                        prefixIcon: Icon(Icons.search),
                      ),
                      maxLength: 100,
                      onChanged: (v) {
                        _searchDebounce?.cancel();
                        setState(_selected.clear);
                        _searchDebounce = Timer(
                          const Duration(milliseconds: 300),
                          () {
                            if (mounted) {
                              setState(() {
                                _keyword = v;
                                _selected.clear();
                              });
                            }
                          },
                        );
                      },
                    ),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        const SizedBox(width: 16),
                        DropdownButton<String>(
                          value: _subject,
                          items: const [
                            DropdownMenuItem(value: 'all', child: Text('全部学科')),
                            DropdownMenuItem(value: 'math', child: Text('数学')),
                            DropdownMenuItem(
                              value: 'chinese',
                              child: Text('语文'),
                            ),
                            DropdownMenuItem(
                              value: 'english',
                              child: Text('英语'),
                            ),
                          ],
                          onChanged: (v) => setState(() {
                            _subject = v!;
                            _selected.clear();
                          }),
                        ),
                        const SizedBox(width: 16),
                        DropdownButton<String>(
                          value: _mastery,
                          items: const [
                            DropdownMenuItem(value: 'all', child: Text('全部状态')),
                            DropdownMenuItem(
                              value: 'unmastered',
                              child: Text('未掌握'),
                            ),
                            DropdownMenuItem(
                              value: 'practicing',
                              child: Text('练习中'),
                            ),
                            DropdownMenuItem(
                              value: 'review_due',
                              child: Text('待复习'),
                            ),
                            DropdownMenuItem(
                              value: 'mastered',
                              child: Text('已掌握'),
                            ),
                          ],
                          onChanged: (v) => setState(() {
                            _mastery = v!;
                            _selected.clear();
                          }),
                        ),
                        const SizedBox(width: 16),
                        DropdownButton<String>(
                          value: _archive,
                          items: const [
                            DropdownMenuItem(value: 'all', child: Text('全部记录')),
                            DropdownMenuItem(
                              value: 'active',
                              child: Text('未归档'),
                            ),
                            DropdownMenuItem(
                              value: 'archived',
                              child: Text('已归档'),
                            ),
                          ],
                          onChanged: (v) => setState(() {
                            _archive = v!;
                            _selected.clear();
                          }),
                        ),
                      ],
                    ),
                  ),
                  if (authorized && _selected.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      children: [
                        Text('已选 ${_selected.length}/100'),
                        TextButton(
                          onPressed: _busy ? null : () => _bulk(true),
                          child: const Text('批量归档'),
                        ),
                        TextButton(
                          onPressed: _busy ? null : () => _bulk(false),
                          child: const Text('批量恢复'),
                        ),
                        TextButton(
                          onPressed: () => setState(_selected.clear),
                          child: const Text('清空选择'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
          body: TabBarView(
            children: [
              for (final pinyin in [false, true])
                Consumer(
                  builder: (_, tabRef, _) =>
                      _catalogList(tabRef, pinyin, authorized),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReviewOverviewEntry extends ConsumerWidget {
  const _ReviewOverviewEntry({
    required this.childId,
    required this.loadSummary,
    required this.onOpen,
  });
  final String childId;
  final bool loadSummary;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = loadSummary
        ? ref.watch(reviewOverviewProvider(childId))
        : null;
    final summary =
        overview?.when(
          data: (value) =>
              '${value['offline_cache'] == true ? '离线 · ' : ''}待复习 ${value['due']} 题 · 积压 ${value['backlog']} 题',
          loading: () => '正在读取复习安排…',
          error: (_, _) => '复习安排读取失败，可查看并重试',
        ) ??
        '查看待复习题目与提醒';
    return ListTile(
      leading: const Icon(Icons.event_repeat_outlined),
      title: const Text('今日复习'),
      subtitle: Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: onOpen,
    );
  }
}

class _ReviewOverviewSheet extends ConsumerWidget {
  const _ReviewOverviewSheet({required this.childId});
  final String childId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = reviewOverviewProvider(childId);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      '今日复习',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            ref
                .watch(provider)
                .when(
                  loading: () =>
                      const LinearProgressIndicator(semanticsLabel: '正在读取复习安排'),
                  error: (error, _) => Column(
                    children: [
                      Text('复习概览读取失败：$error'),
                      OutlinedButton(
                        onPressed: () => ref.invalidate(provider),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                  data: (value) {
                    final task = value['task_id'] as String?;
                    final reminder = value['reminder'];
                    final offline = value['offline_cache'] == true;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '今日待复习 ${value['due']} 题 · 积压 ${value['backlog']} 题',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          offline
                              ? '离线缓存；已缓存题目可作答，判定与奖励联网确认'
                              : '每天最多10题；开始后题目固定，积压顺延',
                        ),
                        if (task != null) ...[
                          const SizedBox(height: 12),
                          FilledButton.tonal(
                            onPressed: () => Navigator.pop(context, (
                              task: task,
                              remind: false,
                            )),
                            child: const Text('去复习'),
                          ),
                          if (reminder is Map && reminder['allowed'] == true)
                            TextButton.icon(
                              onPressed: offline
                                  ? null
                                  : () => Navigator.pop(context, (
                                      task: task,
                                      remind: true,
                                    )),
                              icon: const Icon(Icons.snooze),
                              label: Text(
                                offline
                                    ? '联网后可设置稍后提醒'
                                    : reminder['remind_at'] == null
                                    ? '稍后提醒'
                                    : '稍后提醒 · ${reminder['remind_local']}',
                              ),
                            ),
                        ],
                      ],
                    );
                  },
                ),
          ],
        ),
      ),
    );
  }
}
