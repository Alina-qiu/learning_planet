import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'parent_mode_prompt.dart';
import 'app_sign_out.dart';
import 'entry_recovery_screen.dart';
import 'getting_started_screen.dart';
import '../../tasks/application/task_providers.dart';

import '../../home/presentation/home_screen.dart';
import '../application/family_providers.dart';
import '../application/family_access_provider.dart';
import '../application/auth_providers.dart';
import 'family_management_screen.dart';
import 'family_onboarding_screen.dart';
import '../../tasks/presentation/task_management_screen.dart';
import '../../tasks/presentation/reminder_coordinator.dart';
import '../../tasks/data/notification_scheduler.dart';

class FamilyGate extends ConsumerStatefulWidget {
  const FamilyGate({super.key});

  @override
  ConsumerState<FamilyGate> createState() => _FamilyGateState();
}

class _FamilyGateState extends ConsumerState<FamilyGate> {
  bool _switchingChild = false;

  Future<bool> _clearNotifications() async {
    try {
      await ref.read(notificationSchedulerProvider).setScope(null);
      return mounted;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('清除旧提醒失败，请重试。')));
      }
      return false;
    }
  }

  Future<bool> _exitParentMode() async {
    final wasInParentMode = ref.read(parentModeProvider);
    clearLocalParentAuthorization(ref);
    final revision = ref.read(parentAuthorizationRevisionProvider);
    final repository = ref.read(familyRepositoryProvider);
    try {
      await repository.revokeParentAuthorization().timeout(
        const Duration(seconds: 3),
      );
    } catch (_) {
      if (mounted && wasInParentMode) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('本机已退出家长模式。再次进入时请联网验证 PIN。')),
        );
      }
    }
    return mounted && ref.read(parentAuthorizationRevisionProvider) == revision;
  }

  Future<void> _selectChild(String id) async {
    if (_switchingChild) return;
    setState(() => _switchingChild = true);
    try {
      if (!await _exitParentMode() || !mounted) return;
      final revision = ref.read(parentAuthorizationRevisionProvider);
      if (!await _clearNotifications() ||
          !mounted ||
          ref.read(parentAuthorizationRevisionProvider) != revision) {
        return;
      }
      final families = ref.read(familiesProvider).valueOrNull;
      if (families != null &&
          families.any(
            (family) => family.children.any((child) => child.id == id),
          )) {
        ref.read(selectedChildIdProvider.notifier).state = id;
      }
    } finally {
      if (mounted) setState(() => _switchingChild = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(familiesProvider, (_, next) {
      if (next.isLoading) return;
      final families = next.asData?.value;
      if (families == null) return;
      final children = families.expand((family) => family.children);
      if (children.isEmpty) return;
      final selected = ref.read(selectedChildIdProvider);
      final child = children.firstWhere(
        (child) => child.id == selected,
        orElse: () => children.first,
      );
      // Permission and deletion checks have completed. Start the same providers
      // consumed by the home widgets before laying out their first frame.
      ref.read(tasksProvider(child.id));
      ref.read(walletProvider(child.id));
      ref.read(familyTodayProvider(child.id));
    });
    ref.listen(familyAccessChangesProvider, (_, next) {
      final change = next.valueOrNull;
      if (change == null ||
          ref.read(authRepositoryProvider).currentSession?.userId !=
              change.owner) {
        return;
      }
      final families = ref.read(familiesProvider).valueOrNull;
      final children = families?.expand((family) => family.children).toList();
      final selected =
          ref.read(selectedChildIdProvider) ??
          (children == null || children.isEmpty ? null : children.first.id);
      final parent = ref.read(parentFamilyIdProvider) == change.familyId;
      if (parent) clearLocalParentAuthorization(ref);
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      for (final child in change.childIds) {
        ref.invalidate(tasksProvider(child));
        ref.invalidate(walletProvider(child));
        ref.invalidate(familyTodayProvider(child));
      }
      if (change.childIds.contains(selected) || parent) {
        ref.read(selectedChildIdProvider.notifier).state = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted &&
              ref.read(authRepositoryProvider).currentSession?.userId ==
                  change.owner) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
        });
      }
      ref.invalidate(familiesProvider);
    });
    ref.listen(remotelyDeletedChildProvider, (_, next) {
      final deleted = next.valueOrNull;
      if (deleted == null) return;
      final children = ref
          .read(familiesProvider)
          .valueOrNull
          ?.expand((family) => family.children)
          .toList();
      final current =
          ref.read(selectedChildIdProvider) ??
          (children == null || children.isEmpty ? null : children.first.id);
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      if (current == deleted || current == null) {
        ref.read(selectedChildIdProvider.notifier).state = null;
        ref.read(notificationSchedulerProvider).setScope(null).catchError((
          Object error,
        ) {
          if (context.mounted) {
            ref.read(notificationErrorProvider.notifier).state =
                '清除已删除孩子的提醒失败：$error';
          }
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
        });
      }
      ref.invalidate(familiesProvider);
    });
    return ref
        .watch(familiesProvider)
        .when(
          data: (families) {
            if (families.isEmpty) return const FamilyOnboardingScreen();
            final children = families
                .expand((family) => family.children)
                .toList();
            if (children.isEmpty) {
              return Scaffold(
                appBar: AppBar(title: const Text('家庭设置')),
                body: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text('家庭中暂无孩子。验证家长 PIN 后可以添加孩子或查看删除记录。'),
                    for (final family in families)
                      ListTile(
                        title: Text(family.name),
                        trailing: FilledButton(
                          child: const Text('管理家庭'),
                          onPressed: () async {
                            await enterParentMode(context, ref, family.id);
                            if (!context.mounted ||
                                ref.read(activeParentFamilyProvider) !=
                                    family.id) {
                              return;
                            }
                            await Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) => const FamilyManagementScreen(),
                              ),
                            );
                          },
                        ),
                      ),
                    const AppSignOutButton(),
                  ],
                ),
              );
            }
            final selectedId = ref.watch(selectedChildIdProvider);
            final parentFamilyId = ref.watch(activeParentFamilyProvider);
            final child = children.firstWhere(
              (item) => item.id == selectedId,
              orElse: () => children.first,
            );
            final isParentMode = parentFamilyId == child.familyId;
            final familyTimezone = families
                .firstWhere((f) => f.id == child.familyId)
                .timezone;
            // A sync snapshot may discover a setting changed on another phone.
            // Reload the family record instead of retaining its older cached zone.
            ref.listen(taskFamilyTimezoneProvider(child.id), (_, next) {
              final confirmed = next.valueOrNull;
              if (confirmed != null && confirmed != familyTimezone) {
                ref.invalidate(familiesProvider);
              }
            });
            if (_switchingChild) {
              return Scaffold(
                body: Center(
                  child: Semantics(
                    liveRegion: true,
                    child: const Text('正在切换孩子…'),
                  ),
                ),
              );
            }
            return ReminderCoordinator(
              childId: child.id,
              familyId: child.familyId,
              familyTimezone: familyTimezone,
              child: HomeScreen(
                childNickname: child.nickname,
                children: children,
                selectedChildId: child.id,
                onChildSelected: _selectChild,
                onGettingStarted: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => GettingStartedScreen(
                      childId: child.id,
                      familyId: child.familyId,
                    ),
                  ),
                ),
                onManageFamily: () async {
                  if (!isParentMode) {
                    await enterParentMode(context, ref, child.familyId);
                  }
                  if (!context.mounted ||
                      ref.read(activeParentFamilyProvider) != child.familyId) {
                    return;
                  }
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const FamilyManagementScreen(),
                    ),
                  );
                },
                onManageTasks: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TaskManagementScreen(
                        childId: child.id,
                        childNickname: child.nickname,
                        familyId: child.familyId,
                        isParentMode: isParentMode,
                      ),
                    ),
                  );
                  if (!context.mounted) return;
                  ref.invalidate(tasksProvider(child.id));
                  ref.invalidate(walletProvider(child.id));
                },
                isParentMode: isParentMode,
                onParentMode: () {
                  if (isParentMode) {
                    _exitParentMode();
                  } else {
                    enterParentMode(context, ref, child.familyId);
                  }
                },
                onSignOut: () => signOutOfApp(context, ref),
              ),
            );
          },
          loading: () => const Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 24),
                  AppSignOutButton(),
                ],
              ),
            ),
          ),
          error: (error, stackTrace) => EntryRecoveryScreen(
            check: EntryCheck.family,
            error: error,
            retrying: ref.watch(familiesProvider).isLoading,
            onRetry: () => ref.invalidate(familiesProvider),
          ),
        );
  }
}
