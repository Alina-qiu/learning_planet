import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../../auth_family/application/family_providers.dart';
import '../data/child_export_repository.dart';
import '../domain/child_export.dart';

abstract interface class ChildExportOutput {
  Future<bool> save(Uint8List bytes, String filename);
}

class NativeChildExportOutput implements ChildExportOutput {
  NativeChildExportOutput({
    Future<bool> Function(Uint8List bytes, String filename)? saveFile,
  }) : _saveFile = saveFile ?? _saveNative;
  final Future<bool> Function(Uint8List bytes, String filename) _saveFile;
  static const _temporaryFiles = MethodChannel(
    'learning_planet/export_temporary_files',
  );
  static bool _saving = false;

  static Future<bool> _saveNative(Uint8List bytes, String filename) async =>
      await FilePicker.saveFile(
        dialogTitle: '保存孩子数据导出',
        fileName: filename,
        bytes: bytes,
        mimeType: 'application/zip',
      ) !=
      null;

  @override
  Future<bool> save(Uint8List bytes, String filename) async {
    if (_saving) throw StateError('已有文件正在保存，请先完成系统保存流程');
    _saving = true;
    final ios = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    try {
      // file_picker 13 iOS stages exports in NSTemporaryDirectory. The native
      // channel removes only our strictly named ZIPs, never unrelated imports.
      if (ios) await _temporaryFiles.invokeMethod<void>('purge');
      try {
        return await _saveFile(bytes, filename);
      } finally {
        if (ios) {
          try {
            await _temporaryFiles.invokeMethod<void>('purge');
          } catch (_) {
            throw StateError('系统保存流程已结束，但临时副本清理失败；请重启应用重试清理');
          }
        }
      }
    } finally {
      _saving = false;
    }
  }
}

final childExportOutputProvider = Provider<ChildExportOutput>(
  (_) => NativeChildExportOutput(),
);

class ChildExportScreen extends ConsumerStatefulWidget {
  const ChildExportScreen({
    required this.childId,
    required this.familyId,
    required this.nickname,
    super.key,
  });
  final String childId, familyId, nickname;
  @override
  ConsumerState<ChildExportScreen> createState() => _ChildExportScreenState();
}

class _ChildExportScreenState extends ConsumerState<ChildExportScreen> {
  bool _busy = false, _cancelled = false;
  String? _status;
  double? _progress;
  ExportScope get _scope =>
      (childId: widget.childId, familyId: widget.familyId);
  void _checkAccess() {
    if (!mounted || _cancelled) throw StateError('已取消导出');
    if (ref.read(activeParentFamilyProvider) != widget.familyId) {
      throw StateError('家长授权已到期，请重新验证 PIN');
    }
  }

  Future<void> _export(Map<String, dynamic> preview) async {
    if (_busy) return;
    var phrase = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('导出${widget.nickname}的数据'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '文件含孩子信息、标准答案和操作记录。仅包含已同步数据及图片索引，不包含图片文件。保存的副本不能由应用远程删除。',
              ),
              TextField(
                onChanged: (value) => phrase = value,
                decoration: const InputDecoration(labelText: '输入“导出孩子数据”确认'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (phrase == '导出孩子数据') Navigator.pop(context, true);
            },
            child: const Text('确认导出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _cancelled = false;
      _status = '正在建立数据快照…';
      _progress = null;
    });
    final repository = ref.read(childExportRepositoryProvider);
    final output = ref.read(childExportOutputProvider);
    final id = const Uuid().v4();
    try {
      _checkAccess();
      final manifest = await repository.prepare(
        widget.childId,
        id,
        Map<String, dynamic>.from(preview['counts'] as Map),
      );
      _checkAccess();
      if (manifest['id'] != id ||
          manifest['child_id'] != widget.childId ||
          manifest['family_id'] != widget.familyId ||
          manifest['schema_version'] != 1) {
        throw const FormatException('导出范围与所选孩子不一致');
      }
      final data = await collectChildExport(
        repository,
        manifest,
        checkAccess: _checkAccess,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _progress = total == 0 ? 1 : done / total;
              _status = '已读取 $done / $total 条记录';
            });
          }
        },
      );
      _checkAccess();
      setState(() {
        _status = '正在打包 CSV 与图片索引…';
        _progress = null;
      });
      final bytes = await compute(buildChildExportZip, data);
      _checkAccess();
      // Closing, PIN expiry, role changes or source cleanup invalidate the job.
      final current = await repository.manifest(id);
      _checkAccess();
      if (current['id'] != id || current['child_id'] != widget.childId) {
        throw const FormatException('导出快照已变化');
      }
      setState(() => _status = '请选择保存位置');
      final saved = await output.save(
        bytes,
        'learning-planet-${widget.childId}-$id.zip',
      );
      if (mounted) {
        setState(
          () => _status = saved ? '已交给系统保存 ZIP。请妥善保管导出文件。' : '已取消保存，未保留导出文件。',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _status = '导出未完成：$error');
    } finally {
      // Best effort even after PIN expiry; Cron removes abandoned server rows.
      // Native output also cleans the iOS file picker's temporary staging ZIP.
      try {
        await repository.close(id);
      } catch (_) {
        if (mounted) {
          setState(
            () => _status =
                '${_status ?? ''}\n临时快照关闭未确认；15分钟后不可读取，后台清理将在任务恢复后执行。',
          );
        }
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
        ref.invalidate(childExportPreviewProvider(_scope));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final parent = ref.watch(activeParentFamilyProvider) == widget.familyId;
    return Scaffold(
      appBar: AppBar(title: const Text('导出孩子数据')),
      body: !parent
          ? const Center(child: Text('家长授权已到期，请返回首页验证 PIN'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  widget.nickname,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const Text(
                  '仅家庭管理员可导出。请先同步离线记录。文件包括 CSV、原始 JSON 和图片索引，不含图片或 PDF 文件、签名链接和登录凭证。',
                ),
                const SizedBox(height: 12),
                if (_status != null)
                  Text(_status!, key: const Key('export-status')),
                if (_busy) ...[
                  LinearProgressIndicator(
                    value: _progress,
                    semanticsLabel: '读取导出记录进度',
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _cancelled = true;
                      _status = '正在取消导出…';
                    }),
                    child: const Text('取消导出'),
                  ),
                ] else
                  ref
                      .watch(childExportPreviewProvider(_scope))
                      .when(
                        loading: () => const LinearProgressIndicator(),
                        error: (error, _) => Column(
                          children: [
                            Text('范围预览失败：$error'),
                            TextButton(
                              onPressed: () => ref.invalidate(
                                childExportPreviewProvider(_scope),
                              ),
                              child: const Text('刷新范围'),
                            ),
                          ],
                        ),
                        data: (preview) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final entry
                                in (preview['counts'] as Map<String, dynamic>)
                                    .entries)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  exportSectionLabels[entry.key] ?? entry.key,
                                ),
                                trailing: Text('${entry.value} 条'),
                              ),
                            const Text(
                              '包含该孩子的归档错题、已提交待家长确认的错题及家庭共享奖励目录；其他成员未提交的OCR草稿除外。临时快照最多可读取15分钟；PIN授权过期时需重新验证。',
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: () => _export(preview),
                              icon: const Icon(Icons.download),
                              label: const Text('生成并保存 ZIP'),
                            ),
                          ],
                        ),
                      ),
              ],
            ),
    );
  }
}
