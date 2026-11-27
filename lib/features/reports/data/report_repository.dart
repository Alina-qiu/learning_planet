import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth_family/application/family_providers.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../domain/learning_report.dart';

typedef ReportScope = ({
  String childId,
  String familyId,
  String period,
  String? endDate,
});

abstract interface class ReportRepository {
  Future<LearningReport> load(ReportScope scope);
}

final reportRepositoryProvider = Provider<ReportRepository>((ref) {
  final client = taskSupabaseClient(ref.watch(taskRepositoryProvider));
  if (client == null) throw StateError('请配置 Supabase');
  return SupabaseReportRepository(client);
});

final learningReportProvider = FutureProvider.autoDispose
    .family<LearningReport, ReportScope>((ref, scope) {
      if (ref.watch(activeParentFamilyProvider) != scope.familyId) {
        throw StateError('请返回首页验证家长 PIN');
      }
      return ref.watch(reportRepositoryProvider).load(scope);
    });

class SupabaseReportRepository implements ReportRepository {
  SupabaseReportRepository(this.client);
  final SupabaseClient client;

  @override
  Future<LearningReport> load(ReportScope scope) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final data = await client
        .rpc<Map<String, dynamic>>(
          'learning_report',
          params: {
            'target_child_id': scope.childId,
            'report_period': scope.period,
            'anchor_date': scope.endDate,
          },
        )
        .timeout(const Duration(seconds: 15));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    if (data['child_id'] != scope.childId || data['period'] != scope.period) {
      throw const FormatException('报告范围不匹配');
    }
    final report = LearningReport(data);
    if (report.familyRetention != null &&
        report.familyRetention!.familyId != scope.familyId) {
      throw const FormatException('报告家庭范围不匹配');
    }
    if (report.configurationTime != null &&
        report.configurationTime!.familyId != scope.familyId) {
      throw const FormatException('配置用时家庭范围不匹配');
    }
    return report;
  }
}
