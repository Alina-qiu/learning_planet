const errorReasonLabels = {
  'reading': '审题',
  'concept': '概念',
  'calculation': '计算',
  'handwriting': '书写',
  'memory': '记忆',
  'other': '其他',
};

List<String> questionErrorReasons(Map<String, dynamic> question) =>
    errorReasonLabels.keys
        .where(
          (key) => (question['error_reason_tags'] as List? ?? []).contains(key),
        )
        .toList();
