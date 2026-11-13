import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';
import '../../auth_family/application/family_providers.dart';
import '../data/worksheet_repository.dart';

abstract interface class WorksheetOutput {
  Future<bool> save(Uint8List bytes, String filename);
  Future<bool> print(Uint8List bytes, String filename);
  Future<bool> share(Uint8List bytes, String filename);
}

class NativeWorksheetOutput implements WorksheetOutput {
  @override
  Future<bool> save(Uint8List bytes, String filename) async =>
      await FilePicker.saveFile(
        fileName: filename,
        bytes: bytes,
        mimeType: 'application/pdf',
        dialogTitle: '保存原始 PDF',
      ) !=
      null;
  @override
  Future<bool> print(Uint8List bytes, String filename) => Printing.layoutPdf(
    name: filename,
    onLayout: (_) async => bytes,
    dynamicLayout: false,
  );
  @override
  Future<bool> share(Uint8List bytes, String filename) =>
      Printing.sharePdf(bytes: bytes, filename: filename);
}

final worksheetOutputProvider = Provider<WorksheetOutput>(
  (_) => NativeWorksheetOutput(),
);
final worksheetPreviewBuilderProvider = Provider<Widget Function(Uint8List)>(
  (_) =>
      (bytes) => PdfPreview(
        build: (_) async => bytes,
        canChangeOrientation: false,
        canChangePageFormat: false,
        canDebug: false,
        allowPrinting: false,
        allowSharing: false,
        useActions: false,
        dynamicLayout: false,
      ),
);

class WorksheetPdfScreen extends ConsumerStatefulWidget {
  const WorksheetPdfScreen({
    required this.id,
    required this.familyId,
    super.key,
  });
  final String id, familyId;
  @override
  ConsumerState<WorksheetPdfScreen> createState() => _WorksheetPdfScreenState();
}

class _WorksheetPdfScreenState extends ConsumerState<WorksheetPdfScreen> {
  bool _busy = false;
  Future<void> _export(Uint8List bytes, String action) async {
    if (_busy || ref.read(activeParentFamilyProvider) != widget.familyId) {
      return;
    }
    setState(() => _busy = true);
    try {
      // Recheck live authorization, expiry and source cleanup before every export.
      final current = await ref
          .read(worksheetRepositoryProvider)
          .download(widget.id);
      if (!mounted || ref.read(activeParentFamilyProvider) != widget.familyId) {
        throw StateError('PIN授权已到期');
      }
      if (!listEqualsBytes(current, bytes)) throw StateError('文件已改变，请重新打开预览');
      final output = ref.read(worksheetOutputProvider),
          filename = 'worksheet-${widget.id}.pdf';
      final success = await (action == 'save'
          ? output.save(bytes, filename)
          : action == 'print'
          ? output.print(bytes, filename)
          : output.share(bytes, filename));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(success ? '已交给系统处理原始 PDF' : '已取消')),
        );
      }
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

  @override
  Widget build(BuildContext context) {
    final authorized = ref.watch(activeParentFamilyProvider) == widget.familyId;
    return Scaffold(
      appBar: AppBar(title: const Text('A4 PDF 预览')),
      body: !authorized
          ? const Center(child: Text('家长授权已到期，请返回首页验证 PIN'))
          : ref
                .watch(worksheetBytesProvider(widget.id))
                .when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('PDF读取失败：$error'),
                        TextButton(
                          onPressed: () =>
                              ref.invalidate(worksheetBytesProvider(widget.id)),
                          child: const Text('重试下载'),
                        ),
                      ],
                    ),
                  ),
                  data: (bytes) => SafeArea(
                    top: false,
                    child: Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(8),
                          child: Text(
                            '预览、打印、保存和分享使用同一份服务端 PDF，不在设备上重新排版。导出的副本可能含答案，请谨慎分享。',
                          ),
                        ),
                        Wrap(
                          spacing: 12,
                          children: [
                            TextButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _export(bytes, 'save'),
                              icon: const Icon(Icons.download),
                              label: const Text('下载保存'),
                            ),
                            TextButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _export(bytes, 'print'),
                              icon: const Icon(Icons.print),
                              label: const Text('打印'),
                            ),
                            TextButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _export(bytes, 'share'),
                              icon: const Icon(Icons.share),
                              label: const Text('分享文件'),
                            ),
                          ],
                        ),
                        if (_busy) const Text('正在核对授权并打开系统操作…'),
                        Expanded(
                          child: ref.watch(worksheetPreviewBuilderProvider)(
                            bytes,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
    );
  }
}

bool listEqualsBytes(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}
