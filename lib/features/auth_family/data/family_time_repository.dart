import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/offline/offline_store.dart';

class FamilyTimeSettings {
  const FamilyTimeSettings({
    required this.familyId,
    required this.timezone,
    required this.version,
    required this.today,
    required this.children,
  });
  final String familyId, timezone, today;
  final int version;
  final List<String> children;
  factory FamilyTimeSettings.fromJson(Map<String, dynamic> value) =>
      FamilyTimeSettings(
        familyId: value['family_id'] as String,
        timezone: value['timezone'] as String,
        version: value['version'] as int,
        today: value['family_today'] as String,
        children: (value['child_ids'] as List).cast<String>(),
      );
}

abstract interface class FamilyTimeRemote {
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> params);
}

class SupabaseFamilyTimeRemote implements FamilyTimeRemote {
  const SupabaseFamilyTimeRemote(this.client);
  final SupabaseClient client;
  @override
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> params) =>
      client
          .rpc<Map<String, dynamic>>(name, params: params)
          .timeout(const Duration(seconds: 15));
}

typedef FamilyTimeChange =
    Future<FamilyTimeSettings> Function(
      FamilyTimeSettings before,
      Future<FamilyTimeSettings> Function() action,
    );

/// Online compare-and-set settings. Timezone changes are never queued offline;
/// replaying the same expected version/zone is idempotent at the server.
class FamilyTimeRepository {
  FamilyTimeRepository({
    required this.remote,
    required this.accountId,
    required this.isAuthorized,
    required this.authorizationRevision,
    required this.changeConfiguration,
    this.store,
  });
  final FamilyTimeRemote remote;
  final String? Function() accountId;
  final bool Function(String family) isAuthorized;
  final int Function() authorizationRevision;
  final FamilyTimeChange changeConfiguration;
  final OfflineStore? store;
  final _changing = <String>{};

  Future<FamilyTimeSettings> _perform(
    String family,
    Future<FamilyTimeSettings> Function(Future<void> Function()) action,
  ) async {
    final owner = accountId(),
        revision = authorizationRevision(),
        privacy = store?.privacyGeneration;
    Future<void> check() async {
      void guard() {
        if (owner == null ||
            accountId() != owner ||
            revision != authorizationRevision() ||
            privacy != store?.privacyGeneration ||
            !isAuthorized(family)) {
          throw StateError('账号或家长授权已变化，请重新验证 PIN');
        }
      }

      guard();
      if (store != null &&
          (await store!.accountDeletionJob(owner!) != null ||
              await store!.familyAccessRevoked(owner, familyId: family))) {
        throw StateError('此家庭已不可访问');
      }
      guard();
    }

    await check();
    final result = await action(check);
    await check();
    if (result.familyId != family || result.version < 0) {
      throw const FormatException('家庭时区回执不匹配');
    }
    return result;
  }

  Future<FamilyTimeSettings> load(String family) => _perform(
    family,
    (check) async => FamilyTimeSettings.fromJson(
      await remote.call('family_time_settings', {'target_family_id': family}),
    ),
  );

  Future<FamilyTimeSettings> save(FamilyTimeSettings before, String timezone) =>
      _perform(before.familyId, (check) async {
        if (!_changing.add(before.familyId)) throw StateError('时区正在保存');
        try {
          return await changeConfiguration(before, () async {
            await check();
            final result = FamilyTimeSettings.fromJson(
              await remote.call('set_family_timezone', {
                'target_family_id': before.familyId,
                'requested_timezone': timezone,
                'expected_version': before.version,
              }),
            );
            await check();
            final expected =
                before.version + (timezone == before.timezone ? 0 : 1);
            if (result.familyId != before.familyId ||
                result.timezone != timezone ||
                result.version != expected) {
              throw const FormatException('时区保存回执不匹配，请刷新核对');
            }
            return result;
          });
        } finally {
          _changing.remove(before.familyId);
        }
      });
}
