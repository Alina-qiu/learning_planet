import 'dart:async';

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
  int _configurationRevision = 0, _readNumber = 0, _latestDirectory = 0;
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
  Future<List<Family>> loadFamilies({
    AuthRetryableFetchException? entryRefreshFailure,
  }) async {
    final owner = accountId();
    if (owner == null) throw StateError('请先登录');
    final configurationRevision = _configurationRevision;
    final read = ++_readNumber;
    var generation = store.privacyGeneration;
    void check() {
      if (accountId() != owner) throw StateError('登录账号已变化');
      if (read < _latestDirectory) throw StateError('家庭目录已刷新');
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
      if (entryRefreshFailure != null && currentSession?.user.id == owner) {
        throw entryRefreshFailure;
      }
      final loaded = await super.loadFamilies().timeout(
        const Duration(seconds: 10),
      );
      check();
      _latestDirectory = read;
      final visible = {
        for (final family in loaded)
          family.id: family.children.map((child) => child.id).toSet(),
      };
      await store.transaction(() async {
        check();
        await store.restrictDirectoryAccess(owner, visible);
        generation = store.privacyGeneration;
        check();
      });
      // Both reads use the memberships after accepting invitations. Local
      // revocations still take effect even if the tombstone request fails.
      final membership = (access?.refresh() ?? Future<void>.value()).then((_) {
        if (accountId() != owner) throw StateError('登录账号已变化');
        generation = store.privacyGeneration;
      });
      Future<void> applyDeletions(List<String> ids) async {
        check();
        for (final childId in ids) {
          await store.removeChildData(childId);
        }
        generation = store.privacyGeneration;
        check();
      }

      late final List<String> deleted;
      try {
        final checks = await (
          membership,
          loadDeletedChildIds().timeout(const Duration(seconds: 10)),
        ).wait;
        deleted = checks.$2;
      } on ParallelWaitError<
        (void, List<String>?),
        (AsyncError?, AsyncError?)
      > catch (failure) {
        if (failure.values.$2 case final observed?) {
          // Even a partly offline launch must honor known deletions before
          // considering a cached family.
          await applyDeletions(observed);
        }
        final errors = [failure.errors.$1, failure.errors.$2].nonNulls;
        // A server denial must never turn into offline access just because the
        // other request happened to time out in the same interval.
        final cause = errors.firstWhere(
          (e) => !isNetworkFailure(e.error),
          orElse: () => errors.first,
        );
        Error.throwWithStackTrace(cause.error, cause.stackTrace);
      }
      await applyDeletions(deleted);
      await store.transaction(() async {
        check();
        await store.restoreDirectoryAccess(owner, visible);
        generation = store.privacyGeneration;
        check();
      });
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
