import 'error_reason.dart';

bool matchesQuestion(
  Map<String, dynamic> row, {
  String keyword = '',
  String subject = 'all',
  String mastery = 'all',
  String archive = 'all',
}) {
  if (subject != 'all' && row['subject'] != subject) return false;
  if (mastery != 'all' && row['mastery_status'] != mastery) return false;
  if (archive == 'active' && row['archived'] == true) return false;
  if (archive == 'archived' && row['archived'] != true) return false;
  final text = [
    row['final_text'],
    row['knowledge_point'],
    row['pronunciation_context'],
    row['error_reason'],
    ...questionErrorReasons(row).map((key) => errorReasonLabels[key]),
  ].whereType<String>().join(' ').toLowerCase();
  return text.contains(keyword.trim().toLowerCase());
}
