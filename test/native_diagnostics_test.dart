import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:learning_planet/core/diagnostics/native_diagnostics.dart';
import 'package:learning_planet/core/diagnostics/runtime_diagnostics.dart';
import 'package:learning_planet/core/offline/offline_store.dart';

class _Bridge implements NativeDiagnosticBridge {
  final scopes = <String?>[];
  final acknowledgements = <List<String>>[];
  List<Map<String, dynamic>> events = [];
  Completer<void>? pending;
  bool failAck = false;
  @override
  Future<List<Map<String, dynamic>>> read(String? scope) async {
    scopes.add(scope);
    await pending?.future;
    return events;
  }

  @override
  Future<void> acknowledge(String scope, List<String> ids) async {
    if (failAck) throw StateError('PRIVATE native error');
    acknowledgements.add(ids);
    events = events.where((e) => !ids.contains(e['event_id'])).toList();
  }
}

class _Store extends OfflineStore {
  _Store() : super(NativeDatabase.memory());
  bool fail = false;
  @override
  Future<void> write(String owner, String key, Map<String, dynamic> data) {
    if (fail && key == RuntimeDiagnostics.cacheKey) {
      throw StateError('PRIVATE storage');
    }
    return super.write(owner, key, data);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 11, 5);
  late _Store store;
  late RuntimeDiagnostics diagnostics;
  late NativeDiagnostics native;
  late _Bridge bridge;
  late String? owner;
  late List<List<Map<String, dynamic>>> sent;
  Map<String, dynamic> event([String operation = 'androidNativeCrash']) => {
    'event_id': const Uuid().v4(),
    'day': '2026-11-05',
    'operation': operation,
  };
  Future<List<dynamic>> queued([String account = 'account-a']) async =>
      (await store.read(account, RuntimeDiagnostics.cacheKey))?['events']
          as List? ??
      [];
  setUp(() {
    owner = 'account-a';
    store = _Store();
    bridge = _Bridge();
    sent = [];
    diagnostics = RuntimeDiagnostics(clock: () => now, log: (_) {});
    native = NativeDiagnostics(
      store: store,
      owner: () => owner,
      diagnostics: diagnostics,
      bridge: bridge,
    );
    diagnostics.attach(
      store: store,
      owner: () => owner,
      automatic: false,
      collectNative: native.synchronize,
      send: (events) async {
        sent.add(events);
        return {'event_ids': events.map((e) => e['event_id']).toList()};
      },
    );
  });
  tearDown(() async {
    await native.dispose();
    await diagnostics.dispose();
    await store.close();
  });

  test(
    'all native categories enter the encrypted queue before acknowledgement',
    () async {
      bridge.events = [
        'androidJavaCrash',
        'androidNativeCrash',
        'androidAnr',
        'iosCrash',
        'iosHang',
      ].map(event).toList();
      final expected = bridge.events.map((e) => e['event_id']).toList();
      await native.synchronize();
      expect(bridge.acknowledgements.single, expected);
      expect(bridge.scopes.single, isNot(contains('account')));
      expect(Uuid.isValidUUID(fromString: bridge.scopes.single!), true);
      final rows = await queued();
      expect(rows.length, 5);
      for (final row in rows) {
        expect(row.length, 7);
        expect(row['kind'], 'native');
        expect(row['error'], 'none');
        expect(row['bucket'], 0);
      }
      await diagnostics.flush();
      expect(sent.single.map((e) => e['event_id']), expected);
      expect(await queued(), isEmpty);
    },
  );

  test(
    'native lost acknowledgement preserves event IDs before and after server upload',
    () async {
      final original = event();
      bridge.events = [original];
      bridge.failAck = true;
      await native.synchronize();
      await native.synchronize();
      expect((await queued()).length, 1);
      await diagnostics.flush();
      expect(sent.single.single['event_id'], original['event_id']);
      expect(await queued(), isEmpty);
      bridge.failAck = false;
      await diagnostics.flush();
      expect(sent.length, 2);
      expect(sent.last.single, sent.first.single);
      expect(bridge.acknowledgements.single, [original['event_id']]);
    },
  );

  test(
    'native storage failures never acknowledge or block subsequent business diagnostics',
    () async {
      bridge.events = [event()];
      store.fail = true;
      await native.synchronize();
      expect(bridge.acknowledgements, isEmpty);
      expect(await queued(), isEmpty);
      store.fail = false;
      diagnostics.record(DiagnosticOperation.tasks);
      await native.synchronize();
      expect(bridge.acknowledgements.length, 1);
      expect((await queued()).length, 2);
    },
  );

  test(
    'account change during native collection discards old results and binds a new opaque scope',
    () async {
      bridge.events = [event()];
      bridge.pending = Completer<void>();
      final old = native.synchronize();
      while (bridge.scopes.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      owner = 'account-b';
      diagnostics.scopeChanged();
      final next = native.synchronize();
      bridge.pending!.complete();
      await old;
      bridge.events = [];
      await next;
      expect(await queued(), isEmpty);
      expect(await queued('account-b'), isEmpty);
      expect(bridge.acknowledgements, isEmpty);
      expect(bridge.scopes.last, isNot(bridge.scopes.first));
    },
  );

  test(
    'logout clears the native binding and never imports an unowned record',
    () async {
      await native.synchronize();
      owner = null;
      diagnostics.scopeChanged();
      bridge.events = [event()];
      await native.synchronize();
      expect(bridge.scopes.last, isNull);
      expect(await queued(), isEmpty);
      expect(bridge.acknowledgements, isEmpty);
    },
  );

  test(
    'privacy barrier drops an in-flight import and a removed scope is regenerated',
    () async {
      bridge.events = [event()];
      bridge.pending = Completer<void>();
      final work = native.synchronize();
      while (bridge.scopes.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      store.privacyGeneration++;
      bridge.pending!.complete();
      await work;
      expect(await queued(), isEmpty);
      expect(bridge.acknowledgements, isEmpty);
      final previous = bridge.scopes.single;
      await store.write(owner!, NativeDiagnostics.scopeKey, {});
      bridge.events = [];
      await native.synchronize();
      expect(bridge.scopes.last, isNot(previous));
    },
  );

  test(
    'accepted account deletion clears native binding and cannot recreate its scope',
    () async {
      await native.synchronize();
      await store.removeAccountData(owner!, const Uuid().v4());
      bridge.events = [event()];
      await native.synchronize();
      expect(bridge.scopes.last, isNull);
      expect(await store.read(owner!, NativeDiagnostics.scopeKey), isNull);
      expect(bridge.acknowledgements, isEmpty);
      expect(await queued(), isEmpty);
    },
  );

  test(
    'scope survives controller restart without exposing the account to native code',
    () async {
      await native.synchronize();
      final original = bridge.scopes.single;
      await native.dispose();
      native = NativeDiagnostics(
        store: store,
        owner: () => owner,
        diagnostics: diagnostics,
        bridge: bridge,
      );
      await native.synchronize();
      expect(bridge.scopes.last, original);
    },
  );

  test(
    'strict import rejects private fields, unsupported types, dates, conflicts and oversized batches',
    () async {
      final valid = event();
      final token = diagnostics.capture();
      for (final bad in [
        {...valid, 'stack': 'PRIVATE'},
        {...valid, 'scope': owner},
        {...valid, 'day': '2026-02-30'},
        {...valid, 'day': '2026-11-06'},
        {...valid, 'day': '2026-10-28'},
        {...valid, 'operation': 'framework'},
        {...valid, 'operation': null},
        {...valid, 'event_id': 'PRIVATE'},
        {...valid, 'day': false},
      ]) {
        expect(await diagnostics.ingestNative([bad], token), isEmpty);
      }
      expect(await diagnostics.ingestNative([valid, valid], token), isEmpty);
      expect(
        await diagnostics.ingestNative(
          List.generate(51, (_) => event()),
          token,
        ),
        isEmpty,
      );
      expect(await queued(), isEmpty);
      expect(await diagnostics.ingestNative([valid], token), [
        valid['event_id'],
      ]);
      expect(
        await diagnostics.ingestNative([
          {...valid, 'operation': 'iosHang'},
        ], token),
        isEmpty,
      );
      expect(jsonEncode(await queued()), isNot(contains('PRIVATE')));
    },
  );

  test(
    'full queue preserves acknowledged native entries and normal retention limits',
    () async {
      final old = event();
      await diagnostics.ingestNative([old], diagnostics.capture());
      for (var i = 0; i < 249; i++) {
        diagnostics.record(DiagnosticOperation.tasks);
      }
      await diagnostics.settled;
      bridge.events = [old, ...List.generate(49, (_) => event())];
      await native.synchronize();
      final rows = await queued();
      expect(rows.length, 250);
      final ids = rows.map((e) => (e as Map)['event_id']).toSet();
      expect(bridge.acknowledgements.single.every(ids.contains), true);
    },
  );

  test(
    'disposed or superseded collection cannot commit native events',
    () async {
      bridge.events = [event()];
      bridge.pending = Completer<void>();
      final work = native.synchronize();
      while (bridge.scopes.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      final closing = native.dispose();
      bridge.pending!.complete();
      await work;
      await closing;
      expect(await queued(), isEmpty);
      expect(bridge.acknowledgements, isEmpty);
    },
  );

  test(
    'method channel uses only scoped read and exact acknowledgement IDs',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      final row = event();
      messenger.setMockMethodCallHandler(
        MethodChannelNativeDiagnostics.channel,
        (call) async {
          calls.add(call);
          return call.method == 'read' ? [row] : null;
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          MethodChannelNativeDiagnostics.channel,
          null,
        ),
      );
      const real = MethodChannelNativeDiagnostics();
      final scope = const Uuid().v4();
      expect(await real.read(scope), [row]);
      await real.acknowledge(scope, [row['event_id'] as String]);
      expect(calls.map((e) => e.method), ['read', 'ack']);
      expect(calls.first.arguments, {'scope': scope});
      expect(calls.last.arguments, {
        'scope': scope,
        'ids': [row['event_id']],
      });
      messenger.setMockMethodCallHandler(
        MethodChannelNativeDiagnostics.channel,
        (_) async => {'stack': 'PRIVATE'},
      );
      await expectLater(real.read(scope), throwsFormatException);
    },
  );
}
