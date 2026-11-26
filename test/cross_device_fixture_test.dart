import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../integration_test/cross_device_sync_test.dart'
    show
        fixtureFailureMark,
        readFixtureOtp,
        reportAndroidProgress,
        showFixtureTarget;

void main() {
  final progress = Uri.http('127.0.0.1:54324', '/progress', {
    'device': 'android',
  });

  test(
    'mailbox polling retries a lost GET and a timeout without repeating any auth action',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/otp');
        expect(request.url.queryParameters.keys, ['device']);
        switch (++calls) {
          case 1:
            throw http.ClientException('connection lost');
          case 2:
            throw TimeoutException('network read');
          case 3:
            return http.Response('', 202);
          default:
            return http.Response(jsonEncode({'code': '0' * 8}), 200);
        }
      });
      addTearDown(client.close);
      final result = await readFixtureOtp(client, 'ios', (_) async {});
      expect(result.length, 8);
      expect(calls, 4);
    },
  );

  test(
    'mailbox rejection never retries or exposes the response body',
    () async {
      for (final status in [401, 403, 429, 500]) {
        var calls = 0;
        final client = MockClient((_) async {
          calls++;
          return http.Response('private_marker', status);
        });
        addTearDown(client.close);
        await expectLater(
          readFixtureOtp(client, 'ios', (_) async {}),
          throwsA(
            isA<TestFailure>().having(
              (e) => e.message,
              'message',
              'Fixture mailbox returned HTTP $status',
            ),
          ),
        );
        expect(calls, 1);
      }
    },
  );

  test('a stalled mailbox read obeys the total budget', () async {
    final client = MockClient((_) => Completer<http.Response>().future);
    addTearDown(client.close);
    await expectLater(
      readFixtureOtp(
        client,
        'ios',
        (_) async {},
        budget: const Duration(milliseconds: 30),
      ),
      throwsA(
        isA<TestFailure>().having(
          (e) => e.message,
          'message',
          'Fixture mailbox deadline reached (timeout)',
        ),
      ),
    );
  });

  test(
    'a lost acknowledgement allows the next stage without resending',
    () async {
      final accepted = <String>[];
      final lost = Completer<http.Response>();
      final client = MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.url, progress);
        accepted.add(jsonDecode(req.body)['stage'] as String);
        if (accepted.length == 1) return lost.future;
        return http.Response('', 200);
      });
      addTearDown(client.close);
      await reportAndroidProgress(
        client,
        progress,
        'otp_verify_tapped',
        timeout: const Duration(milliseconds: 20),
      );
      await reportAndroidProgress(
        client,
        progress,
        'load_family_task_and_wallet',
      );
      lost.complete(http.Response('', 200));
      expect(accepted, ['otp_verify_tapped', 'load_family_task_and_wallet']);
    },
  );

  test(
    'a dropped connection is diagnostic and protocol rejections still fail',
    () async {
      var attempts = 0;
      final client = MockClient((req) async {
        if (++attempts == 1) {
          throw http.ClientException('private details', req.url);
        }
        return http.Response('', 409);
      });
      addTearDown(client.close);
      await reportAndroidProgress(client, progress, 'otp_verify_tapped');
      await expectLater(
        reportAndroidProgress(client, progress, 'complete_task'),
        throwsA(isA<TestFailure>()),
      );
      expect(attempts, 2);
    },
  );

  test('a genuine assertion is never treated as a transport failure', () async {
    final client = MockClient(
      (_) async => throw TestFailure('fixture assertion'),
    );
    addTearDown(client.close);
    await expectLater(
      reportAndroidProgress(client, progress, 'fixture'),
      throwsA(isA<TestFailure>()),
    );
  });

  testWidgets('ready action and title must coexist on the same task card', (
    tester,
  ) async {
    final phase = ValueNotifier(0);
    addTearDown(phase.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          children: [
            ValueListenableBuilder<int>(
              valueListenable: phase,
              builder: (context, value, _) => Card(
                key: const ValueKey('home-task:child:task'),
                child: Column(
                  children: [
                    if (value != 1) const Text('开始'),
                    if (value != 0) const Text('fixture title'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    Timer(const Duration(milliseconds: 200), () => phase.value = 1);
    Timer(const Duration(milliseconds: 400), () => phase.value = 2);
    final card = find.byKey(const ValueKey('home-task:child:task'));
    Finder onCard(String text) =>
        find.descendant(of: card, matching: find.text(text));
    await showFixtureTarget(
      tester,
      find.byType(Scrollable),
      onCard('开始'),
      'ready task',
      matches: () =>
          card.evaluate().length == 1 &&
          onCard('fixture title').evaluate().length == 1,
    );
    expect(phase.value, 2);
  });

  test(
    'failure reporting only retains the fixture line and error category',
    () {
      final details = FlutterErrorDetails(
        exception: StateError('private message'),
        stack: StackTrace.fromString(
          'private/path/integration_test/cross_device_sync_test.dart:348:17',
        ),
      );
      expect(
        fixtureFailureMark(details),
        'AC01_UI_FAILURE kind=state line=348',
      );
      expect(
        fixtureFailureMark(
          FlutterErrorDetails(exception: Exception('private data')),
        ),
        'AC01_UI_FAILURE kind=other line=unknown',
      );
    },
  );
}
