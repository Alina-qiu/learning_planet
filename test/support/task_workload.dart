import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/auth_family/data/auth_repository.dart';
import 'package:learning_planet/features/auth_family/data/family_repository.dart';
import 'package:learning_planet/features/auth_family/domain/auth_session.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_sync_remote.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/tasks/domain/task_item.dart';
import 'package:learning_planet/features/tasks/domain/wallet_summary.dart';

const workloadOwner = '10000000-0000-4000-8000-000000000001';
const workloadFamily = '20000000-0000-4000-8000-000000000001';
const workloadChild = '30000000-0000-4000-8000-000000000001';
String workloadTaskId(int index) =>
    '40000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
List<TaskItem> taskWorkload(int count, DateTime now, {DateTime? dueDate}) {
  final familyDate = dueDate ?? now.toUtc().add(const Duration(hours: 8));
  return List.generate(
    count,
    (index) => TaskItem(
      id: workloadTaskId(index),
      childId: workloadChild,
      title: '本机测试任务 ${index.toString().padLeft(4, '0')}',
      status: index == 0 ? TaskStatus.inProgress : TaskStatus.ready,
      coinReward: 5,
      xpReward: 10,
      accumulatedSeconds: 60,
      activeStartedAt: index == 0
          ? now.subtract(const Duration(minutes: 2))
          : null,
      dueDate: DateTime(familyDate.year, familyDate.month, familyDate.day),
    ),
  );
}

Map<String, dynamic> taskWorkloadSnapshot(List<TaskItem> tasks, DateTime now) =>
    {
      'lease_id': '50000000-0000-4000-8000-000000000001',
      'lease_expires_at': now.add(const Duration(days: 7)).toIso8601String(),
      'server_at': now.toUtc().toIso8601String(),
      'received_at': now.toUtc().toIso8601String(),
      'timezone': 'Asia/Shanghai',
      'tasks': tasks.map((e) => e.toJson()).toList(),
      'wallet': {'coin_balance': 100, 'frozen_balance': 0, 'xp': 120},
    };

class WorkloadAuth extends Fake implements AuthRepository {
  @override
  AuthSession get currentSession => const AuthSession(userId: workloadOwner);
  @override
  Stream<AuthSession?> watchSession() => Stream.value(currentSession);
}

class WorkloadFamily extends Fake implements FamilyRepository {
  @override
  Future<List<Family>> loadFamilies() async => [
    Family(
      id: workloadFamily,
      name: '本机测试家庭',
      timezone: 'Asia/Shanghai',
      children: [
        ChildProfile(
          id: workloadChild,
          familyId: workloadFamily,
          nickname: '本机测试孩子',
          grade: 2,
          onboardingCompletedAt: DateTime(2026),
        ),
      ],
    ),
  ];
}

class WorkloadTasks extends Fake implements TaskRepository {
  WorkloadTasks(this.tasks);
  List<TaskItem> tasks;
  int completions = 0;
  bool failCompletion = false;
  @override
  Future<List<TaskItem>> loadTasks(String childId) async => tasks;
  @override
  Future<WalletSummary> loadWallet(String childId) async =>
      const WalletSummary(coins: 100, frozen: 0, xp: 120);
  @override
  Future<void> complete(String taskId) async {
    if (failCompletion) throw StateError('completion not saved');
    completions++;
    tasks = tasks
        .map(
          (task) => task.id == taskId
              ? TaskItem.fromJson({
                  ...task.toJson(),
                  'status': 'completed',
                  'active_started_at': null,
                })
              : task,
        )
        .toList();
  }
}

/// Held network I/O proves a completion is committed locally without a reply.
class HeldTaskRemote implements TaskSyncRemote {
  final waiting = Completer<void>();
  int calls = 0;
  @override
  Future<Map<String, dynamic>> snapshot(String childId) async {
    calls++;
    await waiting.future;
    throw const SocketException('Synthetic offline transport');
  }

  @override
  Future<Map<String, dynamic>> apply(Map<String, dynamic> command) async =>
      throw const SocketException('Synthetic offline transport');
}
