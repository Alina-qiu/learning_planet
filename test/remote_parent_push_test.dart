import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/security/device_secrets.dart';
import 'package:learning_planet/features/notifications/data/remote_parent_push.dart';
import 'package:learning_planet/features/notifications/domain/parent_notification.dart';
import 'package:learning_planet/features/notifications/presentation/remote_push_lifecycle.dart';
import 'package:learning_planet/features/auth_family/data/auth_repository.dart';
import 'package:learning_planet/features/tasks/data/notification_scheduler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/mock_supabase.dart';

const settings = ParentNotificationSettings(enabled: true, version: 2);

class Secrets implements DeviceSecrets {
  final values = <String, String>{};
  bool failRead = false;
  bool Function(Map<String, dynamic>)? failWrite;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw const LocalDataException('locked');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite?.call(jsonDecode(value) as Map<String, dynamic>) == true) {
      throw const LocalDataException('write failed');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class Native implements ParentPushNative {
  int revision = 0, tokenCalls = 0, enables = 0;
  bool enabled = false, configured = true, available = true, permit = true;
  String transport = 'hms';
  String? deviceToken = 'device-token';
  Completer<int>? disableAck;
  Map<String, dynamic>? gate;
  @override
  Future<Map<String, dynamic>> availability() async => {
    'revision': revision,
    'enabled': enabled,
    'configured': configured,
    'available': available,
    'transport': transport,
  };
  @override
  Future<int> disable({bool startup = false}) async {
    enabled = false;
    final next = ++revision;
    final held = disableAck;
    disableAck = null;
    return held == null ? next : await held.future;
  }

  @override
  Future<String?> token(int expected) async {
    tokenCalls++;
    return expected == revision && permit ? deviceToken : null;
  }

  @override
  Future<bool> enable(Map<String, dynamic> values) async {
    if (values['revision'] != revision || !permit) return false;
    enables++;
    gate = Map.of(values);
    enabled = true;
    return true;
  }
}

class Remote implements ParentPushRemote {
  final calls = <String>[];
  final revocations = <Map<String, dynamic>>[];
  Map<String, dynamic>? prepared;
  bool offline = false;
  FutureOr<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
  intercept;
  Future<void> Function(Map<String, dynamic>)? interceptRevoke;
  Map<String, dynamic> reply(String name, Map<String, dynamic> p) {
    if (name == 'prepare_parent_push_device') prepared = Map.of(p);
    return {
      'device_id': p['target_device_id'],
      'family_id': prepared!['target_family_id'],
      'scope_nonce': prepared!['requested_nonce'],
      'intent_version': p['requested_version'],
      'state': name == 'prepare_parent_push_device' ? 'prepared' : 'enabled',
      'transport': p['requested_transport'] ?? 'hms',
      'server_time': '2026-11-05T04:00:00Z',
      'expires_at': '2026-12-05T04:00:00Z',
    };
  }

  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    calls.add(name);
    if (offline) throw StateError('offline');
    return intercept == null
        ? reply(name, params)
        : await intercept!(name, params);
  }

  @override
  Future<void> revoke(Map<String, dynamic> params) async {
    revocations.add(Map.of(params));
    if (offline) throw StateError('offline');
    await interceptRevoke?.call(params);
  }
}

class Harness {
  final native = Native(), remote = Remote(), secrets = Secrets();
  String? owner = 'parent-a';
  int privacy = 0;
  bool pin = true;
  late RemoteParentPush push = controller();
  RemoteParentPush controller({bool configured = true}) => RemoteParentPush(
    native: native,
    remote: remote,
    secrets: secrets,
    backendUrl: 'https://project.test',
    accountId: () => owner,
    privacyGeneration: () => privacy,
    configured: configured,
  );
  Future<void> enable() =>
      push.enable('family', settings, canConfigure: () => pin);
  Map<String, dynamic> get row =>
      jsonDecode(secrets.values[push.storageKey]!) as Map<String, dynamic>;
}

Future<void> drain() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'failed native family revocation retains its scope for a later retry',
    () async {
      final h = Harness();
      await h.enable();
      final pending = Completer<int>();
      h.native.disableAck = pending;
      final result = expectLater(
        h.push.disableFamilyAccess('parent-a', 'family'),
        throwsStateError,
      );
      pending.completeError(StateError('native unavailable'));
      await result;
      final revision = h.native.revision;
      await h.push.disableFamilyAccess('parent-a', 'family');
      expect(h.native.revision, revision + 1);
      expect(h.native.enabled, false);
    },
  );
  test(
    'membership notification revocation is limited to the bound account and family',
    () async {
      final h = Harness();
      await h.enable();
      final revision = h.native.revision;
      await h.push.disableFamilyAccess('other-parent', 'family');
      await h.push.disableFamilyAccess('parent-a', 'other-family');
      expect(h.native.enabled, true);
      expect(h.native.revision, revision);
      await h.push.disableFamilyAccess('parent-a', 'family');
      expect(h.native.enabled, false);
      expect(h.native.revision, greaterThan(revision));
    },
  );
  test(
    'sign-out fences native before clearing authentication persistence',
    () async {
      final h = Harness(), backend = MockSupabase();
      addTearDown(backend.close);
      await backend.signIn();
      await h.enable();
      h.remote.offline = true;
      final auth = SupabaseAuthRepository(
        backend.client,
        beforeSignOut: () async {
          await h.push.disable();
          expect(h.native.enabled, false);
          expect(h.row['state'], 'revoking');
        },
      );
      await auth.signOut();
      expect(auth.currentSession, isNull);
    },
  );

  test(
    'local scheduler fences repeated clears even while prior work is waiting',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final held = Completer<void>(), entered = <String?>[];
      final scheduler = LocalNotificationScheduler(
        onScopeChanged: (scope) async {
          entered.add(scope);
          if (scope == 'old') await held.future;
          if (scope == null) throw StateError('native fence failure');
        },
      );
      await scheduler.setScope(
        null,
      ); // initial scope is already fenced at startup
      expect(entered, isEmpty);
      final old = scheduler.setScope('old');
      final clear = expectLater(scheduler.setScope(null), throwsStateError);
      await drain();
      expect(entered, ['old', null]);
      held.complete();
      await old;
      await clear;
      await expectLater(scheduler.setScope(null), throwsStateError);
      expect(entered, ['old', null, null]);
    },
  );

  testWidgets('signed-out lifecycle retries revocation only while foreground', (
    tester,
  ) async {
    final h = Harness();
    await h.enable();
    h.owner = null;
    h.remote.offline = true;
    await h.push.disable();
    await tester.pumpWidget(
      RemotePushLifecycle(controller: h.push, child: const SizedBox()),
    );
    await tester.pump();
    final before = h.remote.revocations.length;
    await tester.pump(const Duration(minutes: 1));
    await tester.pump();
    expect(h.remote.revocations.length, greaterThan(before));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final paused = h.remote.revocations.length;
    await tester.pump(const Duration(minutes: 2));
    expect(h.remote.revocations.length, paused);
    h.remote.offline = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(h.row['state'], 'disabled');
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'explicit opt-in persists prepare before network and binds native gate',
    () async {
      final h = Harness();
      await h.push.initialize();
      expect(await h.push.status('family'), RemotePushStatus.disabled);
      expect(h.native.tokenCalls, 0);
      h.remote.intercept = (name, params) {
        expect(h.row['state'], 'preparing');
        expect(h.row['secret'], params['device_secret']);
        return h.remote.reply(name, params);
      };
      await h.enable();
      expect(h.remote.calls, [
        'prepare_parent_push_device',
        'activate_parent_push_device',
      ]);
      expect(h.row['state'], 'enabled');
      expect(h.row.containsKey('push_token'), false);
      expect(h.row['native_revision'], h.native.revision);
      expect(h.native.gate!['scope_nonce'], h.row['nonce']);
      expect(h.native.gate!['settings_version'], 2);
      expect(await h.push.status('family'), RemotePushStatus.enabled);
      expect(await h.push.status('another'), RemotePushStatus.disabled);
      await h.push.setScope('parent:parent-a:family');
      expect(h.native.enabled, true);
    },
  );

  test(
    'build flag, PIN, account and preferences all gate token registration',
    () async {
      for (final mode in ['flag', 'pin', 'account', 'preferences']) {
        final h = Harness();
        if (mode == 'pin') h.pin = false;
        if (mode == 'account') h.owner = null;
        if (mode == 'flag') h.push = h.controller(configured: false);
        await expectLater(
          h.push.enable(
            'family',
            mode == 'preferences'
                ? const ParentNotificationSettings()
                : settings,
            canConfigure: () => h.pin,
          ),
          throwsStateError,
        );
        expect(h.native.tokenCalls, 0);
        expect(h.remote.calls, isEmpty);
      }
    },
  );

  test(
    'unsupported native configuration and denied OS permission stay disabled',
    () async {
      for (final mode in [
        'config',
        'available',
        'transport',
        'permission',
        'token',
      ]) {
        final h = Harness();
        if (mode == 'config') h.native.configured = false;
        if (mode == 'available') h.native.available = false;
        if (mode == 'transport') h.native.transport = 'unknown';
        if (mode == 'permission') h.native.permit = false;
        if (mode == 'token') h.native.deviceToken = null;
        await expectLater(h.enable(), throwsStateError);
        await drain();
        expect(h.native.enabled, false);
        if (mode == 'config') {
          expect(await h.push.status('family'), RemotePushStatus.unconfigured);
        }
        if (mode == 'available') {
          expect(await h.push.status('family'), RemotePushStatus.unavailable);
        }
      }
    },
  );

  test(
    'offline opt-out immediately fences native and durably retries without owner',
    () async {
      final h = Harness();
      await h.enable();
      final oldVersion = h.row['version'] as int;
      h.remote.offline = true;
      await h.push.disable();
      expect(h.native.enabled, false);
      expect(h.row['state'], 'revoking');
      expect(h.row['version'], oldVersion + 1);
      expect(h.row.keys.toSet(), {
        'schema',
        'device',
        'secret',
        'version',
        'state',
      });
      expect(await h.push.status('family'), RemotePushStatus.revoking);
      h.owner = null;
      h.push = h.controller();
      await h.push.initialize();
      await drain();
      h.remote.offline = false;
      await h.push.flushRevocation();
      expect(h.row['state'], 'disabled');
      expect(h.remote.revocations.last['requested_version'], oldVersion + 1);
    },
  );

  test(
    'late activation after opt-out cannot display or overwrite pending revoke',
    () async {
      final h = Harness();
      final entered = Completer<void>(), release = Completer<void>();
      h.remote.intercept = (name, params) async {
        final result = h.remote.reply(name, params);
        if (name.startsWith('activate')) {
          entered.complete();
          await release.future;
        }
        return result;
      };
      final operation = h.enable();
      final failure = expectLater(operation, throwsStateError);
      await entered.future;
      h.remote.offline = true;
      await h.push.disable();
      final version = h.row['version'];
      release.complete();
      await failure;
      expect(h.native.enables, 0);
      expect(h.row['version'], version);
      expect(h.row['state'], 'revoking');
    },
  );

  test('new opt-in overtakes old activation and old revoke response', () async {
    final h = Harness();
    final entered = Completer<void>(),
        release = Completer<void>(),
        revoke = Completer<void>();
    var first = true;
    h.remote.intercept = (name, params) async {
      final result = h.remote.reply(name, params);
      if (name.startsWith('activate') && first) {
        first = false;
        entered.complete();
        await release.future;
      }
      return result;
    };
    h.remote.interceptRevoke = (_) => revoke.future;
    final firstAttempt = expectLater(h.enable(), throwsStateError);
    await entered.future;
    await h.push.disable();
    await drain();
    await h.enable();
    final version = h.row['version'];
    release.complete();
    revoke.complete();
    await firstAttempt;
    await drain();
    expect(h.row['version'], version);
    expect(h.row['state'], 'enabled');
    expect(h.native.enabled, true);
  });

  test(
    'late native disable callback cannot take ownership from a newer opt-in',
    () async {
      final h = Harness();
      await h.enable();
      final held = h.native.disableAck = Completer<int>();
      final old = h.push.disable();
      final oldRevision = h.native.revision;
      await h.enable();
      held.complete(oldRevision);
      await old;
      h.push.resumed();
      await h.push.refresh('family', settings);
      expect(h.native.enabled, true);
      expect(h.row['native_revision'], h.native.revision);
    },
  );

  test(
    'cold foreground launch renews matching opt-in without a new PIN',
    () async {
      final h = Harness();
      await h.enable();
      final version = h.row['version'];
      h.push = h.controller();
      h.pin = false;
      await h.push.initialize();
      expect(h.native.enabled, false);
      await h.push.setScope('parent:parent-a:family');
      await h.push.refresh('family', settings);
      expect(h.native.enabled, true);
      expect(h.row['version'], version);
      expect(h.remote.calls.last, 'renew_parent_push_device');
      expect(h.row['native_revision'], h.native.revision);
      final calls = h.remote.calls.length;
      await h.push.refresh('family', settings);
      expect(h.remote.calls.length, calls);
    },
  );

  test(
    'interrupted prepare, owner change and native mismatch revoke on restart',
    () async {
      for (final mode in [
        'prepare',
        'owner',
        'disabled',
        'revision',
        'config',
      ]) {
        final h = Harness();
        await h.enable();
        if (mode == 'prepare') {
          h.secrets.values[h.push.storageKey] = jsonEncode({
            ...h.row,
            'state': 'preparing',
          });
        }
        if (mode == 'owner') h.owner = 'parent-b';
        if (mode == 'disabled') h.native.enabled = false;
        if (mode == 'revision') h.native.revision++;
        h.push = h.controller(configured: mode != 'config');
        await h.push.initialize();
        await drain();
        await h.push.refresh('family', settings);
        expect(h.native.enabled, false, reason: mode);
        expect(h.row['state'], 'disabled', reason: mode);
      }
    },
  );

  test(
    'failed opt-out secure write cannot be silently renewed or restored',
    () async {
      final h = Harness();
      await h.enable();
      h.secrets.failWrite = (_) => true;
      await h.push.disable();
      await drain();
      await h.push.refresh('family', settings);
      expect(h.native.enabled, false);
      expect(h.row['state'], 'enabled'); // stale record retained for recovery
      expect(await h.push.status('family'), RemotePushStatus.disabled);
      h.secrets.failWrite = null;
      h.push = h.controller();
      await h.push.initialize();
      await drain();
      expect(h.row['state'], 'disabled');
      expect(h.native.enabled, false);
    },
  );

  test(
    'failed activation persistence keeps gate closed and revokes grant',
    () async {
      final h = Harness();
      h.secrets.failWrite = (row) => row['state'] == 'enabled';
      await expectLater(h.enable(), throwsA(isA<LocalDataException>()));
      await drain();
      expect(h.native.enables, 0);
      expect(h.row['state'], 'disabled');
    },
  );

  test(
    'locked or corrupt optional storage does not block startup or replace identity',
    () async {
      final h = Harness();
      await h.enable();
      final original = h.secrets.values[h.push.storageKey];
      h.secrets.failRead = true;
      h.push = h.controller();
      await h.push.initialize();
      expect(h.native.enabled, false);
      expect(h.secrets.values[h.push.storageKey], original);
      h.secrets.failRead = false;
      await h.push.flushRevocation();
      expect(h.row['state'], 'disabled');
      h.secrets.values[h.push.storageKey] = '{broken';
      await h.push.initialize();
      await expectLater(h.enable(), throwsA(isA<LocalDataException>()));
      await drain();
      expect(h.secrets.values[h.push.storageKey], '{broken');
    },
  );

  test(
    'malformed acknowledgements and invalid grant times fail closed',
    () async {
      for (final change in [
        {'device_id': 'wrong'},
        {'family_id': 'wrong'},
        {'scope_nonce': 'wrong'},
        {'intent_version': 999},
        {'state': 'disabled'},
        {'transport': 'gateway'},
        {'expires_at': '2026-11-05T04:00:00Z'},
        {'expires_at': '2027-11-05T04:00:00Z'},
        {'server_time': 'invalid'},
      ]) {
        final h = Harness();
        h.remote.intercept = (name, params) => {
          ...h.remote.reply(name, params),
          if (name.startsWith('activate')) ...change,
        };
        await expectLater(h.enable(), throwsA(anything));
        await drain();
        expect(h.native.enables, 0, reason: '$change');
        expect(h.row['state'], 'disabled');
      }
    },
  );

  test(
    'account, privacy and PIN changes fence an activation already in flight',
    () async {
      for (final mode in ['owner', 'privacy', 'pin']) {
        final h = Harness();
        h.remote.intercept = (name, params) {
          final result = h.remote.reply(name, params);
          if (name.startsWith('activate')) {
            if (mode == 'owner') h.owner = 'other';
            if (mode == 'privacy') h.privacy++;
            if (mode == 'pin') h.pin = false;
          }
          return result;
        };
        await expectLater(h.enable(), throwsStateError);
        await drain();
        expect(h.native.enabled, false);
        expect(h.row['state'], 'disabled');
      }
    },
  );

  test(
    'resume renews rotated token; offline errors back off; stale grant disables',
    () async {
      final h = Harness();
      await h.enable();
      h.native.deviceToken = 'rotated-token';
      h.remote.intercept = (name, params) {
        expect(params['push_token'], 'rotated-token');
        return h.remote.reply(name, params);
      };
      h.push.resumed();
      await h.push.refresh('family', settings);
      expect(h.native.enables, 2);
      h.remote.offline = true;
      h.push.resumed();
      await h.push.refresh('family', settings);
      final calls = h.remote.calls.length;
      await h.push.refresh('family', settings);
      expect(h.remote.calls.length, calls);
      h.remote.offline = false;
      h.remote.intercept = (_, _) => throw const PostgrestException(
        message: 'STALE_PUSH_DEVICE_INTENT',
        code: 'P0001',
      );
      h.push.resumed();
      await h.push.refresh('family', settings);
      await drain();
      expect(h.native.enabled, false);
      expect(h.row['state'], 'disabled');
    },
  );

  test(
    'scope and preferences changes disable an existing registration',
    () async {
      for (final mode in ['scope', 'family', 'owner', 'preferences']) {
        final h = Harness();
        await h.enable();
        if (mode == 'scope') {
          await h.push.setScope('child');
        } else {
          h.push.resumed();
          if (mode == 'owner') h.owner = null;
          await h.push.refresh(
            mode == 'family' ? 'other' : 'family',
            mode == 'preferences'
                ? const ParentNotificationSettings()
                : settings,
          );
        }
        await drain();
        expect(h.native.enabled, false);
      }
    },
  );

  test('late renewal after logout never restores native delivery', () async {
    final h = Harness();
    await h.enable();
    final entered = Completer<void>(), release = Completer<void>();
    h.remote.intercept = (name, params) async {
      final result = h.remote.reply(name, params);
      entered.complete();
      await release.future;
      return result;
    };
    h.push.resumed();
    final refresh = h.push.refresh('family', settings);
    await entered.future;
    await h.push.disable();
    h.owner = null;
    release.complete();
    await refresh;
    await drain();
    expect(h.native.enabled, false);
    expect(h.row['state'], 'disabled');
  });

  test(
    'native revision rejects activation even when callback is delayed',
    () async {
      final h = Harness();
      h.remote.intercept = (name, params) {
        final result = h.remote.reply(name, params);
        if (name.startsWith('activate')) h.native.revision++;
        return result;
      };
      await expectLater(h.enable(), throwsStateError);
      expect(h.native.enabled, false);
    },
  );

  test(
    'RPC adapter uses authenticated client for registration and anonymous revoke',
    () async {
      final signed = MockSupabase(), anonymous = MockSupabase();
      addTearDown(signed.close);
      addTearDown(anonymous.close);
      await signed.signIn();
      signed.handle = (request) => MockSupabase.json(request, {'ok': true});
      anonymous.handle = (request) => MockSupabase.json(request, {
        'revoked': true,
        'device_id': MockSupabase.body(request)['target_device_id'],
        'intent_version': MockSupabase.body(request)['requested_version'],
      });
      final remote = SupabaseParentPushRemote(signed.client, anonymous.client);
      expect(await remote.call('prepare_parent_push_device', {'value': 1}), {
        'ok': true,
      });
      expect(
        signed.calls.single.headers['Authorization'],
        startsWith('Bearer header.'),
      );
      await signed.client.auth.signOut();
      const capability = {
        'target_device_id': 'device',
        'device_secret': 'secret',
        'requested_version': 3,
      };
      await remote.revoke(capability);
      expect(anonymous.calls.single.headers['Authorization'], 'Bearer public');
      expect(MockSupabase.body(anonymous.calls.single), capability);
      anonymous.handle = (request) => MockSupabase.json(request, {
        'revoked': true,
        'device_id': 'wrong',
        'intent_version': 3,
      });
      await expectLater(remote.revoke(capability), throwsFormatException);
    },
  );

  test(
    'method channel sends typed revision, startup and gate arguments',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(MethodChannelParentPush.channel, (
        call,
      ) async {
        calls.add(call);
        return switch (call.method) {
          'availability' => {'transport': 'hms', 'configured': true},
          'startup' || 'disable' => 7,
          'token' => 'token',
          'enable' => true,
          _ => null,
        };
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          MethodChannelParentPush.channel,
          null,
        ),
      );
      const native = MethodChannelParentPush();
      expect((await native.availability())['transport'], 'hms');
      expect(await native.disable(startup: true), 7);
      expect(await native.disable(), 7);
      expect(await native.token(7), 'token');
      expect(await native.enable({'revision': 7}), true);
      expect(calls.map((c) => c.method), [
        'availability',
        'startup',
        'disable',
        'token',
        'enable',
      ]);
      expect(calls[3].arguments, {'revision': 7});
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(await native.availability(), isEmpty);
      expect(await native.disable(), 0);
      expect(calls.length, 5);
    },
  );
}
