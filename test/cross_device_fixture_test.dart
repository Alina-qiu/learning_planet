import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/cross_device_sync_test.dart'
    show fixtureFailureMark, showFixtureTarget;

void main() {
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
