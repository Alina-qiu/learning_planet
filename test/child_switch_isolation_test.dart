import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/auth_family/application/auth_providers.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/domain/auth_session.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart';
import 'package:learning_planet/features/auth_family/presentation/auth_gate.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/tasks/domain/task_item.dart';
import 'package:learning_planet/features/tasks/domain/wallet_summary.dart';
import 'package:learning_planet/features/wrong_questions/data/review_repository.dart';

import 'review_module_test.dart' show FakeReviewRepository;
import 'widget_test.dart'
    show FakeAuthRepository, FakeFamilyRepository, FakeTaskRepository;

const _children = [
  ChildProfile(id: 'a', familyId: 'family', nickname: '辰辰', grade: 2),
  ChildProfile(id: 'b', familyId: 'family', nickname: '月月', grade: 4),
];

class _Responses {
  final requests = <(String, String)>{};
  final waiting = <(String, String), Completer<void>>{};

  void hold(String child) {
    for (final resource in ['tasks', 'wallet', 'questions']) {
      waiting[(child, resource)] = Completer<void>();
    }
  }

  Future<void> read(String child, String resource) async {
    final pending = waiting[(child, resource)];
    if (pending != null) {
      requests.add((child, resource));
      await pending.future;
    }
  }

  void release(String child, String resource) =>
      waiting.remove((child, resource))!.complete();
}

class _Tasks extends FakeTaskRepository {
  _Tasks(this.responses);
  final _Responses responses;

  @override
  Future<List<TaskItem>> loadTasks(String childId) async {
    await responses.read(childId, 'tasks');
    return [
      TaskItem(
        id: 'task-$childId',
        childId: childId,
        title: '任务 $childId',
        status: TaskStatus.ready,
        coinReward: 1,
        xpReward: 2,
        dueDate: DateTime(2020),
        accumulatedSeconds: 0,
      ),
    ];
  }

  @override
  Future<WalletSummary> loadWallet(String childId) async {
    await responses.read(childId, 'wallet');
    return switch (childId) {
      'a' => const WalletSummary(coins: 17, frozen: 2, xp: 41),
      'b' => const WalletSummary(coins: 93, frozen: 7, xp: 120),
      _ => throw StateError('Unexpected child $childId'),
    };
  }
}

class _Questions extends FakeReviewRepository {
  _Questions(this.responses);
  final _Responses responses;

  @override
  Future<List<Map<String, dynamic>>> questions(String childId) async {
    await responses.read(childId, 'questions');
    return [
      {
        'id': 'question-$childId',
        'final_text': '错题 $childId',
        'subject': 'math',
        'review_kind': 'question',
        'archived': false,
        'mastery_status': 'practicing',
        'wrong_count': 1,
        'review_attempts': 0,
      },
    ];
  }
}

void main() {
  testWidgets(
    'switching the selected child isolates tasks, wallet and notebook even when the previous child replies late',
    (tester) async {
      tester.view.physicalSize = const Size(480, 1140);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final responses = _Responses();
      final family = FakeFamilyRepository()
        ..families.add(
          const Family(
            id: 'family',
            name: '同一家庭',
            timezone: 'Asia/Shanghai',
            children: _children,
          ),
        );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authRepositoryProvider.overrideWithValue(
              FakeAuthRepository(const AuthSession(userId: 'parent')),
            ),
            familyRepositoryProvider.overrideWithValue(family),
            taskRepositoryProvider.overrideWithValue(_Tasks(responses)),
            reviewRepositoryProvider.overrideWithValue(_Questions(responses)),
          ],
          child: const MaterialApp(home: AuthGate()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('进入家长模式'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1234');
      await tester.tap(find.text('验证'));
      await tester.pumpAndSettle();
      expect(find.text('家长模式'), findsOneWidget);
      const aWallet = '金币 17 · 冻结 2 · XP 41';
      const bWallet = '金币 93 · 冻结 7 · XP 120';
      expect(find.text('辰辰'), findsOneWidget);
      expect(find.text('任务 a'), findsOneWidget);
      expect(find.text(aWallet), findsOneWidget);
      expect(find.text('任务 b'), findsNothing);
      expect(find.text(bWallet), findsNothing);
      final notebook = find.text('错题本与拼音复习');
      await tester.tap(notebook);
      await tester.pumpAndSettle();
      expect(find.text('错题 a'), findsOneWidget);
      expect(find.text('错题 b'), findsNothing);

      // Drives route/menu transitions while the old child and new child have
      // outstanding reads. An indeterminate progress indicator cannot settle.
      Future<void> frames() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
      }

      responses.hold('a');
      responses.hold('b');
      await tester.tap(find.byTooltip('刷新'));
      await frames();
      await tester.pageBack();
      await frames();
      expect(
        responses.requests,
        containsAll([('a', 'tasks'), ('a', 'wallet'), ('a', 'questions')]),
      );
      await tester.tap(find.byTooltip('切换孩子'));
      await frames();
      await tester.tap(find.text('月月'));
      await frames();
      expect(find.text('月月'), findsOneWidget);
      expect(find.text('家长模式'), findsNothing);
      expect(find.text('任务 a'), findsNothing);
      expect(find.text(aWallet), findsNothing);
      expect(
        responses.requests,
        containsAll([('b', 'tasks'), ('b', 'wallet')]),
      );
      responses.release('a', 'tasks');
      await frames();
      expect(find.text('任务 a'), findsNothing);
      expect(find.text(aWallet), findsNothing);
      responses.release('b', 'tasks');
      responses.release('b', 'wallet');
      await frames();
      expect(find.text('任务 b'), findsOneWidget);
      expect(find.text(bWallet), findsOneWidget);
      responses.release('a', 'wallet');
      await frames();
      expect(find.text(bWallet), findsOneWidget);
      expect(find.text('任务 a'), findsNothing);
      expect(find.text(aWallet), findsNothing);

      await tester.tap(notebook);
      await frames();
      expect(responses.requests, contains(('b', 'questions')));
      expect(find.text('错题 a'), findsNothing);
      responses.release('b', 'questions');
      await frames();
      expect(find.text('错题 b'), findsOneWidget);
      responses.release('a', 'questions');
      await tester.pumpAndSettle();
      expect(find.text('错题 b'), findsOneWidget);
      expect(find.text('错题 a'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
