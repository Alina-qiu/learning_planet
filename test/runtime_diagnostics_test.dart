import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/app/startup_gate.dart';
import 'package:learning_planet/core/diagnostics/diagnostic_http_client.dart';
import 'package:learning_planet/core/diagnostics/runtime_diagnostics.dart';
import 'package:learning_planet/core/diagnostics/runtime_error_handlers.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/offline/offline_media_store.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_sync_remote.dart';
import 'package:learning_planet/features/wrong_questions/data/offline_question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/question_media_repository.dart';

class _Remote extends Mock implements TaskSyncRemote {}

class _Media extends Mock implements QuestionMediaRepository {}

class _ThrowingText implements Exception {
  @override
  String toString() => throw StateError('Must not stringify errors');
}

class _Transport extends http.BaseClient {
  _Transport(this.handle);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handle;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handle(request);
  @override
  void close() {
    closed = true;
  }
}

class _LifecycleDiagnostics extends RuntimeDiagnostics {
  final states = <bool>[];
  @override
  void setForeground(bool value) => states.add(value);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(Uint8List(0));
  });
  late OfflineStore store;
  late RuntimeDiagnostics diagnostics;
  late DateTime now;
  late String? owner;
  late List<String> logs;
  late List<List<Map<String, dynamic>>> sent;
  late DiagnosticSender send;
  Future<List<Map<String, dynamic>>> pending([String who = 'owner-a']) async {
    await diagnostics.settled;
    return ((await store.read(who, RuntimeDiagnostics.cacheKey))?['events']
                as List? ??
            [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  void attach() => diagnostics.attach(
    store: store,
    owner: () => owner,
    send: (events) => send(events),
    automatic: false,
  );
  setUp(() {
    now = DateTime.utc(2026, 11, 4, 9);
    owner = 'owner-a';
    logs = [];
    sent = [];
    store = OfflineStore(NativeDatabase.memory());
    diagnostics = RuntimeDiagnostics(clock: () => now, log: logs.add);
    send = (events) async {
      sent.add(events);
      return {'event_ids': events.map((e) => e['event_id']).toList()};
    };
    attach();
  });
  tearDown(() async {
    await diagnostics.dispose();
    await store.close();
  });

  test(
    'diagnostic domains, error codes and duration boundaries cannot stringify private errors',
    () async {
      final errors = [
        StateError('PRIVATE'),
        const FormatException('PRIVATE'),
        TypeError(),
        RangeError('PRIVATE'),
        UnsupportedError('PRIVATE'),
        _ThrowingText(),
        null,
      ];
      for (final error in errors) {
        diagnostics.record(DiagnosticOperation.framework, error: error);
      }
      expect((await pending()).map((e) => e['error']), [
        'state',
        'format',
        'type',
        'range',
        'unsupported',
        'unknown',
        'none',
      ]);
      expect(jsonEncode(await pending()), isNot(contains('PRIVATE')));
      expect(logs.join(), isNot(contains('PRIVATE')));
      expect(
        [
          0,
          99,
          100,
          499,
          500,
          1499,
          1500,
          2999,
          3000,
          9999,
          10000,
          29999,
          30000,
        ].map((ms) => diagnosticLatencyBucket(Duration(milliseconds: ms))),
        [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6],
      );
      expect(
        diagnosticFailure(TimeoutException('PRIVATE')),
        DiagnosticOutcome.timeout,
      );
      expect(
        diagnosticFailure(const SocketException('PRIVATE')),
        DiagnosticOutcome.network,
      );
      expect(
        diagnosticFailure(StateError('PRIVATE')),
        DiagnosticOutcome.unexpected,
      );
      final brokenLogger = RuntimeDiagnostics(
        log: (_) => throw StateError('logger failed'),
      );
      brokenLogger.record(DiagnosticOperation.startup, error: _ThrowingText());
      await brokenLogger.dispose();
    },
  );

  test(
    'real SDK transport preserves private responses while diagnostics upload excludes its own request',
    () async {
      final requests = <http.Request>[];
      final transport = DiagnosticHttpClient(
        MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/record_runtime_diagnostics')) {
            final body = jsonDecode(request.body) as Map;
            final events = (body['events'] as List).cast<Map>();
            expect(jsonEncode(events), isNot(contains('PRIVATE')));
            return http.Response(
              jsonEncode({
                'event_ids': events.map((e) => e['event_id']).toList(),
              }),
              200,
              request: request,
              headers: {'content-type': 'application/json'},
            );
          }
          expect(request.body, contains('PRIVATE QUESTION'));
          return http.Response(
            '{"answer":"PRIVATE ANSWER"}',
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
        Uri.parse('https://backend.example'),
        diagnostics,
      );
      final client = SupabaseClient(
        'https://backend.example',
        'public-key',
        httpClient: transport,
      );
      try {
        send = (events) async => Map<String, dynamic>.from(
          await client.rpc(
                'record_runtime_diagnostics',
                params: {'events': events},
              )
              as Map,
        );
        expect(
          await client.rpc(
            'private_operation',
            params: {'text': 'PRIVATE QUESTION', 'child': 'PRIVATE CHILD'},
          ),
          {'answer': 'PRIVATE ANSWER'},
        );
        final event = (await pending()).single;
        expect(event['operation'], 'database');
        expect(event['outcome'], 'ok');
        expect(event.keys.toSet(), {
          'event_id',
          'day',
          'kind',
          'operation',
          'outcome',
          'error',
          'bucket',
        });
        await diagnostics.flush();
        expect(await pending(), isEmpty);
        expect(requests.length, 2);
      } finally {
        await client.dispose();
        transport.close();
      }
    },
  );

  test(
    'HTTP response statuses, body errors, cancellation and send failures record exactly once',
    () async {
      final uri = Uri.parse('https://backend.example');
      for (final (path, status, outcome) in [
        ('/auth/v1/token', 401, 'authorization'),
        ('/storage/v1/object/PRIVATE', 500, 'server_error'),
        ('/functions/v1/ai-analysis', 400, 'client_error'),
      ]) {
        final client = DiagnosticHttpClient(
          MockClient((_) async => http.Response('PRIVATE BODY', status)),
          uri,
          diagnostics,
        );
        expect((await client.get(uri.resolve(path))).body, 'PRIVATE BODY');
        client.close();
        expect((await pending()).last['outcome'], outcome);
      }
      final stream = StreamController<List<int>>();
      final inner = _Transport(
        (_) async => http.StreamedResponse(
          stream.stream,
          200,
          headers: {'private': 'PRIVATE'},
          reasonPhrase: 'OK',
        ),
      );
      final client = DiagnosticHttpClient(inner, uri, diagnostics);
      final response = await client.send(
        http.Request('GET', uri.resolve('/storage/v1/object/PRIVATE')),
      );
      expect(response.headers['private'], 'PRIVATE');
      expect((await pending()).length, 3);
      final subscription = response.stream.listen((_) {});
      stream.add([1]);
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      await stream.close();
      expect((await pending()).last['outcome'], 'cancelled');
      client.close();
      expect(inner.closed, isTrue);
      final bodyFailure = DiagnosticHttpClient(
        _Transport(
          (_) async => http.StreamedResponse(
            Stream<List<int>>.error(const SocketException('PRIVATE')),
            200,
          ),
        ),
        uri,
        diagnostics,
      );
      await expectLater(
        bodyFailure.get(uri.resolve('/rest/v1/private?name=PRIVATE')),
        throwsA(isA<SocketException>()),
      );
      bodyFailure.close();
      expect((await pending()).last['outcome'], 'network');
      final failure = TimeoutException('PRIVATE SESSION');
      final sendFailure = DiagnosticHttpClient(
        _Transport((_) async => throw failure),
        uri,
        diagnostics,
      );
      await expectLater(
        sendFailure.get(uri.resolve('/rest/v1/private')),
        throwsA(same(failure)),
      );
      sendFailure.close();
      expect((await pending()).last['outcome'], 'timeout');
      expect((await pending()).length, 6);
      final other = DiagnosticHttpClient(
        MockClient((_) async => http.Response('', 200)),
        uri,
        diagnostics,
      );
      await other.get(Uri.parse('https://other.example/rest/v1/private'));
      await other.get(uri.resolve('/unknown'));
      other.close();
      expect((await pending()).length, 6);
      expect(jsonEncode(await pending()), isNot(contains('PRIVATE')));
    },
  );

  test(
    'lost acknowledgements retain immutable event IDs, back off and preserve records added during upload',
    () async {
      diagnostics.record(DiagnosticOperation.tasks);
      final original = (await pending()).single;
      send = (events) async {
        sent.add(events);
        throw TimeoutException('unknown acknowledgement');
      };
      await diagnostics.flush();
      await diagnostics.flush();
      expect(sent.length, 1);
      expect((await pending()).single, original);
      expect(() => sent.single.add(original), throwsUnsupportedError);
      expect(
        () => sent.single.single['outcome'] = 'PRIVATE',
        throwsUnsupportedError,
      );
      now = now.add(const Duration(seconds: 31));
      final entered = Completer<void>(), release = Completer<void>();
      send = (events) async {
        sent.add(events);
        entered.complete();
        await release.future;
        return {'event_ids': events.map((e) => e['event_id']).toList()};
      };
      final upload = diagnostics.flush();
      await entered.future;
      expect(identical(diagnostics.flush(), upload), isTrue);
      diagnostics.record(
        DiagnosticOperation.reviews,
        outcome: DiagnosticOutcome.conflict,
      );
      await diagnostics.settled;
      release.complete();
      await upload;
      expect(sent.last.single, original);
      expect((await pending()).single['operation'], 'reviews');
    },
  );

  test(
    'wrong or duplicate acknowledgements never erase diagnostic records',
    () async {
      diagnostics.record(DiagnosticOperation.database);
      diagnostics.record(DiagnosticOperation.edge);
      final original = await pending();
      for (final reply in [
        {
          'event_ids': ['other', 'other'],
        },
        {
          'event_ids': [original.first['event_id'], original.first['event_id']],
        },
        <String, dynamic>{},
      ]) {
        send = (_) async => reply;
        await diagnostics.flush();
        expect(await pending(), original);
        now = now.add(const Duration(minutes: 6));
      }
      send = (events) async => {
        'event_ids': events.map((e) => e['event_id']).toList(),
      };
      await diagnostics.flush();
      expect(await pending(), isEmpty);
    },
  );

  test(
    'account switching and deletion fence late HTTP outcomes and upload receipts',
    () async {
      diagnostics.record(DiagnosticOperation.database);
      await diagnostics.settled;
      final oldScope = diagnostics.capture(),
          entered = Completer<void>(),
          release = Completer<void>();
      send = (events) async {
        entered.complete();
        await release.future;
        return {'event_ids': events.map((e) => e['event_id']).toList()};
      };
      final upload = diagnostics.flush();
      await entered.future;
      owner = 'owner-b';
      diagnostics.scopeChanged();
      diagnostics.record(DiagnosticOperation.storage, scope: oldScope);
      diagnostics.record(DiagnosticOperation.auth);
      await diagnostics.settled;
      release.complete();
      await upload;
      expect((await pending()).length, 1);
      expect((await pending('owner-b')).single['operation'], 'auth');
      owner = 'owner-a';
      diagnostics.scopeChanged();
      await store.removeAccountData('owner-a', 'deletion-job');
      diagnostics.record(DiagnosticOperation.database);
      await diagnostics.settled;
      await diagnostics.flush();
      expect(await pending(), isEmpty);
      expect(await store.accountDeletionJob('owner-a'), 'deletion-job');
      owner = null;
      diagnostics.scopeChanged();
      await diagnostics.flush();
    },
  );

  test(
    'restored diagnostics prune malformed, future and expired cache data before any upload',
    () async {
      diagnostics.record(DiagnosticOperation.database);
      final good = (await pending()).single;
      final data = {
        'events': [
          good,
          {
            ...good,
            'event_id': '00000000-0000-4000-8000-000000000001',
            'day': '2026-10-28',
          },
          {
            ...good,
            'event_id': '00000000-0000-4000-8000-000000000002',
            'day': '2026-10-27',
          },
          {...good, 'day': '2999-01-01'},
          {...good, 'day': '2026-02-30'},
          {...good, 'body': 'PRIVATE'},
          {...good, 'error': 'PRIVATE'},
          {...good, 'bucket': 7},
          {...good, 'outcome': null},
          {...good, 'kind': 'ai'},
          {...good, 'operation': 'PRIVATE'},
          {...good, 'event_id': 'PRIVATE'},
          {...good, 'kind': 'runtime', 'operation': 'startup', 'bucket': 1},
          true,
          good,
        ],
      };
      await store.write('owner-a', RuntimeDiagnostics.cacheKey, data);
      await diagnostics.dispose();
      diagnostics = RuntimeDiagnostics(clock: () => now, log: logs.add);
      attach();
      await diagnostics.flush();
      expect(sent.single.length, 2);
      expect(sent.single.last['day'], '2026-10-28');
      expect(await pending(), isEmpty);
      expect(jsonEncode(sent), isNot(contains('PRIVATE')));
      await store.write('owner-a', RuntimeDiagnostics.cacheKey, {
        'events': true,
      });
      await diagnostics.flush();
      expect(await pending(), isEmpty);
    },
  );

  test(
    'disk-backed diagnostic event IDs survive database close and a fresh recorder',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'learning-planet-diagnostics-',
      );
      final file = File(
        '${directory.path}${Platform.pathSeparator}diagnostics.sqlite',
      );
      var disk = OfflineStore(NativeDatabase(file));
      var recorder = RuntimeDiagnostics(clock: () => now, log: logs.add);
      void connect() => recorder.attach(
        store: disk,
        owner: () => 'disk-owner',
        automatic: false,
        send: (events) async {
          sent.add(events);
          return {'event_ids': events.map((e) => e['event_id']).toList()};
        },
      );
      try {
        connect();
        recorder.record(
          DiagnosticOperation.tasks,
          outcome: DiagnosticOutcome.network,
        );
        await recorder.settled;
        final saved = (await disk.read(
          'disk-owner',
          RuntimeDiagnostics.cacheKey,
        ))!['events'];
        await recorder.dispose();
        await disk.close();
        disk = OfflineStore(NativeDatabase(file));
        recorder = RuntimeDiagnostics(clock: () => now, log: logs.add);
        connect();
        await recorder.flush();
        expect(sent.single, saved);
        expect(
          (await disk.read(
            'disk-owner',
            RuntimeDiagnostics.cacheKey,
          ))!['events'],
          isEmpty,
        );
      } finally {
        await recorder.dispose();
        await disk.close();
        final root = Directory.systemTemp.absolute.path;
        if (!directory.absolute.path.startsWith(
          '$root${Platform.pathSeparator}learning-planet-diagnostics-',
        )) {
          throw StateError('Unexpected test directory');
        }
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'metered streams preserve pause and resume and discard responses from a previous account',
    () async {
      final body = StreamController<List<int>>(),
          entered = Completer<void>(),
          release = Completer<void>();
      var paused = 0, resumed = 0;
      body.onPause = () => paused++;
      body.onResume = () => resumed++;
      final inner = _Transport((_) async {
        entered.complete();
        await release.future;
        return http.StreamedResponse(body.stream, 200);
      });
      final client = DiagnosticHttpClient(
        inner,
        Uri.parse('https://backend.example'),
        diagnostics,
      );
      final loading = client.send(
        http.Request(
          'GET',
          Uri.parse('https://backend.example/storage/v1/object/private'),
        ),
      );
      await entered.future;
      owner = 'owner-b';
      diagnostics.scopeChanged();
      release.complete();
      final response = await loading,
          bytes = <int>[],
          finished = Completer<void>();
      final subscription = response.stream.listen(
        bytes.addAll,
        onDone: finished.complete,
      );
      subscription.pause();
      body.add([1, 2]);
      await Future<void>.delayed(Duration.zero);
      expect(bytes, isEmpty);
      expect(paused, 1);
      subscription.resume();
      await Future<void>.delayed(Duration.zero);
      expect(bytes, [1, 2]);
      expect(resumed, 1);
      await body.close();
      await finished.future;
      await diagnostics.settled;
      expect(await pending(), isEmpty);
      expect(await pending('owner-b'), isEmpty);
      client.close();
    },
  );

  test(
    'bounded queues flush fifty events at a time and do not upload while backgrounded',
    () async {
      for (var i = 0; i < 260; i++) {
        diagnostics.record(DiagnosticOperation.database);
      }
      expect((await pending()).length, RuntimeDiagnostics.capacity);
      diagnostics.setForeground(false);
      await diagnostics.flush();
      expect(sent, isEmpty);
      diagnostics.setForeground(true);
      await diagnostics.flush();
      expect(sent.single.length, 50);
      expect((await pending()).length, 200);
      now = now.add(const Duration(days: 8));
      await diagnostics.flush();
      expect(await pending(), isEmpty);
      expect(sent.length, 1);
    },
  );

  test(
    'task, review and image sync paths report safe outcomes through the real local queues',
    () async {
      final remote = _Remote();
      when(() => remote.snapshot(any())).thenAnswer((_) async => {'tasks': []});
      when(
        () => remote.apply(any()),
      ).thenThrow(const SocketException('PRIVATE NETWORK'));
      await store.customStatement(
        'INSERT INTO task_outbox(owner,command_id,child_id,task_id,payload) VALUES(?,?,?,?,?)',
        [
          'owner-a',
          'command',
          'PRIVATE CHILD',
          'task',
          jsonEncode({'kind': 'review_answer'}),
        ],
      );
      final tasks = OfflineTaskRepository(
        store: store,
        remote: remote,
        live: const UnconfiguredTaskRepository(),
        accountId: () => owner,
        autoSync: false,
        diagnostics: diagnostics,
      );
      try {
        await tasks.synchronize('PRIVATE CHILD');
      } finally {
        await tasks.dispose();
      }
      expect((await pending()).map((e) => e['operation']), [
        'reviews',
        'tasks',
      ]);
      expect((await pending()).every((e) => e['outcome'] == 'network'), isTrue);
      final media = _Media();
      when(
        () => media.save(any(), any(), any(), any(), any(), any()),
      ).thenThrow(const SocketException('PRIVATE IMAGE'));
      final images = OfflineQuestionMediaRepository(
        store: store,
        live: media,
        accountId: () => owner,
        parentFamily: () => 'family',
        autoSync: false,
        diagnostics: diagnostics,
      );
      final bytes = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0]);
      await store.writeImageDraft(
        'owner-a',
        'PRIVATE CHILD',
        'family',
        'draft',
        {
          'config': {'ocr_confirmed': true},
          'consent': true,
          'recognition': null,
        },
        bytes,
        bytes,
        queue: true,
      );
      try {
        await images.synchronize();
      } finally {
        await images.dispose();
      }
      expect((await pending()).last['operation'], 'images');
      expect((await pending()).last['outcome'], 'network');
      expect(jsonEncode(await pending()), isNot(contains('PRIVATE')));
    },
  );

  test(
    'uncaught Flutter and platform errors emit redacted diagnostics instead of raw messages',
    () async {
      final previousFlutter = FlutterError.onError,
          previousPlatform = PlatformDispatcher.instance.onError;
      try {
        installRuntimeErrorHandlers(diagnostics);
        FlutterError.onError!(
          FlutterErrorDetails(
            exception: StateError('PRIVATE CHILD'),
            context: ErrorDescription('PRIVATE WIDGET'),
          ),
        );
        expect(
          PlatformDispatcher.instance.onError!(
            _ThrowingText(),
            StackTrace.fromString('PRIVATE PATH'),
          ),
          isTrue,
        );
        expect((await pending()).map((e) => e['operation']), [
          'framework',
          'async',
        ]);
        expect(logs.join(), isNot(contains('PRIVATE')));
      } finally {
        FlutterError.onError = previousFlutter;
        PlatformDispatcher.instance.onError = previousPlatform;
      }
    },
  );

  testWidgets(
    'diagnostic lifecycle pauses uploads and failing startup observers cannot block recovery',
    (tester) async {
      final spy = _LifecycleDiagnostics();
      var calls = 0;
      await tester.pumpWidget(
        RuntimeDiagnosticsLifecycle(
          diagnostics: spy,
          child: StartupGate(
            load: () async {
              if (calls++ == 0) throw StateError('PRIVATE');
              return const MaterialApp(home: Text('Recovered'));
            },
            onFailure: (_) => throw StateError('reporter failed'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(spy.states.last, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(spy.states.last, isTrue);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('Recovered'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(spy.states.last, isFalse);
      await spy.dispose();
    },
  );
}
