import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'family_providers.dart';
import 'auth_providers.dart';
import '../data/family_time_repository.dart';
import '../data/offline_family_repository.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../../tasks/data/schedule_repository.dart';
import '../../notifications/data/parent_notification_device.dart';

final familyTimeRepositoryProvider = Provider<FamilyTimeRepository?>((ref) {
  final tasks = ref.watch(taskRepositoryProvider),
      family = ref.watch(familyRepositoryProvider);
  final client = taskSupabaseClient(tasks);
  if (client == null) return null;
  final offline = tasks is OfflineTaskRepository ? tasks : null;
  final schedules = ref.watch(scheduleRepositoryProvider),
      device = ref.watch(parentNotificationDeviceProvider);
  bool authorized(String id) =>
      !ref.read(signingOutProvider) &&
      ref.read(activeParentFamilyProvider) == id;
  return FamilyTimeRepository(
    remote: SupabaseFamilyTimeRemote(client),
    accountId: offline?.accountId ?? () => client.auth.currentUser?.id,
    isAuthorized: authorized,
    authorizationRevision: () => ref.read(parentAuthorizationRevisionProvider),
    store: offline?.store,
    changeConfiguration: (before, action) async {
      Future<FamilyTimeSettings> children(int i) => i == before.children.length
          ? action()
          : schedules.snapshots.change(
              before.children[i],
              () => schedules.changeReminders(
                before.children[i],
                () => children(i + 1),
              ),
            );
      Future<FamilyTimeSettings> notifications() => device == null
          ? children(0)
          : device.changeFamilyTimezone(
              before.familyId,
              () => children(0),
              canConfigure: () => authorized(before.familyId),
            );
      return family is OfflineFamilyRepository
          ? family.changeConfiguration(before.familyId, notifications)
          : notifications();
    },
  );
});
