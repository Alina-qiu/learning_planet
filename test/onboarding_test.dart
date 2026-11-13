import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Family;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/data/family_repository.dart';
import 'package:learning_planet/features/auth_family/data/offline_family_repository.dart';
import 'package:learning_planet/features/auth_family/data/onboarding_repository.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart';
import 'package:learning_planet/features/auth_family/presentation/child_profile_editor.dart';
import 'package:learning_planet/features/auth_family/presentation/getting_started_screen.dart';
import 'package:learning_planet/features/auth_family/presentation/family_management_screen.dart';
import 'package:learning_planet/features/tasks/domain/schedule_config.dart';
import 'widget_test.dart' show FakeFamilyRepository;
import 'package:learning_planet/features/reports/data/configuration_time_recorder.dart';

class ProfileFamily extends FakeFamilyRepository {
  Map<String, dynamic>? saved;
  bool fail = true;
  @override
  Future<void> updateChild({
    required String childId,
    required String nickname,
    required int grade,
    Map<String, String> textbookLabels = const {},
    String avatarKey = 'star',
    int expectedVersion = 0,
  }) async {
    saved = {
      'id': childId,
      'nickname': nickname,
      'grade': grade,
      'textbooks': textbookLabels,
      'avatar': avatarKey,
      'version': expectedVersion,
    };
    if (fail) throw StateError('档案已在另一处修改，请刷新');
  }
}

class StarterRepository implements OnboardingRepository {
  final data = <String, dynamic>{
    'child': {
      'id': 'child',
      'nickname': '小火箭',
      'guide_step': 0,
      'starter_task_preset': 'study10',
      'starter_rules_at': null,
      'onboarding_completed_at': null,
    },
    'today': '2026-11-05',
    'daily_limit': 150,
    'active_rewards': 0,
    'has_task': false,
    'appearance': {'avatar': 'astronaut', 'pet': 'starter_star'},
    'pets': [
      {'key': 'starter_star', 'title': '小星伙伴'},
      {'key': 'starter_rabbit', 'title': '小兔伙伴'},
    ],
  };
  bool loseReply = false;
  final advances = <int>[];
  final configurations = <StarterRulesConfig>[];
  final tasks = <ScheduleConfig>[];
  int finishes = 0;
  @override
  Future<Map<String, dynamic>> load(String childId) async =>
      jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
  @override
  Future<void> advance(String childId, int step, String? selection) async {
    advances.add(step);
    (data['child'] as Map)['guide_step'] = step + 1;
    if (step < 2) {
      (data['appearance'] as Map)[step == 0 ? 'avatar' : 'pet'] = selection;
    }
    if (loseReply) {
      loseReply = false;
      throw const SocketException('回执丢失');
    }
  }

  @override
  Future<void> configure(
    String childId,
    String preset,
    int dailyLimit,
    List<String> rewards,
  ) async {
    configurations.add(StarterRulesConfig(preset, dailyLimit, rewards));
    (data['child'] as Map)['starter_rules_at'] = '2026-11-04T08:00:00Z';
  }

  @override
  Future<void> firstTask(String childId, ScheduleConfig config) async {
    tasks.add(config);
    data['has_task'] = true;
  }

  @override
  Future<void> finish(String childId) async {
    finishes++;
  }
}

void main() {
  const profile = ChildProfile(
    id: 'child',
    familyId: 'family',
    nickname: '小火箭',
    grade: 3,
    textbookLabels: {'chinese': '统编版'},
    avatarKey: 'rocket',
    profileVersion: 7,
    guideStep: 1,
  );
  Future<void> show(
    WidgetTester tester,
    Widget page, {
    ProfileFamily? family,
    StarterRepository? starter,
    bool parent = true,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configurationTimeRecorderProvider.overrideWithValue(null),
          familyRepositoryProvider.overrideWithValue(family ?? ProfileFamily()),
          activeParentFamilyProvider.overrideWithValue(
            parent ? 'family' : null,
          ),
          if (starter != null)
            onboardingRepositoryProvider.overrideWithValue(starter),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(builder: (_) => page),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String label) async {
    final finder = find.text(label);
    await tester.scrollUntilVisible(
      finder,
      160,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 45,
    );
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);
  test(
    'extended profiles survive online cache and offline reload with legacy defaults and account isolation',
    () async {
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      var online = true, owner = 'parent';
      final client = SupabaseClient(
        'https://example.test',
        'key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          if (!online) throw const SocketException('offline');
          final value = switch (request.url.path.split('/').last) {
            'families' => [
              {'id': 'family', 'name': '家庭', 'timezone': 'Asia/Shanghai'},
            ],
            'children' => [profile.toJson()],
            'accept_family_invitations' => null,
            _ => <Object>[],
          };
          return http.Response(
            jsonEncode(value),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final repository = OfflineFamilyRepository(client, store, () => owner);
      expect(
        (await repository.loadFamilies()).single.children.single.toJson(),
        profile.toJson(),
      );
      online = false;
      expect(
        (await repository.loadFamilies()).single.children.single.toJson(),
        profile.toJson(),
      );
      owner = 'another-account';
      await expectLater(
        repository.loadFamilies(),
        throwsA(isA<SocketException>()),
      );
      final legacy = ChildProfile.fromJson({
        'id': 'old',
        'family_id': 'family',
        'nickname': '旧档案',
        'grade': 2,
      });
      expect(legacy.avatarKey, 'star');
      expect(legacy.textbookLabels, isEmpty);
      expect(legacy.guideStep, 0);
      expect(legacy.onboardingCompletedAt, isNull);
    },
  );
  test(
    'repositories send versioned profiles and authoritative onboarding RPC arguments including real schedules',
    () async {
      final calls = <String, Map<String, dynamic>>{};
      final client = SupabaseClient(
        'https://example.test',
        'key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          final method = request.url.path.split('/').last;
          calls[method] = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(
              method == 'advance_child_guide'
                  ? 2
                  : method == 'create_starter_task'
                  ? 'template'
                  : null,
            ),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      await SupabaseFamilyRepository(client).updateChild(
        childId: 'child',
        nickname: '小火箭',
        grade: 3,
        textbookLabels: profile.textbookLabels,
        avatarKey: 'rocket',
        expectedVersion: 7,
      );
      final repository = SupabaseOnboardingRepository(client);
      await repository.configure('child', 'study10', 150, ['book']);
      await repository.advance('child', 1, 'starter_rabbit');
      final config = ScheduleConfig(
        title: '专注10分钟',
        startsOn: DateTime(2026, 11, 5),
        endsOn: DateTime(2026, 11, 5),
        recurrence: ScheduleRecurrence.daily,
        startTime: '16:00',
        dueTime: '20:00',
        coins: 15,
        xp: 12,
        expectedMinutes: 10,
      );
      await repository.firstTask('child', config);
      await repository.finish('child');
      expect(calls['update_child_profile']!['expected_version'], 7);
      expect(calls['update_child_profile']!['preferences'], {
        'textbook_labels': profile.textbookLabels,
        'avatar_key': 'rocket',
      });
      expect(calls['advance_child_guide'], {
        'target_child_id': 'child',
        'expected_step': 1,
        'selection': 'starter_rabbit',
      });
      expect(calls['configure_starter_rules']!['reward_keys'], ['book']);
      expect(calls['create_starter_task']!['config'], config.toJson());
      expect(
        calls.keys.any(
          (key) => key.contains('wallet') || key.contains('award'),
        ),
        false,
      );
    },
  );
  testWidgets(
    'profile editor retains a conflicting draft and sends its original version on a narrow enlarged screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final family = ProfileFamily();
      await show(
        tester,
        const ChildProfileEditor(familyId: 'family', child: profile),
        family: family,
        scale: 1.3,
      );
      await tester.enterText(field('孩子昵称'), ' 新昵称 ');
      await tester.ensureVisible(find.text('绿叶'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '绿叶'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(field('数学教材版本'));
      await tester.enterText(field('数学教材版本'), ' 校本数学 ');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tap(tester, '保存');
      expect(find.textContaining('档案尚未保存'), findsOneWidget);
      expect(family.saved, {
        'id': 'child',
        'nickname': '新昵称',
        'grade': 3,
        'textbooks': {'chinese': '统编版', 'math': '校本数学'},
        'avatar': 'leaf',
        'version': 7,
      });
      expect(find.text(' 新昵称 '), findsOneWidget);
      expect(tester.takeException(), isNull);
      family.fail = false;
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tap(tester, '保存');
      expect(find.text('打开'), findsOneWidget);
    },
  );
  testWidgets(
    'family cards keep long textbook tags readable with controls below the profile on narrow screens',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final family = ProfileFamily();
      family.families.add(
        const Family(
          id: 'family',
          name: '小火箭家',
          timezone: 'Asia/Shanghai',
          children: [profile],
        ),
      );
      await show(
        tester,
        const FamilyManagementScreen(),
        family: family,
        scale: 1.3,
      );
      await tester.scrollUntilVisible(
        find.byTooltip('编辑'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getTopLeft(find.byTooltip('编辑')).dy,
        greaterThan(tester.getBottomLeft(find.textContaining('语文：统编版')).dy),
      );
      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();
      expect(find.text('编辑孩子档案'), findsOneWidget);
      expect(find.text('统编版'), findsOneWidget);
    },
  );
  testWidgets(
    'guide starts from the saved step and refresh recovers a committed step whose reply was lost',
    (tester) async {
      final repository = StarterRepository();
      (repository.data['child'] as Map)['guide_step'] = 1;
      repository.loseReply = true;
      await show(
        tester,
        const GettingStartedScreen(childId: 'child', familyId: 'family'),
        starter: repository,
      );
      expect(find.text('孩子引导 · 第 2 / 3 步'), findsOneWidget);
      await tap(tester, '小兔伙伴');
      await tap(tester, '确认伙伴，下一步');
      expect(find.textContaining('操作尚未确认'), findsOneWidget);
      expect(repository.advances, [1]);
      await tester.tap(find.byTooltip('刷新引导进度'));
      await tester.pumpAndSettle();
      expect(find.text('孩子引导 · 第 3 / 3 步'), findsOneWidget);
      await tap(tester, '我知道怎样开始和兑换奖励了');
      await tap(tester, '完成三步引导');
      expect(repository.advances, [1, 2]);
      await tester.scrollUntilVisible(
        find.text('设置完成，开始冒险'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, '设置完成，开始冒险'),
            )
            .onPressed,
        isNull,
      );
      expect(repository.finishes, 0);
    },
  );
  testWidgets(
    'child chooses a role and partner then acknowledges instructions; completed setup returns home',
    (tester) async {
      final repository = StarterRepository();
      repository.data['has_task'] = true;
      (repository.data['child'] as Map)['starter_rules_at'] = '2026-11-04';
      await show(
        tester,
        const GettingStartedScreen(childId: 'child', familyId: 'family'),
        starter: repository,
      );
      await tap(tester, '自然观察员');
      await tap(tester, '确认角色，下一步');
      await tap(tester, '小兔伙伴');
      await tap(tester, '确认伙伴，下一步');
      expect((repository.data['appearance'] as Map)['avatar'], 'explorer');
      expect((repository.data['appearance'] as Map)['pet'], 'starter_rabbit');
      await tap(tester, '我知道怎样开始和兑换奖励了');
      await tap(tester, '完成三步引导');
      await tap(tester, '设置完成，开始冒险');
      expect(repository.finishes, 1);
      expect(find.text('打开'), findsOneWidget);
    },
  );
  testWidgets(
    'starter rules validate the cap after scrolling and keep default task rewards and selected shop entries',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = StarterRepository();
      await show(
        tester,
        const GettingStartedScreen(childId: 'child', familyId: 'family'),
        starter: repository,
        scale: 1.2,
      );
      await tap(tester, '家长设置积分与奖励');
      await tester.enterText(field('每日金币软上限（0–10000）'), '-1');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tap(tester, '确认保存初始规则');
      expect(repository.configurations, isEmpty);
      expect(find.text('请输入0至10000的整数'), findsOneWidget);
      await tester.ensureVisible(field('每日金币软上限（0–10000）'));
      await tester.enterText(field('每日金币软上限（0–10000）'), '150');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tap(tester, '确认保存初始规则');
      final saved = repository.configurations.single;
      expect(saved.preset, 'study10');
      expect(saved.limit, 150);
      expect(saved.rewards, containsAll(['cartoon', 'book']));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'first task uses the chosen preset and family date and cancel creates nothing',
    (tester) async {
      final repository = StarterRepository();
      await show(
        tester,
        const GettingStartedScreen(childId: 'child', familyId: 'family'),
        starter: repository,
      );
      await tap(tester, '创建第一个任务');
      expect(find.text('开始：2026-11-05'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(repository.tasks, isEmpty);
      await tap(tester, '创建第一个任务');
      await tap(tester, '保存配置');
      final saved = repository.tasks.single;
      expect(saved.coins, 15);
      expect(saved.xp, 12);
      expect(saved.expectedMinutes, 10);
      expect(saved.startsOn, DateTime(2026, 11, 5));
      expect(find.text('首个任务已创建'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'parent configuration asks for PIN while child guide can continue and cancel performs no writes',
    (tester) async {
      final repository = StarterRepository();
      await show(
        tester,
        const GettingStartedScreen(childId: 'child', familyId: 'family'),
        starter: repository,
        parent: false,
      );
      await tap(tester, '家长设置积分与奖励');
      expect(find.text('输入家长 PIN'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repository.configurations, isEmpty);
      await tap(tester, '确认角色，下一步');
      expect(repository.advances, [0]);
    },
  );
}
