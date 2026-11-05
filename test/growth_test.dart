import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/growth/data/growth_repository.dart';
import 'package:learning_planet/features/growth/presentation/growth_screen.dart';
import 'package:learning_planet/features/growth/presentation/learning_event_screen.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';

class FakeGrowth implements GrowthRepository {
  bool failEquip = false, failAward = false;
  final equipment = <(String, String?)>[];
  final commands = <String>[];
  final configs = <Map<String, dynamic>>[];
  final appearance = <String, dynamic>{
    'avatar': 'astronaut',
    'pet': 'starter_star',
    'badge': null,
    'outfit': null,
  };
  @override
  Future<Map<String, dynamic>> load(String childId) async => {
    'xp': 1000,
    'streak': 7,
    'checkin_today': true,
    'today': '2026-11-04',
    'milestones': [3, 7],
    'appearance': Map<String, dynamic>.of(appearance),
    'assets': [
      {
        'key': 'starter_star',
        'title': '小星伙伴',
        'kind': 'pet',
        'unlocked': true,
        'minimum_level': null,
      },
      {
        'key': 'level5',
        'title': '星星徽章',
        'kind': 'badge',
        'unlocked': true,
        'minimum_level': 5,
      },
      {
        'key': 'level10',
        'title': '勇气披风',
        'kind': 'outfit',
        'unlocked': false,
        'minimum_level': 10,
      },
    ],
  };
  @override
  Future<void> equip(String childId, String slot, String? selection) async {
    equipment.add((slot, selection));
    if (failEquip) throw StateError('offline');
    appearance[slot] = selection;
  }

  @override
  Future<void> award(
    String childId,
    String commandId,
    Map<String, dynamic> config,
  ) async {
    commands.add(commandId);
    configs.add(Map.of(config));
    if (failAward) throw StateError('acknowledgement lost');
  }

  @override
  Future<void> challenge(
    String childId,
    String commandId,
    String title,
    int minimumSeconds,
  ) async {
    commands.add(commandId);
    configs.add({'title': title, 'minimum_seconds': minimumSeconds});
    if (failAward) throw StateError('acknowledgement lost');
  }

  @override
  Future<List<Map<String, dynamic>>> history(String childId) async => [];
}

void main() {
  Future<ProviderContainer> mount(
    WidgetTester tester,
    FakeGrowth repository, {
    bool parent = false,
    bool editor = false,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          growthRepositoryProvider.overrideWithValue(repository),
          taskRepositoryProvider.overrideWithValue(
            const UnconfiguredTaskRepository(),
          ),
          parentModeProvider.overrideWith((ref) => parent),
          parentFamilyIdProvider.overrideWith((ref) => 'family'),
          parentAuthorizedUntilProvider.overrideWith(
            (ref) => DateTime.now().add(const Duration(hours: 1)),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: editor
              ? const LearningEventScreen(
                  childId: 'child',
                  familyId: 'family',
                  today: '2026-11-04',
                )
              : const GrowthScreen(
                  childId: 'child',
                  familyId: 'family',
                  nickname: '小星',
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(editor ? LearningEventScreen : GrowthScreen)),
    );
  }

  testWidgets(
    'child sees real growth and equips only unlocked assets without parent controls',
    (tester) async {
      final repository = FakeGrowth();
      await mount(tester, repository);
      expect(find.text('Lv.5 · 1000 XP'), findsOneWidget);
      expect(find.text('连续完成 7 天'), findsOneWidget);
      expect(find.text('家长成长奖励'), findsNothing);
      await tester.scrollUntilVisible(
        find.widgetWithText(ChoiceChip, '星星徽章'),
        300,
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '星星徽章'));
      await tester.pumpAndSettle();
      expect(repository.equipment, [('badge', 'level5')]);
      final locked = find.widgetWithText(ChoiceChip, '勇气披风 · Lv.10解锁');
      await tester.scrollUntilVisible(locked, 200);
      expect(tester.widget<ChoiceChip>(locked).onSelected, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'failed equipment request does not optimistically unlock or replace appearance',
    (tester) async {
      final repository = FakeGrowth()..failEquip = true;
      await mount(tester, repository);
      await tester.scrollUntilVisible(
        find.widgetWithText(ChoiceChip, '自然观察员'),
        250,
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '自然观察员'));
      await tester.pumpAndSettle();
      expect(repository.appearance['avatar'], 'astronaut');
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '星际探索员'))
            .selected,
        true,
      );
      expect(find.textContaining('更换尚未确认'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('unauthorized user cannot enter reward form', (tester) async {
    await mount(tester, FakeGrowth(), editor: true);
    expect(find.textContaining('家长授权已到期'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'challenge validates then confirms and uses stable UUID after a lost acknowledgement',
    (tester) async {
      final repository = FakeGrowth()..failAward = true;
      await mount(tester, repository, parent: true, editor: true);
      await tester.tap(find.text('核对并提交'));
      await tester.pumpAndSettle();
      expect(find.text('请填写名称'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, '挑战名称'),
        '阅读新故事',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '最低有效时长（分钟）'),
        '10',
      );
      await tester.tap(find.text('核对并提交'));
      await tester.pumpAndSettle();
      expect(repository.commands, isEmpty);
      expect(find.textContaining('完成后获得30金币'), findsOneWidget);
      await tester.tap(find.text('确认提交'));
      await tester.pumpAndSettle();
      expect(repository.configs.single['minimum_seconds'], 600);
      expect(find.text('重试同一请求'), findsOneWidget);
      repository.failAward = false;
      await tester.ensureVisible(find.text('重试同一请求'));
      await tester.tap(find.text('重试同一请求'));
      await tester.pumpAndSettle();
      expect(repository.commands.length, 2);
      expect(repository.commands.toSet().length, 1);
      expect(find.textContaining('挑战已创建'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('PIN expiry during confirmation blocks award submission', (
    tester,
  ) async {
    final repository = FakeGrowth();
    final container = await mount(
      tester,
      repository,
      parent: true,
      editor: true,
    );
    await tester.enterText(find.widgetWithText(TextFormField, '挑战名称'), '阅读新故事');
    await tester.tap(find.text('核对并提交'));
    await tester.pumpAndSettle();
    container.read(parentModeProvider.notifier).state = false;
    await tester.pump();
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();
    expect(repository.commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'exam confirmation shows one package and sends both original candidates for server validation',
    (tester) async {
      final repository = FakeGrowth();
      await mount(tester, repository, parent: true, editor: true);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('考试进步').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, '事件名称（同一次考试请使用同一名称）'),
        '数学期中考试',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '家长确认说明'),
        '能主动检查答案',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('核对并提交'),
        300,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await Scrollable.ensureVisible(
        tester.element(find.widgetWithText(FilledButton, '核对并提交')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对并提交'));
      await tester.pumpAndSettle();
      expect(
        find.byType(AlertDialog),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .join('\n'),
      );
      expect(find.textContaining('结算 100 金币、50 XP，不叠加'), findsOneWidget);
      await tester.tap(find.text('确认提交'));
      await tester.pumpAndSettle();
      expect(repository.configs.single['score_coins'], 50);
      expect(repository.configs.single['improvement_coins'], 100);
      expect(repository.configs.single['kind'], 'exam');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'static growth cards remain usable with large text on small screens',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, FakeGrowth(), scale: 2);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('选择角色'), 300);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
