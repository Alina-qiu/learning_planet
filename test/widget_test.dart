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
import 'package:learning_planet/features/wrong_questions/presentation/review_question_editor.dart';

void main() {
  testWidgets('未配置服务的调试包直接说明限制，不提供无效登录入口', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      const LearningPlanetApp(
        authRepository: UnconfiguredAuthRepository(),
        familyRepository: UnconfiguredFamilyRepository(),
        taskRepository: UnconfiguredTaskRepository(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('调试版本尚未连接服务'), findsOneWidget);
    expect(find.text('发送验证码'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除最后一个孩子后仍可验证 PIN 管理原家庭', (tester) async {
    final family = FakeFamilyRepository();
    family.families.add(
      const Family(
        id: 'family-1',
        name: '空家庭',
        timezone: 'Asia/Shanghai',
        children: [],
      ),
    );
    await tester.pumpWidget(
      LearningPlanetApp(
        authRepository: FakeAuthRepository(
          const AuthSession(userId: 'parent-1'),
        ),
        familyRepository: family,
        taskRepository: FakeTaskRepository(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('管理家庭'), findsOneWidget);
    await tester.tap(find.text('管理家庭'));
    await tester.pumpAndSettle();
    expect(find.text('输入家长 PIN'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.text('验证'));
    await tester.pumpAndSettle();
    expect(find.text('添加孩子'), findsOneWidget);
    expect(find.byTooltip('孩子删除记录'), findsOneWidget);
    expect(family.createdFamilyName, isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('退出登录关闭持有上一账号数据的错题编辑路由', (tester) async {
    final repository = SwitchingAuthRepository();
    await tester.pumpWidget(
      LearningPlanetApp(
        authRepository: repository,
        familyRepository: FakeFamilyRepository.withChild(),
        taskRepository: FakeTaskRepository(),
      ),
    );
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('今日任务'))).push<void>(
      MaterialPageRoute(
        builder: (_) => const ReviewQuestionEditor(
          pinyin: false,
          initial: {
            'final_text': '上一账号的私有题目',
            'answers': ['private'],
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('上一账号的私有题目'), findsOneWidget);
    await repository.signOut();
    await tester.pumpAndSettle();
    expect(find.byType(ReviewQuestionEditor), findsNothing);
    expect(find.text('上一账号的私有题目'), findsNothing);
    expect(find.text('登录学习星球'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await repository.changes.close();
  });
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
    await tester.tap(find.text('发送验证码'));
    await tester.pump();

    expect(repository.lastOtpEmail, 'parent@example.com');
    expect(find.text('请检查邮箱并输入验证码，也可以查看垃圾邮件文件夹。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
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
        authRepository: FakeAuthRepository(
          const AuthSession(userId: 'parent-1'),
        ),
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
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('创建并开始'));
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
  Future<void> verifyEmailOtp(
    String email,
    String code, {
    required bool Function() isCurrent,
  }) async {}

  @override
  Future<void> signOut() async {}

  @override
  Stream<AuthSession?> watchSession() => Stream.value(currentSession);
}

class SwitchingAuthRepository extends FakeAuthRepository {
  SwitchingAuthRepository() : super(const AuthSession(userId: 'parent-1'));
  final changes = StreamController<AuthSession?>.broadcast();
  @override
  Stream<AuthSession?> watchSession() async* {
    yield currentSession;
    yield* changes.stream;
  }

  @override
  Future<void> signOut() async => changes.add(null);
}

class FakeFamilyRepository implements FamilyRepository {
  @override
  Future<void> revokeParentAuthorization() async {}
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
    Map<String, String> textbookLabels = const {},
    String avatarKey = 'star',
  }) async {
    createdFamilyName = familyName;
    createdChildNickname = childNickname;
  }

  @override
  Future<void> createChild({
    required String familyId,
    required String nickname,
    required int grade,
    Map<String, String> textbookLabels = const {},
    String avatarKey = 'star',
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
  }) async => ParentPinVerification(
    verified: true,
    remainingAttempts: 5,
    authorizedUntil: DateTime.now().add(const Duration(minutes: 10)),
  );

  @override
  Future<void> updateChild({
    required String childId,
    required String nickname,
    required int grade,
    Map<String, String> textbookLabels = const {},
    String avatarKey = 'star',
    int expectedVersion = 0,
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
  Future<void> abandon(String taskId) async {}

  @override
  Future<void> manualComplete(String taskId, String reason) async {}
}
