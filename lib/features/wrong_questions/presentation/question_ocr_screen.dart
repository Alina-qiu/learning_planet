import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../auth_family/application/family_providers.dart';
import '../data/question_media_repository.dart';
import '../data/offline_question_media_repository.dart';
import 'review_question_editor.dart';
import 'image_drafts_screen.dart';

class QuestionOcrScreen extends ConsumerStatefulWidget {
  const QuestionOcrScreen({
    required this.childId,
    required this.familyId,
    this.draftId,
    this.childInput = false,
    super.key,
  });
  final String childId, familyId;
  final String? draftId;
  final bool childInput;
  @override
  ConsumerState<QuestionOcrScreen> createState() => _QuestionOcrScreenState();
}

class _QuestionOcrScreenState extends ConsumerState<QuestionOcrScreen> {
  Uint8List? _original, _processed;
  Map<String, dynamic>? _result, _config;
  Map<String, dynamic>? _editorDraft;
  Map<String, dynamic> _importInfo = {};
  Future<void> _saving = Future.value();
  String? _persistedDraftId;
  Uint8List? _persistedProcessed;
  String _draftId = const Uuid().v4();
  int _turns = 0;
  RangeValues _horizontal = const RangeValues(0, 1),
      _vertical = const RangeValues(0, 1);
  bool _busy = false, _consent = false;
  bool _enhance = false;
  String? _error;
  bool _restoring = false;
  OfflineQuestionMediaRepository? _entryRepository;
  String? _entryOwner;
  int? _entryPrivacy;
  @override
  void initState() {
    super.initState();
    if (widget.draftId != null) {
      _draftId = widget.draftId!;
      _restoring = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _run(() async {
          final repo = ref.read(questionMediaRepositoryProvider);
          if (repo is! OfflineQuestionMediaRepository) {
            throw StateError('本机草稿不可用');
          }
          final row = await repo.draft(
            _draftId,
            widget.familyId,
            childInput: widget.childInput,
          );
          if (row['child_id'] != widget.childId || row['stage'] != 'editing') {
            throw StateError('草稿已进入上传队列');
          }
          if (!mounted) return;
          final data = row['metadata'] as Map<String, dynamic>;
          setState(() {
            _original = row['original'] as Uint8List;
            _processed = row['processed'] as Uint8List?;
            _result = data['recognition'] as Map<String, dynamic>?;
            _editorDraft = data['editor'] as Map<String, dynamic>?;
            _config = data['config'] as Map<String, dynamic>?;
            _importInfo = {
              for (final key in [
                'import_batch',
                'import_created_at',
                'import_index',
                'import_count',
              ])
                if (data.containsKey(key)) key: data[key],
            };
            _consent = data['consent'] == true;
            _turns = data['turns'] as int? ?? 0;
            _enhance = data['enhance'] == true;
            final crop = (data['crop'] as List?)?.cast<num>();
            if (crop != null) {
              _horizontal = RangeValues(crop[0].toDouble(), crop[2].toDouble());
              _vertical = RangeValues(crop[1].toDouble(), crop[3].toDouble());
            }
            _restoring = false;
            _persistedDraftId = _draftId;
            _persistedProcessed = _processed;
          });
        }),
      );
    }
  }

  Future<void> _persist() {
    if (_original == null || _restoring) return Future.value();
    try {
      _checkParent();
    } catch (error) {
      return Future.error(error);
    }
    final repo = ref.read(questionMediaRepositoryProvider);
    if (repo is! OfflineQuestionMediaRepository) return Future.value();
    final id = _draftId, original = _original, processed = _processed;
    final metadata = <String, dynamic>{
      if (widget.childInput) 'requires_parent_review': true,
      ..._importInfo,
      'recognition': _result,
      'config': _config,
      'editor': _editorDraft,
      'consent': _consent,
      'turns': _turns,
      'enhance': _enhance,
      'crop': [
        _horizontal.start,
        _vertical.start,
        _horizontal.end,
        _vertical.end,
      ],
    };
    final next = _saving.then((_) async {
      // A preceding write may finish after the account or privacy scope changed.
      // Keep this check independent of ref so already queued edits can finish
      // after leaving the page, but never move to another account.
      if (!_currentEntry(repo)) {
        throw StateError('账号或本机资料已变化，请重新打开录入页');
      }
      await repo.saveDraft(
        widget.childId,
        widget.familyId,
        id,
        metadata,
        original,
        processed,
        metadataOnly:
            _persistedDraftId == id &&
            identical(_persistedProcessed, processed),
      );
      _persistedDraftId = id;
      _persistedProcessed = processed;
    });
    _saving = next.catchError((Object error) {
      if (mounted) setState(() => _error = '本机草稿保存失败：$error');
    });
    return next;
  }

  void _persistInBackground() {
    unawaited(_persist().catchError((Object _) {}));
  }

  bool _currentEntry(QuestionMediaRepository repository) =>
      _entryRepository == null ||
      (repository is OfflineQuestionMediaRepository &&
          identical(repository, _entryRepository) &&
          repository.accountId() == _entryOwner &&
          repository.store.privacyGeneration == _entryPrivacy);

  void _checkParent() {
    final repository = ref.read(questionMediaRepositoryProvider);
    if (repository is OfflineQuestionMediaRepository) {
      if (repository.accountId() == null) throw StateError('请登录后录入错题');
      _entryRepository ??= repository;
      _entryOwner ??= repository.accountId();
      _entryPrivacy ??= repository.store.privacyGeneration;
      if (!_currentEntry(repository)) {
        throw StateError('账号或本机资料已变化，请重新打开录入页');
      }
    } else if (widget.childInput || _entryRepository != null) {
      throw StateError('本机草稿访问已变化，请重新打开录入页');
    }
    if (!widget.childInput &&
        ref.read(activeParentFamilyProvider) != widget.familyId) {
      throw StateError('家长 PIN 授权已到期，请返回首页重新验证');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _checkParent();
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick(bool camera) => _run(() async {
    final bytes = await ref.read(questionImageServiceProvider).pick(camera);
    if (bytes == null || !mounted) return;
    _checkParent();
    setState(() {
      _original = bytes;
      _processed = null;
      _result = null;
      _config = null;
      _editorDraft = null;
      _importInfo = {};
      _consent = false;
      _enhance = false;
      _draftId = const Uuid().v4();
      _turns = 0;
      _horizontal = _vertical = const RangeValues(0, 1);
    });
    await _process();
  });
  Future<void> _recover() => _run(() async {
    final repository = ref.read(questionMediaRepositoryProvider);
    if (repository is OfflineQuestionMediaRepository) {
      await _importSelection(repository, recover: true);
      return;
    }
    final files = await ref.read(questionImageServiceProvider).recover();
    if (files.isEmpty) throw StateError('没有可恢复的图片选择');
    if (files.length != 1) throw StateError('多张图片需使用本机草稿导入，请启用本机存储');
    final bytes = files.single;
    if (!mounted) return;
    _checkParent();
    setState(() {
      _original = bytes;
      _processed = null;
      _result = null;
      _config = null;
      _editorDraft = null;
      _importInfo = {};
      _consent = false;
      _enhance = false;
      _draftId = const Uuid().v4();
      _turns = 0;
      _horizontal = _vertical = const RangeValues(0, 1);
    });
    await _process();
  });

  Future<void> _importSelection(
    OfflineQuestionMediaRepository repository, {
    bool recover = false,
  }) async {
    // Finish any existing single-image draft before opening a new selection.
    await _persist();
    if (!mounted) return;
    _checkParent();
    final service = ref.read(questionImageServiceProvider);
    final ids = await repository.importImages(
      widget.childId,
      widget.familyId,
      () async {
        final images = await (recover ? service.recover() : service.pickMany());
        if (!mounted) throw StateError('已离开图片导入页面，本次未导入');
        _checkParent();
        return images;
      },
      childInput: widget.childInput,
    );
    if (ids.isEmpty) {
      if (recover) throw StateError('没有可恢复的图片选择');
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导入${ids.length}张本机草稿，请逐张校对；尚未上传。')),
    );
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ImageDraftsScreen(
          childId: widget.childId,
          familyId: widget.familyId,
        ),
      ),
    );
  }

  Future<void> _process() async {
    if (!mounted) return;
    _checkParent();
    // Preserve the original before decoding/cropping starts. Processing can
    // fail or outlive this page; neither should lose the selected image.
    await _persist();
    if (!mounted) return;
    _checkParent();
    final bytes = await ref.read(questionImageServiceProvider).process(
      _original!,
      _turns,
      [_horizontal.start, _vertical.start, _horizontal.end, _vertical.end],
      enhance: _enhance,
    );
    if (!mounted) return;
    _checkParent();
    setState(() => _processed = bytes);
    await _persist();
  }

  Future<bool> _confirmSourceChange({bool recognizing = false}) async {
    if (_editorDraft == null) return true;
    final replace = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('重新校对这张图片？'),
        content: Text(
          recognizing
              ? '重新识别成功后，将替换当前校对文字、答案和确认标记，需要重新核对。若识别失败，原校对内容仍会保留。'
              : '修改处理图会清除当前校对文字、答案和确认标记，需要按新的图片重新校对。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留校对内容'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重新校对'),
          ),
        ],
      ),
    );
    return mounted && replace == true;
  }

  void _applyImageChange(VoidCallback change) {
    setState(() {
      change();
      _processed = null;
      _result = null;
      _editorDraft = null;
    });
  }

  void _changed(VoidCallback change) {
    if (_editorDraft == null) {
      _applyImageChange(change);
      _persistInBackground();
      return;
    }
    unawaited(
      _run(() async {
        if (!await _confirmSourceChange()) return;
        _checkParent();
        _applyImageChange(change);
        await _persist();
      }),
    );
  }

  Future<void> _recognize() => _run(() async {
    if (!await _confirmSourceChange(recognizing: true)) return;
    _checkParent();
    await _process();
    if (!mounted) return;
    _checkParent();
    final result = await ref
        .read(questionImageServiceProvider)
        .recognize(_processed!);
    if (!mounted) return;
    _checkParent();
    // Only replace prior corrections after the new recognition succeeds.
    // Field confirmations belong to the old source and cannot be reused.
    setState(() {
      _result = result;
      _editorDraft = null;
    });
    await _persist();
  });
  Future<void> _save() => _run(() async {
    if (!_consent) throw StateError('请同意将图片保存至本家庭的私有错题库');
    await _process();
    if (!mounted) return;
    if (_config == null) {
      final config = await Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(
          builder: (_) => Consumer(
            builder: (context, ref, _) {
              final repository = ref.watch(questionMediaRepositoryProvider);
              final parentFamily = ref.watch(activeParentFamilyProvider);
              final current = _currentEntry(repository);
              return current &&
                      (widget.childInput || parentFamily == widget.familyId)
                  ? ReviewQuestionEditor(
                      familyId: widget.familyId,
                      childId: widget.childId,
                      pinyin: false,
                      fromImage: true,
                      childSubmission: widget.childInput,
                      ocrResult: _result,
                      originalImage: _original,
                      processedImage: _processed,
                      initial: _editorDraft,
                      onDraftChanged: (data) {
                        _editorDraft = data;
                        _persistInBackground();
                      },
                    )
                  : Scaffold(
                      appBar: AppBar(
                        title: Text(current ? '校对草稿已保留' : '请重新打开校对页'),
                      ),
                      body: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          current
                              ? '家长授权已到期，请返回并重新验证 PIN 后继续校对。'
                              : '账号或本机资料已变化，请返回并重新打开录入页。',
                        ),
                      ),
                    );
            },
          ),
        ),
      );
      if (config == null || !mounted) return;
      setState(
        () => _config = {
          ...config,
          if (widget.childInput) 'requires_parent_review': true,
        },
      );
    }
    _checkParent();
    await _persist();
    await ref
        .read(questionMediaRepositoryProvider)
        .save(
          widget.childId,
          _draftId,
          _original!,
          _processed!,
          _result,
          _config!,
        );
    if (mounted) {
      if (ref.read(questionMediaRepositoryProvider)
          is OfflineQuestionMediaRepository) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.childInput
                  ? '已保存本机，联网后提交给家长确认标准答案。确认前不会进入奖励复习。'
                  : '已保存本机，联网且家长授权有效时自动上传。可在本机草稿中查看进度。',
            ),
          ),
        );
      }
      Navigator.pop(context, true);
    }
  });
  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(questionMediaRepositoryProvider);
    final parentFamily = ref.watch(activeParentFamilyProvider);
    final current = _currentEntry(repository);
    final parent =
        current && (widget.childInput || parentFamily == widget.familyId);
    final editable = !_busy && !_restoring && parent && _config == null;
    return Scaffold(
      appBar: AppBar(title: const Text('拍照识别错题')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.childInput)
            const Text('校对后可保存给家长。标准答案经家长确认后，才会加入可获得奖励的复习。'),
          const Text('中文 OCR 在设备上运行，不向第三方识别服务发送图片。手写、公式、表格可能识别不准，请人工校对。'),
          const Text('图片及校对文字自动保存为本机草稿；勾选同意并完成校对后才加入上传队列。'),
          const Text('拍照或选图前，请避开姓名、学校、班级和人脸。'),
          if (!current)
            const Text('账号或本机资料已变化，请返回并重新打开录入页。')
          else if (!parent)
            const Text('家长授权已到期，请返回首页重新验证 PIN。'),
          if (_busy) const LinearProgressIndicator(),
          Wrap(
            spacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: editable ? () => _pick(true) : null,
                icon: const Icon(Icons.camera_alt),
                label: const Text('拍照'),
              ),
              OutlinedButton.icon(
                onPressed: editable ? () => _pick(false) : null,
                icon: const Icon(Icons.photo_library),
                label: const Text('相册'),
              ),
            ],
          ),
          if (repository is OfflineQuestionMediaRepository)
            OutlinedButton.icon(
              onPressed: editable
                  ? () => _run(() => _importSelection(repository))
                  : null,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('多图导入（每次最多10张）'),
            ),
          OutlinedButton(
            onPressed: editable ? _recover : null,
            child: const Text('恢复中断的图片选择（Android）'),
          ),
          if (_original != null && parent) ...[
            if (_importInfo['import_index'] is int &&
                _importInfo['import_count'] is int)
              Text(
                '导入图片 · 第${_importInfo['import_index']}/${_importInfo['import_count']}张',
              ),
            SizedBox(
              height: 260,
              child: InteractiveViewer(
                child: Image.memory(_processed ?? _original!),
              ),
            ),
            const Text('可旋转后调整横向、纵向裁剪范围；点击预览或识别应用裁剪。'),
            OutlinedButton(
              onPressed: editable ? () => _changed(() => _turns++) : null,
              child: const Text('顺时针旋转90°'),
            ),
            Text(
              '横向裁剪 ${(_horizontal.start * 100).round()}%–${(_horizontal.end * 100).round()}%',
            ),
            RangeSlider(
              values: _horizontal,
              divisions: 100,
              onChanged: editable
                  ? (v) => _changed(() => _horizontal = v)
                  : null,
            ),
            Text(
              '纵向裁剪 ${(_vertical.start * 100).round()}%–${(_vertical.end * 100).round()}%',
            ),
            RangeSlider(
              values: _vertical,
              divisions: 100,
              onChanged: editable ? (v) => _changed(() => _vertical = v) : null,
            ),
            OutlinedButton(
              onPressed: editable ? () => _run(_process) : null,
              child: const Text('预览处理图'),
            ),
            CheckboxListTile(
              value: _enhance,
              onChanged: editable ? (v) => _changed(() => _enhance = v!) : null,
              title: const Text('增强对比度（可选，请预览确认不影响细节）'),
            ),
            FilledButton.icon(
              onPressed: editable ? _recognize : null,
              icon: const Icon(Icons.document_scanner),
              label: const Text('设备端识别 / 重试'),
            ),
            if (_result != null) ...[
              const Text('识别完成，以下为未经校对的文字：'),
              SelectableText(_result!['text'] as String),
            ],
            const Text(
              '上传会同时保存原图。裁剪和增强只改变处理图，原图中的信息仍会保留；如含个人信息，请先遮挡后重拍，或换用已处理好的图片。',
            ),
            CheckboxListTile(
              value: _consent,
              onChanged: !_busy && parent
                  ? (v) {
                      setState(() => _consent = v!);
                      _persistInBackground();
                    }
                  : null,
              title: const Text(
                '同意将原图、处理图与识别结果保存至本家庭 Supabase 私有错题库（原图可能含拍摄元数据）',
              ),
            ),
            FilledButton(
              onPressed: !_busy && parent ? _save : null,
              child: Text(
                _config != null
                    ? '重试保存已校对的错题'
                    : _result == null
                    ? '转手工校对并保存图片'
                    : '校对、配置答案并保存',
              ),
            ),
            if (_config != null) const Text('保存失败时保留相同草稿标识，重试不重复建题；请勿关闭页面。'),
          ],
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}
