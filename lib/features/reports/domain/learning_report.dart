import 'business_metrics.dart';
import 'task_start_metrics.dart';
import 'family_retention.dart';
import 'configuration_time.dart';

class LearningReport {
  LearningReport(this.data)
    : configurationTime = data['configuration_time'] == null
          ? null
          : ConfigurationTime.fromJson(
              Map<String, dynamic>.from(data['configuration_time'] as Map),
            ),
      familyRetention = data['family_retention'] == null
          ? null
          : FamilyRetention.fromJson(
              Map<String, dynamic>.from(data['family_retention'] as Map),
            ),
      startMetrics = data['start_metrics'] == null
          ? null
          : TaskStartMetrics.fromJson(
              Map<String, dynamic>.from(data['start_metrics'] as Map),
            ),
      businessMetrics = data['business_metrics'] == null
          ? null
          : BusinessMetrics.fromJson(
              Map<String, dynamic>.from(data['business_metrics'] as Map),
            );
  final Map<String, dynamic> data;
  final BusinessMetrics? businessMetrics;
  final TaskStartMetrics? startMetrics;
  final FamilyRetention? familyRetention;
  final ConfigurationTime? configurationTime;
  String get startDate => data['start_date'] as String;
  String get endDate => data['end_date'] as String;
  String get today => data['today'] as String;
  String get timezone => data['timezone'] as String;
  Map<String, dynamic> get tasks => data['tasks'] as Map<String, dynamic>;
  Map<String, dynamic> get reviews => data['reviews'] as Map<String, dynamic>;
  Map<String, dynamic> get coins => data['coins'] as Map<String, dynamic>;
  List<Map<String, dynamic>> get days =>
      (data['days'] as List).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get activities =>
      (data['activities'] as List).cast<Map<String, dynamic>>();
  int get activityCount => (data['activity_count'] as num).toInt();
  int get dueNow => (data['due_now'] as num).toInt();
  List<Map<String, dynamic>> get growthMonths =>
      ((data['growth'] as Map?)?['series'] as List? ?? [])
          .cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get knowledgeSubjects =>
      ((data['knowledge'] as Map?)?['subjects'] as List? ?? [])
          .cast<Map<String, dynamic>>();

  // A transparent rule-based suggestion, never a diagnosis or an AI claim.
  ({String text, String basis}) get suggestion {
    if (dueNow > 0) {
      return (
        text: '下次学习先安排一小段错题复习，按当天队列逐题完成。',
        basis: '截至今天有 $dueNow 道未掌握的到期题。',
      );
    }
    if ((tasks['expected'] as num) == 0) {
      return (text: '和孩子一起选一项容易开始的小任务，再观察适合的学习时间。', basis: '所选日期没有已生成的应完成任务。');
    }
    if ((tasks['completed'] as num) < (tasks['expected'] as num)) {
      return (
        text: '一起看看未完成任务的时段和时长，下一次可以把任务拆成更小的一步。',
        basis: '所选日期的 ${tasks['expected']} 项任务中，已完成 ${tasks['completed']} 项。',
      );
    }
    return (
      text: '和孩子回顾一项喜欢的任务，下次保留这个安排。',
      basis: '所选日期的 ${tasks['completed']} 项应完成任务均已完成。',
    );
  }
}

/// Calendar arithmetic on server-provided dates, independent of the device zone.
String adjacentReportAnchor(
  LearningReport report,
  String period,
  int direction,
) {
  final end = DateTime.parse('${report.endDate}T00:00:00Z');
  final next = period == 'month'
      ? DateTime.utc(end.year, end.month + direction, 1)
      : end.add(Duration(days: direction * (period == 'week' ? 7 : 1)));
  return next.toIso8601String().substring(0, 10);
}

String reportPercent(Object? value) =>
    value == null ? '暂无数据' : '${((value as num) * 100).toStringAsFixed(0)}%';

String reportDuration(num seconds) {
  final total = seconds.toInt();
  if (total < 60) return '$total 秒';
  return '${total ~/ 60} 分 ${total % 60} 秒';
}
