import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

const exportSectionLabels = {
  'child_profile': '孩子档案',
  'task_templates': '任务模板',
  'tasks': '任务记录',
  'task_notes': '任务补充说明',
  'long_plans': '长期计划',
  'plan_leaves': '批准请假',
  'plan_stage_rewards': '阶段奖励',
  'plan_bonus_tiers': '计划终奖规则',
  'wallet': '钱包',
  'wallet_settings': '金币规则',
  'ledger': '金币与XP账本',
  'pending_coins': '待确认金币',
  'wrong_questions': '错题与拼音',
  'question_answers': '标准答案与解析',
  'review_items': '复习记录',
  'review_reminders': '复习稍后提醒',
  'review_answer_keys': '复习答案快照',
  'ocr_records': 'OCR来源与草稿',
  'ai_analysis': 'AI分析请求与建议',
  'ai_question_origins': 'AI题目来源',
  'ai_question_adoptions': 'AI题目采纳记录',
  'ai_feedback': 'AI题目反馈',
  'ai_report_feedback': 'AI周报反馈',
  'parent_notification_receipts': '当前家长消息回执',
  'family_retention': '家庭共享回访起点',
  'family_activity_days': '家庭共享首周活跃日期',
  'parent_configuration_time': '当前家长配置用时',
  'image_index': '图片索引',
  'family_rewards': '家庭共享奖励目录',
  'redemptions': '孩子兑换记录',
  'learning_events': '表扬与考试',
  'checkin_days': '成长日期',
  'streak_awards': '连续里程碑',
  'growth_assets': '解锁物品',
  'growth_profile': '角色设置',
  'reminder_settings': '提醒设置',
  'reminder_receipts': '提醒已读记录',
  'worksheets': '未过期组卷索引',
  'worksheet_items': '组卷题目快照',
  'audit_logs': '关联操作审计',
};

String exportCsvCell(Object? value) {
  var text = value == null
      ? ''
      : value is Map || value is List
      ? jsonEncode(value)
      : '$value';
  // Quoting alone does not prevent spreadsheet formula evaluation. Preserve the
  // untouched value in data.json while making textual CSV cells inert.
  if (value is String &&
      (RegExp(r'^[\s\x00-\x1f]*[=+\-@]').hasMatch(text) ||
          RegExp(r'^[\t\r\n]').hasMatch(text))) {
    text = "'$text";
  }
  return '"${text.replaceAll('"', '""')}"';
}

/// Runs in a compute isolate. Only fixed section names become ZIP entry paths.
Uint8List buildChildExportZip(Map<String, dynamic> input) {
  final manifest = Map<String, dynamic>.from(input['manifest'] as Map);
  final sections = (manifest['sections'] as List).cast<Map<String, dynamic>>();
  final records = input['records'] as Map<String, dynamic>;
  final archive = Archive();
  final hashes = <String, String>{};
  final modified = DateTime.parse(manifest['created_at'] as String).toUtc();
  void add(String name, String text) {
    final bytes = utf8.encode(text);
    hashes[name] = sha256.convert(bytes).toString();
    archive.addFile(
      ArchiveFile.bytes(name, bytes)
        ..lastModTime = modified.millisecondsSinceEpoch ~/ 1000,
    );
  }

  final seen = <String>{};
  for (final section in sections) {
    final name = section['name'] as String;
    if (!exportSectionLabels.containsKey(name) || !seen.add(name)) {
      throw const FormatException('未知或重复的导出类别');
    }
    final columns = (section['columns'] as List).cast<String>();
    final rows = (records[name] as List).cast<Map<String, dynamic>>();
    if (rows.length != section['count'] ||
        columns.isEmpty ||
        columns.toSet().length != columns.length) {
      throw const FormatException('导出记录不完整');
    }
    final csv = StringBuffer('\uFEFF')
      ..write('${columns.map(exportCsvCell).join(',')}\r\n');
    for (final row in rows) {
      if (row.keys.any((key) => !columns.contains(key))) {
        throw const FormatException('导出字段与清单不一致');
      }
      csv.write(
        '${columns.map((key) => exportCsvCell(row[key])).join(',')}\r\n',
      );
    }
    add('$name.csv', csv.toString());
  }
  if (records.keys.toSet().difference(seen).isNotEmpty) {
    throw const FormatException('存在清单之外的导出数据');
  }
  add(
    'data.json',
    jsonEncode({
      'schema_version': manifest['schema_version'],
      'snapshot': manifest['created_at'],
      'child_id': manifest['child_id'],
      'records': records,
    }),
  );
  add(
    'README.txt',
    '学习星球孩子数据导出\r\n快照时间：${manifest['created_at']}\r\n'
        'CSV使用UTF-8 BOM、逗号和双引号。复杂字段以JSON表示。为避免表格软件执行公式，特殊开头的文本前加单引号；原始值完整保存在data.json中。\r\n'
        '包含此孩子已同步的云端记录、已提交待家长确认的错题、家庭共享奖励目录与首周回访统计；其他成员未提交的OCR草稿除外。家庭回访数据不标识具体孩子或操作者。\r\n'
        'image_index.csv和worksheets.csv是私有文件索引，包含路径，不含图片/PDF文件、签名链接或登录凭证。查看原图/PDF仍需在应用内授权。\r\n'
        '内容包含孩子信息、答案和操作记录，请妥善保管。已保存到设备或其他位置的副本无法由应用远程删除。\r\n'
        'manifest.json记录各类别行数、列名和文件SHA-256，便于核对完整性。此导出用于查阅与备份，当前不支持导入恢复。\r\n',
  );
  add(
    'manifest.json',
    jsonEncode({...manifest, 'files_sha256': Map<String, String>.from(hashes)}),
  );
  return ZipEncoder().encodeBytes(archive, modified: modified);
}
