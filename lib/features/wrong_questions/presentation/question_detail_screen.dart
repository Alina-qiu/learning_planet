import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/question_media_repository.dart';
import '../domain/error_reason.dart';
import '../domain/ocr_fields.dart';

class QuestionDetailScreen extends ConsumerWidget {
  const QuestionDetailScreen({required this.question, super.key});
  final Map<String, dynamic> question;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('错题详情')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (question['ai_generated'] == true)
          const Text('来源：AI生成，家长已审核；后续编辑仍保留此来源标记。'),
        SelectableText(question['final_text'] as String),
        Text(
          '学科：${question['subject']} · 知识点：${question['knowledge_point'] ?? '未设置'}',
        ),
        Text(
          '错误次数：${question['wrong_count']} · 复习次数：${question['review_attempts']}',
        ),
        Text(
          '掌握状态：${question['mastery_status']} · 下次复习：${question['review_due_at'] ?? '无'}',
        ),
        Text(
          '错误原因标签：${questionErrorReasons(question).isEmpty ? '未设置' : questionErrorReasons(question).map((key) => errorReasonLabels[key]).join('、')}',
        ),
        if ((question['error_reason'] as String? ?? '').trim().isNotEmpty)
          Text('错误原因备注：${question['error_reason']}'),
        if (question['review_kind'] == 'pinyin')
          Text('语境：${question['pronunciation_context']}'),
        ref
            .watch(questionProvenanceProvider(question['id'] as String))
            .when(
              data: (draft) => draft == null
                  ? Text(
                      question['ai_generated'] == true
                          ? '本题无关联图片'
                          : '来源：手工录入（无关联图片）',
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('图片来源（双指可缩放）'),
                        for (final field in [
                          'original_path',
                          'processed_path',
                        ]) ...[
                          Text(field == 'original_path' ? '原图' : '处理图'),
                          if (field == 'original_path' &&
                              draft['original_deleted_at'] != null)
                            const Text('原图已永久清理，无法恢复')
                          else
                            ref
                                .watch(
                                  questionImageUrlProvider(
                                    draft[field] as String,
                                  ),
                                )
                                .when(
                                  data: (url) => SizedBox(
                                    height: 280,
                                    child: InteractiveViewer(
                                      child: Image.network(
                                        url,
                                        errorBuilder: (_, _, _) => const Text(
                                          '图片加载失败，请返回后重试（链接5分钟有效）',
                                        ),
                                      ),
                                    ),
                                  ),
                                  loading: () =>
                                      const CircularProgressIndicator(),
                                  error: (_, _) =>
                                      const Text('图片链接获取失败，请联网后重新打开'),
                                ),
                        ],
                        const Text('原始 OCR 文字（只读，区别于最终校对题目）'),
                        SelectableText(draft['raw_text'] as String? ?? ''),
                        if (draft['final_ocr_fields'] is Map)
                          ExpansionTile(
                            title: const Text('入库时的逐字段校对（区别于后续编辑）'),
                            children: [
                              for (final entry in ocrFieldLabels.entries)
                                ListTile(
                                  title: Text(entry.value),
                                  subtitle: SelectableText(
                                    (draft['final_ocr_fields']
                                                as Map)[entry.key]
                                            as String? ??
                                        '',
                                  ),
                                ),
                              const Text('图片中的作答和批注是来源记录，不代表家长确认的标准答案。'),
                            ],
                          ),
                      ],
                    ),
              loading: () => const LinearProgressIndicator(),
              error: (_, _) => const Text('图片来源读取失败；文字仍可查看，联网后重新打开'),
            ),
        const Text('标准答案与解析仅在复习提交后或 PIN 授权的编辑页面显示。'),
      ],
    ),
  );
}
