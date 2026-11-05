import '../../../core/offline/network_failure.dart';
import '../../../core/offline/offline_store.dart';
import '../domain/family.dart';
import 'family_repository.dart';
import 'family_creation_repository.dart';
import 'family_members_repository.dart';
import 'family_access_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OfflineFamilyRepository extends SupabaseFamilyRepository
    implements FamilyCreationAccess {
  OfflineFamilyRepository(
    SupabaseClient client,
    this.store,
    this.accountId, {
    this.access,
  }) : super(client) {
    membersRemote = SupabaseFamilyMembersRemote(client);
    creations = FamilyCreationRepository(
      store: store,
      accountId: accountId,
      remote: SupabaseFamilyCreationRemote(client),
    );
  }
  @override
  late final FamilyCreationRepository creations;
  late final FamilyMembersRemote membersRemote;
  final OfflineStore store;
  final String? Function() accountId;
  final FamilyAccessRepository? access;
  int _configurationRevision = 0;
  final _changingConfiguration = <String>{};

  Future<T> changeConfiguration<T>(
    String family,
    Future<T> Function() action,
  ) async {
    final owner = accountId(), privacy = store.privacyGeneration;
    final key = '$owner:$family';
    if (owner == null || !_changingConfiguration.add(key)) {
      throw StateError('家庭设置正在保存或账号已退出');
    }
    void check() {
      if (accountId() != owner || store.privacyGeneration != privacy) {
        throw StateError('家庭设置范围已变化');
      }
    }

    _configurationRevision++;
    try {
      await store.remove(owner, 'families');
      check();
      final result = await action();
      check();
      return result;
    } finally {
      _configurationRevision++;
      _changingConfiguration.remove(key);
      if (accountId() == owner) await store.remove(owner, 'families');
    }
  }

  @override
  Future<List<Family>> loadFamilies() async {
    final owner = accountId();
    if (owner == null) throw StateError('请先登录');
    final configurationRevision = _configurationRevision;
    var generation = store.privacyGeneration;
    void check() {
      if (accountId() != owner) throw StateError('登录账号已变化');
      if (configurationRevision != _configurationRevision ||
          _changingConfiguration.any((key) => key.startsWith('$owner:'))) {
        throw StateError('家庭设置已变化，请刷新');
      }
      if (store.privacyGeneration != generation) {
        throw StateError('孩子数据已删除，请刷新家庭');
      }
    }

    try {
      check();
      final loaded = await super.loadFamilies().timeout(
        const Duration(seconds: 10),
      );
      check();
      await access?.refresh();
      if (accountId() != owner) throw StateError('登录账号已变化');
      generation = store.privacyGeneration;
      final deleted = await loadDeletedChildIds().timeout(
        const Duration(seconds: 10),
      );
      check();
      for (final childId in deleted) {
        await store.removeChildData(childId);
      }
      generation = store.privacyGeneration;
      check();
      final families = [
        for (final family in loaded)
          if (!await store.familyAccessRevoked(owner, familyId: family.id))
            Family(
              id: family.id,
              name: family.name,
              timezone: family.timezone,
              children: family.children
                  .where((child) => !deleted.contains(child.id))
                  .toList(),
            ),
      ];
      await store.transaction(() async {
        check();
        await store.write(owner, 'families', {
          'items': [
            for (final family in families)
              {
                'id': family.id,
                'name': family.name,
                'timezone': family.timezone,
                'children': [
                  for (final child in family.children) child.toJson(),
                ],
              },
          ],
        });
        check();
      });
      check();
      await store.pruneFamilyInvitations(
        owner,
        families.map((family) => family.id).toSet(),
      );
      check();
      return families;
    } catch (error) {
      check();
      if (!isNetworkFailure(error)) {
        await store.remove(owner, 'families');
        rethrow;
      }
      final cached = await store.read(owner, 'families');
      check();
      if (cached == null) rethrow;
      return [
        for (final value in cached['items'] as List)
          Family(
            id: value['id'] as String,
            name: value['name'] as String,
            timezone: value['timezone'] as String,
            children: [
              for (final child in value['children'] as List)
                ChildProfile.fromJson((child as Map).cast<String, dynamic>()),
            ],
          ),
      ];
    }
  }
}
