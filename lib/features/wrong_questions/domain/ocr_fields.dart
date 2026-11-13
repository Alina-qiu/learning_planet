const ocrFieldLabels = <String, String>{
  'prompt': '题干',
  'options': '选项',
  'answer': '图片中的作答',
  'annotation': '批注',
};

/// Local layout hints only: every unlabelled line is retained. Neither answer
/// recognition nor a layout hint authorizes a grading answer.
Map<String, dynamic> structureQuestionOcr(Map<String, dynamic> raw) {
  final lines = (raw['lines'] as List? ?? []).whereType<Map>().toList();
  final fullText = raw['text'] as String? ?? '';
  String normalize(String text) => text.replaceAll(RegExp(r'\s+'), '');
  final useLines =
      lines.isNotEmpty &&
      (fullText.isEmpty ||
          normalize(
                lines
                    .map((line) => line['text'] is String ? line['text'] : '')
                    .join('\n'),
              ) ==
              normalize(fullText));
  final source = useLines
      ? lines
      : fullText.split('\n').map((s) => {'text': s}).toList();
  final texts = {for (final key in ocrFieldLabels.keys) key: <String>[]};
  final indices = {for (final key in ocrFieldLabels.keys) key: <int>[]};
  final confidence = {for (final key in ocrFieldLabels.keys) key: <double?>[]};
  final label = RegExp(
    r'^\s*(?:【|\[)?(题干|题目|问题|选项|参考答案|标准答案|正确答案|学生答案|我的答案|答案|作答|教师批注|老师批注|批注|点评|解析|question|options|answer|annotation|comment)(?:】|\])?\s*[:：]\s*',
    caseSensitive: false,
  );
  final option = RegExp(r'^\s*[A-HＡ-Ｈ][.．、)）]\s*');
  var section = 'prompt';
  for (var i = 0; i < source.length; i++) {
    final line = source[i], text = line['text'];
    if (text is! String || text.trim().isEmpty) continue;
    var value = text;
    final match = label.firstMatch(text);
    if (match != null) {
      final name = match.group(1)!.toLowerCase();
      section = switch (name) {
        '题干' || '题目' || '问题' || 'question' => 'prompt',
        '选项' || 'options' => 'options',
        '教师批注' ||
        '老师批注' ||
        '批注' ||
        '点评' ||
        '解析' ||
        'annotation' ||
        'comment' => 'annotation',
        _ => 'answer',
      };
      value = text.substring(match.end);
    } else if (option.hasMatch(text)) {
      section = 'options';
    }
    texts[section]!.add(value);
    indices[section]!.add(i);
    final score = line['confidence'];
    confidence[section]!.add(
      score is num && score.isFinite && score >= 0 && score <= 1
          ? score.toDouble()
          : null,
    );
  }
  return {
    ...raw,
    'field_schema': 1,
    'field_method': 'explicit-labels-v1',
    'field_line_source': useLines ? 'lines' : 'text',
    'fields': {
      for (final key in ocrFieldLabels.keys)
        key: {
          'text': texts[key]!.join('\n').trim(),
          'line_indices': indices[key],
          'confidence':
              confidence[key]!.isEmpty || confidence[key]!.contains(null)
              ? null
              : confidence[key]!.cast<double>().reduce((a, b) => a < b ? a : b),
        },
    },
  };
}

Map<String, dynamic> questionOcrFields(Map<String, dynamic> raw) =>
    Map<String, dynamic>.from(
      (raw['field_schema'] == 1 && raw['fields'] is Map
              ? raw['fields']
              : structureQuestionOcr(raw)['fields'])
          as Map,
    );

String composeOcrQuestion(Map<String, dynamic> fields) => [
  (fields['prompt'] as String? ?? '').trim(),
  (fields['options'] as String? ?? '').trim(),
].where((text) => text.isNotEmpty).join('\n');
