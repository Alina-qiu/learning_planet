import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../integration_test/cross_device_sync_test.dart'
    show fixtureFailureMark, reportAndroidProgress, showFixtureTarget;

void main() {
  final progress = Uri.http('127.0.0.1:54324', '/progress', {
    'device': 'android',
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
