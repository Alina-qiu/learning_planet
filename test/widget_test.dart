import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/app/app.dart';
import 'package:learning_planet/features/auth_family/data/auth_repository.dart';
import 'package:learning_planet/features/auth_family/data/family_repository.dart';
import 'package:learning_planet/features/auth_family/domain/auth_session.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/domain/task_item.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/tasks/domain/wallet_summary.dart';

void main() {
  testWidgets('未登录时展示邮箱登录并发送验证码', (tester) async {
    final repository = FakeAuthRepository();
    await tester.pumpWidget(
      LearningPlanetApp(
        authRepository: repository,
        familyRepository: FakeFamilyRepository(),
        taskRepository: FakeTaskRepository(),
      ),
    );
    await tester.pump();

    expect(find.text('登录学习星球'), findsOneWidget);
    await tester.enterText(find.byType(EditableText), 'parent@example.com');
    await tester.tap(find.text('发送登录链接'));
    await tester.pump();

    expect(repository.lastOtpEmail, 'parent@example.com');
    expect(find.text('登录链接已发送，请检查邮箱'), findsOneWidget);
  });

  testWidgets('登录后展示今日任务和自动错题复习入口', (tester) async {
    final repository = FakeAuthRepository(
      const AuthSession(userId: 'parent-1', email: 'parent@example.com'),
    );
    await tester.pumpWidget(
      LearningPlanetApp(
        authRepository: repository,
        familyRepository: FakeFamilyRepository.withChild(),
        taskRepository: FakeTaskRepository(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('今日任务'), findsOneWidget);
    expect(find.text('今日错题复习'), findsOneWidget);
    expect(find.text('查看任务'), findsOneWidget);
    expect(find.text('金币 37 · 冻结 5 · XP 91'), findsOneWidget);
    expect(find.textContaining('Lv. 12'), findsNothing);
  });

  testWidgets('家庭管理先验证 PIN，且家长模式可以退出', (tester) async {
    await tester.pumpWidget(
      LearningPlanetApp(
        authRepository:
            FakeAuthRepository(const AuthSession(userId: 'parent-1')),
        familyRepository: FakeFamilyRepository.withChild(),
        taskRepository: FakeTaskRepository(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('家庭与孩子'));
    await tester.pumpAndSettle();
    expect(find.text('输入家长 PIN'), findsOneWidget);
    expect(find.text('添加孩子'), findsNothing);
    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.text('验证'));
    await tester.pumpAndSettle();
    expect(find.text('添加孩子'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('家长模式'), findsOneWidget);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出家长模式'));
    await tester.pumpAndSettle();
    expect(find.text('家长模式'), findsNothing);
  });

  testWidgets('首次登录可创建家庭和孩子档案', (tester) async {
    final familyRepository = FakeFamilyRepository();
    await tester.pumpWidget(
      LearningPlanetApp(
        authRepository: FakeAuthRepository(
          const AuthSession(userId: 'parent-1'),
        ),
        familyRepository: familyRepository,
        taskRepository: FakeTaskRepository(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('创建家庭'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, '家庭名称'), '星星家');
    await tester.enterText(find.widgetWithText(TextFormField, '孩子昵称'), '星宝');
    await tester.tap(find.text('创建并开始'));
    await tester.pumpAndSettle();

    expect(familyRepository.createdFamilyName, '星星家');
    expect(familyRepository.createdChildNickname, '星宝');
  });
}

class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository([this.currentSession]);

  @override
  final AuthSession? currentSession;
  String? lastOtpEmail;

  @override
  Future<void> sendEmailOtp(String email) async => lastOtpEmail = email;

  @override
  Future<void> signOut() async {}

  @override
  Stream<AuthSession?> watchSession() => Stream.value(currentSession);
}

class FakeFamilyRepository implements FamilyRepository {
  FakeFamilyRepository() : families = [];

  FakeFamilyRepository.withChild()
      : families = const [
          Family(
            id: 'family-1',
            name: '星星家',
            timezone: 'Asia/Shanghai',
            children: [
              ChildProfile(
                id: 'child-1',
                familyId: 'family-1',
                nickname: '星宝',
                grade: 3,
              ),
            ],
          ),
        ];

  final List<Family> families;
  String? createdFamilyName;
  String? createdChildNickname;

  @override
  Future<List<Family>> loadFamilies() async => families;

  @override
  Future<void> createFamilyWithChild({
    required String familyName,
    required String timezone,
    required String childNickname,
    required int grade,
  }) async {
    createdFamilyName = familyName;
    createdChildNickname = childNickname;
  }

  @override
  Future<void> createChild({
    required String familyId,
    required String nickname,
    required int grade,
  }) async {}

  @override
  Future<void> deleteChild(String childId) async {}

  @override
  Future<void> setParentPin({
    required String familyId,
    required String pin,
  }) async {}

  @override
  Future<void> inviteParent({
    required String familyId,
    required String email,
  }) async {}

  @override
  Future<ParentPinVerification> verifyParentPin({
    required String familyId,
    required String pin,
  }) async =>
      const ParentPinVerification(verified: true, remainingAttempts: 5);

  @override
  Future<void> updateChild({
    required String childId,
    required String nickname,
    required int grade,
  }) async {}
}

class FakeTaskRepository implements TaskRepository {
  @override
  Future<WalletSummary> loadWallet(String childId) async =>
      const WalletSummary(coins: 37, frozen: 5, xp: 91);
  @override
  Future<List<TaskItem>> loadTasks(String childId) async => [
        TaskItem(
          id: 'review-1',
          childId: childId,
          title: '今日错题复习',
          status: TaskStatus.ready,
          coinReward: 10,
          xpReward: 20,
          dueDate: DateTime.now(),
          accumulatedSeconds: 0,
        ),
      ];

  @override
  Future<void> createOneTimeTask({
    required String childId,
    required String title,
    required DateTime dueDate,
    required int coinReward,
    required int xpReward,
  }) async {}

  @override
  Future<void> start(String taskId) async {}

  @override
  Future<void> pause(String taskId) async {}

  @override
  Future<void> resume(String taskId) async {}

  @override
  Future<void> complete(String taskId) async {}

  @override
  Future<void> manualComplete(String taskId, String reason) async {}
}
