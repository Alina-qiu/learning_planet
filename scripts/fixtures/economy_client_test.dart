// Actual Auth + PostgreSQL through PostgREST. No direct SQL or injected sessions.
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/features/auth_family/data/auth_repository.dart';
import 'package:learning_planet/features/auth_family/data/email_otp.dart';
import 'package:learning_planet/features/auth_family/data/family_repository.dart';
import 'package:learning_planet/features/economy/data/economy_commands.dart';
import 'package:learning_planet/features/economy/data/economy_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class EconomyNetwork extends http.BaseClient {
  final inner = http.Client();
  bool offline = false, loseCommandReply = false;
  int lost = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (offline) throw const SocketException('Simulated unreachable backend');
    final response = await inner.send(request);
    if (loseCommandReply &&
        response.statusCode == 200 &&
        request.url.path.endsWith('/resolve_economy_command')) {
      loseCommandReply = false;
      lost++;
      await response.stream.drain<void>();
      throw http.ClientException(
        'Injected reply loss after successful server commit',
      );
    }
    return response;
  }

  @override
  void close() => inner.close();
}

void main() {
  final raw = Platform.environment['LP_ECONOMY_CONFIG'];
  if (raw == null) {
    throw StateError('Run node scripts/test_economy_integration.mjs');
  }
  final config = jsonDecode(raw) as Map<String, dynamic>;
  final url = config['url'] as String, key = config['anon'] as String;
  final uri = Uri.parse(url);
  if (uri.scheme != 'http' || uri.host != '127.0.0.1') {
    throw StateError('Disposable loopback backend required');
  }
  const uuid = Uuid();

  Future<({SupabaseClient client, EconomyNetwork network})> account() async {
    final network = EconomyNetwork();
    final client = SupabaseClient(
      url,
      key,
      httpClient: network,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    final auth = SupabaseAuthRepository(
      client,
      emailOtp: EmailOtpTransport(
        () => GoTrueClient(
          url: '$url/auth/v1',
          headers: {'apikey': key},
          autoRefreshToken: false,
          flowType: AuthFlowType.implicit,
        ),
      ),
    );
    addTearDown(() async {
      await auth.dispose();
      await client.dispose();
      network.close();
    });
    final email = 'economy-${uuid.v4()}@example.test';
    await auth.sendEmailOtp(email);
    final mail = await http.get(
      Uri.parse('$url/__test/mail').replace(queryParameters: {'email': email}),
      headers: {'x-test-mailbox-key': config['mailboxKey'] as String},
    );
    expect(mail.statusCode, 200);
    await auth.verifyEmailOtp(
      email,
      (jsonDecode(mail.body) as Map)['code'] as String,
      isCurrent: () => true,
    );
    return (client: client, network: network);
  }

  Future<({String family, String child, Map<String, dynamic> reward})> seed(
    SupabaseClient client,
  ) async {
    final families = SupabaseFamilyRepository(client);
    await families.createFamilyWithChild(
      familyName: '兑换验证家庭',
      timezone: 'Asia/Shanghai',
      childNickname: '小星',
      grade: 2,
    );
    final family = (await families.loadFamilies()).single;
    final child = family.children.single.id;
    await families.setParentPin(familyId: family.id, pin: '2468');
    expect(
      (await families.verifyParentPin(
        familyId: family.id,
        pin: '2468',
      )).verified,
      true,
    );
    final economy = SupabaseEconomyRepository(client);
    await economy.adjust(child, {
      'coins': 300,
      'xp_amount': 0,
      'reason': '本机兑换流程验证',
      'command_id': uuid.v4(),
    });
    await economy.saveReward(family.id, {
      'title': '家庭电影',
      'cost': 120,
      'rules': '周末一起观看',
      'stock_total': 2,
    });
    final view = await economy.load(child, family.id);
    expect(view['overview']['coin_balance'], 300);
    return (
      family: family.id,
      child: child,
      reward: Map<String, dynamic>.from(
        (view['rewards'] as List).single as Map,
      ),
    );
  }

  Future<List<Map<String, dynamic>>> ledger(
    SupabaseClient client,
    String child,
  ) => client
      .from('ledger_entries')
      .select('id,source_type,amount,frozen_delta')
      .eq('child_id', child)
      .order('id');
  EconomyCommands commands(SupabaseClient client, OfflineStore store) =>
      EconomyCommands(
        store: store,
        remote: SupabaseEconomyCommandRemote(client),
        owner: () => client.auth.currentUser?.id,
        authorized: (_) => true,
        authorizationRevision: () => 1,
      );

  test(
    'real freeze reject approve and fulfillment preserve wallet and ledger with repeated fulfillment',
    () async {
      final user = await account(), scope = await seed(user.client);
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      final repository = SupabaseEconomyRepository(user.client, store: store);
      final requests = commands(user.client, store);
      Future<EconomyCommand> request() async {
        final value = await requests.prepare(
          scope.child,
          scope.family,
          {
            'kind': 'redeem',
            'reward_id': scope.reward['id'],
            'version': scope.reward['version'],
          },
          {'title': scope.reward['title'], 'cost': 120},
        );
        return requests.resolve(
          scope.child,
          scope.family,
          value.requestId,
          'submit',
        );
      }

      final first = await request();
      var view = await repository.load(scope.child, scope.family);
      expect(view['overview']['coin_balance'], 180);
      expect(view['overview']['frozen_balance'], 120);
      await repository.transition(
        first.toJson()['redemption_id'] as String,
        'reject',
        '本周安排已满',
      );
      view = await repository.load(scope.child, scope.family);
      expect(view['overview']['coin_balance'], 300);
      expect(view['overview']['frozen_balance'], 0);
      expect(view['overview']['reconciled'], true);
      await requests.acknowledge(scope.child, scope.family, first.requestId);
      final second = await request(),
          id = second.toJson()['redemption_id'] as String;
      await repository.transition(id, 'approve', '已安排周末');
      await repository.transition(id, 'fulfill', '已一起观看');
      final before = await ledger(user.client, scope.child);
      await repository.transition(id, 'fulfill', '已一起观看');
      expect(await ledger(user.client, scope.child), before);
      view = await repository.load(scope.child, scope.family);
      expect(view['overview']['coin_balance'], 180);
      expect(view['overview']['frozen_balance'], 0);
      expect(view['overview']['reconciled'], true);
      expect((view['redemptions'] as List).map((r) => r['status']).toSet(), {
        'rejected',
        'fulfilled',
      });
      expect((view['rewards'] as List).single['stock_available'], 1);
    },
  );

  test(
    'real first pages survive file reopen offline and refresh changed server prices on reconnection',
    () async {
      final user = await account(), scope = await seed(user.client);
      final directory = await Directory.systemTemp.createTemp(
        'economy-http-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/cache.sqlite');
      var store = OfflineStore(NativeDatabase(file));
      addTearDown(() => store.close());
      var repository = SupabaseEconomyRepository(user.client, store: store);
      final online = await repository.load(scope.child, scope.family);
      await store.close();
      repository.dispose();
      await SupabaseEconomyRepository(user.client).saveReward(scope.family, {
        'title': '家庭电影',
        'cost': 140,
        'expected_version': scope.reward['version'],
        'stock_total': 2,
      }, rewardId: scope.reward['id'] as String);
      store = OfflineStore(NativeDatabase(file));
      repository = SupabaseEconomyRepository(user.client, store: store);
      user.network.offline = true;
      final offline = await repository.load(scope.child, scope.family);
      expect(offline['offline'], true);
      expect(offline['fetched_at'], online['fetched_at']);
      expect((offline['rewards'] as List).single['cost'], 120);
      user.network.offline = false;
      final fresh = await repository.load(scope.child, scope.family);
      expect(fresh['offline'], false);
      expect((fresh['rewards'] as List).single['cost'], 140);
    },
  );

  test(
    'real committed redemption with lost response restores original request and never freezes twice',
    () async {
      final user = await account(), scope = await seed(user.client);
      final directory = await Directory.systemTemp.createTemp(
        'economy-http-command-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/cache.sqlite');
      var store = OfflineStore(NativeDatabase(file));
      addTearDown(() => store.close());
      await SupabaseEconomyRepository(
        user.client,
        store: store,
      ).load(scope.child, scope.family);
      var queue = commands(user.client, store);
      final request = await queue.prepare(
        scope.child,
        scope.family,
        {
          'kind': 'redeem',
          'reward_id': scope.reward['id'],
          'version': scope.reward['version'],
        },
        {'title': '家庭电影', 'cost': 120},
      );
      user.network.loseCommandReply = true;
      await expectLater(
        queue.resolve(scope.child, scope.family, request.requestId, 'submit'),
        throwsA(isA<http.ClientException>()),
      );
      expect(user.network.lost, 1);
      await store.close();
      store = OfflineStore(NativeDatabase(file));
      queue = commands(user.client, store);
      user.network.offline = true;
      expect(
        (await queue.pending(scope.child, scope.family))!.requestId,
        request.requestId,
      );
      await expectLater(
        SupabaseEconomyRepository(
          user.client,
          store: store,
        ).load(scope.child, scope.family),
        throwsA(isA<SocketException>()),
      );
      user.network.offline = false;
      final receipt = await queue.resolve(
        scope.child,
        scope.family,
        request.requestId,
        'inspect',
      );
      expect(receipt.status, 'applied');
      final before = await ledger(user.client, scope.child);
      await queue.resolve(
        scope.child,
        scope.family,
        request.requestId,
        'submit',
      );
      expect(await ledger(user.client, scope.child), before);
      final view = await SupabaseEconomyRepository(
        user.client,
        store: store,
      ).load(scope.child, scope.family);
      expect(view['overview']['coin_balance'], 180);
      expect(view['overview']['frozen_balance'], 120);
      expect(view['overview']['reconciled'], true);
      expect(view['redemptions'], hasLength(1));
    },
  );

  test(
    'real foreign account cannot read the family or reuse another accounts cached snapshot',
    () async {
      final user = await account(),
          scope = await seed(user.client),
          outsider = await account();
      final store = OfflineStore(NativeDatabase.memory());
      addTearDown(store.close);
      await SupabaseEconomyRepository(
        user.client,
        store: store,
      ).load(scope.child, scope.family);
      final other = SupabaseEconomyRepository(outsider.client, store: store);
      await expectLater(
        other.load(scope.child, scope.family),
        throwsA(isA<PostgrestException>()),
      );
      outsider.network.offline = true;
      await expectLater(
        other.load(scope.child, scope.family),
        throwsA(isA<SocketException>()),
      );
      user.network.offline = true;
      expect(
        (await SupabaseEconomyRepository(
          user.client,
          store: store,
        ).load(scope.child, scope.family))['offline'],
        true,
      );
    },
  );

  test(
    'real adjustment audit reveals original actor and reason only with current server PIN',
    () async {
      final user = await account(), scope = await seed(user.client);
      final repository = SupabaseEconomyRepository(
        user.client,
        includeInactive: (_) => true,
      );
      final view = await repository.load(scope.child, scope.family);
      expect(view['family_timezone'], 'Asia/Shanghai');
      final entry =
          (view['ledger'] as List).firstWhere(
                (row) => row['asset_type'] == 'coin',
              )
              as Map;
      final before = await ledger(user.client, scope.child);
      final details = await repository.adjustmentDetails(
        scope.child,
        scope.family,
        entry['id'] as String,
      );
      expect(details.audit!['reason'], '本机兑换流程验证');
      expect(details.audit!['coins'], 300);
      expect(details.audit!['actor']['is_self'], true);
      expect(
        details.audit!['actor']['email'],
        user.client.auth.currentUser!.email,
      );
      expect(details.entry.containsKey('idempotency_key'), false);
      await user.client.rpc<void>(
        'revoke_parent_authorization',
        params: {'target_family_id': scope.family},
      );
      await expectLater(
        repository.adjustmentDetails(
          scope.child,
          scope.family,
          entry['id'] as String,
        ),
        throwsA(isA<PostgrestException>()),
      );
      expect(await ledger(user.client, scope.child), before);
    },
  );
}
