import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth_family/application/auth_providers.dart';
import '../../auth_family/application/family_providers.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../domain/family_overview.dart';

abstract interface class FamilyOverviewRepository {
  Future<FamilyOverview> load(String familyId);
}

final familyOverviewRepositoryProvider = Provider<FamilyOverviewRepository>((
  ref,
) {
  final client = taskSupabaseClient(ref.watch(taskRepositoryProvider));
  if (client == null) throw StateError('请配置 Supabase');
  return SupabaseFamilyOverviewRepository(client);
});

final familyOverviewProvider = FutureProvider.autoDispose
    .family<FamilyOverview, String>((ref, family) {
      ref.watch(parentAuthorizationRevisionProvider);
      final session = ref.watch(authSessionProvider).valueOrNull;
      if (ref.watch(signingOutProvider) ||
          session == null ||
          ref.watch(activeParentFamilyProvider) != family) {
        throw StateError('请返回首页验证家长 PIN');
      }
      return ref.watch(familyOverviewRepositoryProvider).load(family);
    });

class SupabaseFamilyOverviewRepository implements FamilyOverviewRepository {
  const SupabaseFamilyOverviewRepository(this.client);
  final SupabaseClient client;
  @override
  Future<FamilyOverview> load(String familyId) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final data = await client
        .rpc<Map<String, dynamic>>(
          'family_overview',
          params: {'target_family_id': familyId},
        )
        .timeout(const Duration(seconds: 15));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    return FamilyOverview.fromJson(data, familyId);
  }
}
