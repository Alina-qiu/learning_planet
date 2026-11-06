import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'support/task_push.dart';

void main() {
  test(
    'foreground resume renews the native clock and device token before the twelve-hour lease refresh',
    () async {
      final h = Harness();
      await h.enable();
      await h.push.synchronize(child, slots);
      expect(h.remote.calls.length, 2);
      h.push.resumed();
      await h.push.synchronize(child, slots);
      expect(h.remote.calls.last, 'renew_task_push_device');
      expect(h.remote.calls.length, 3);
      expect(h.native.enabled, isTrue);
    },
  );
  test(
    'background startup with no matching secure capability closes an old native gate',
    () async {
      final h = Harness();
      h.native.enabled = true;
      h.native.backgroundStartup = true;
      await h.push.initialize();
      expect(h.native.enabled, isFalse);
      expect(h.remote.calls, isEmpty);
    },
  );
  test(
    'background startup while secure storage is locked suspends native delivery until scope can be checked',
    () async {
      final h = Harness();
      await h.enable();
      h.native.backgroundStartup = true;
      h.secrets.failRead = true;
      await h.controller().initialize();
      expect(h.native.enabled, isFalse);
      expect(h.native.slots, isEmpty);
    },
  );
  test(
    'task registration binds one child, persists capability and publishes only a native slot policy',
    () async {
      final h = Harness();
      await h.enable();
      expect(h.remote.calls, [
        'prepare_task_push_device',
        'activate_task_push_device',
      ]);
      expect(h.row['child'], child);
      expect(h.row['state'], 'enabled');
      expect(h.native.enabled, isTrue);
      expect(h.native.gate!['settings_version'], 3);
      expect(h.native.slots, slots);
      final encoded = jsonEncode(h.native.gate);
      expect(encoded, isNot(contains(child)));
      expect(encoded, isNot(contains('owner')));
      expect(encoded, isNot(contains(h.row['secret'] as String)));
      await h.push.synchronize(child, slots);
      expect(h.remote.calls.length, 2);
      await h.push.synchronize(child, []);
      expect(h.native.slots, isEmpty);
      expect(
        h.native.enabled,
        isTrue,
      ); // Gate remains scoped, but has no allowed task slot.
    },
  );
  test(
    'switching child fences the old native plan before preparing the new scope',
    () async {
      final h = Harness();
      await h.enable();
      final nonce = h.row['nonce'];
      await h.push.setScope(sibling);
      expect(h.native.enabled, isFalse);
      expect(h.native.slots, isEmpty);
      await h.push.synchronize(child, slots);
      expect(h.native.enabled, isFalse);
      await h.push.synchronize(sibling, slots);
      expect(h.row['child'], sibling);
      expect(h.row['nonce'], isNot(nonce));
      expect(h.native.enabled, isTrue);
    },
  );
  for (final phase in [
    'prepare_task_push_device',
    'activate_task_push_device',
  ]) {
    test(
      'logout fences delayed $phase and retries capability revoke without a signed-in account',
      () async {
        final h = Harness(),
            entered = Completer<void>(),
            held = Completer<Map<String, dynamic>>();
        Map<String, dynamic>? answer;
        h.remote.intercept = (name, p) {
          final reply = h.remote.reply(name, p);
          if (name == phase) {
            answer = reply;
            entered.complete();
            return held.future;
          }
          return reply;
        };
        final work = h.enable();
        final failed = expectLater(work, throwsStateError);
        await entered.future;
        h.remote.offline = true;
        h.owner = null;
        await h.push.disable();
        await drain();
        expect(h.native.enabled, isFalse);
        expect(h.row['state'], 'revoking');
        held.complete(answer!);
        await failed;
        expect(h.native.enabled, isFalse);
        h.remote.offline = false;
        await h.push.flushRevocation();
        expect(h.row['state'], 'disabled');
        expect(
          h.remote.revoked.last['requested_version'],
          greaterThan(answer!['intent_version'] as int),
        );
      },
    );
  }
  test('a delayed native enable cannot survive a newer disable', () async {
    final h = Harness(), held = Completer<void>();
    h.native.heldEnable = held;
    final work = h.enable();
    final failed = expectLater(work, throwsStateError);
    while (h.native.heldEnable != null) {
      await Future<void>.delayed(Duration.zero);
    }
    await h.push.disable();
    held.complete();
    await failed;
    expect(h.native.enabled, isFalse);
  });
  test(
    'native opt-out survives secure storage failure and a later process reconciles it',
    () async {
      final h = Harness();
      await h.enable();
      h.secrets.fail = true;
      await h.push.disable();
      await drain();
      expect(h.native.enabled, isFalse);
      expect(h.row['state'], 'enabled');
      h.secrets.fail = false;
      final restarted = h.controller();
      await restarted.initialize();
      await drain();
      expect(h.row['state'], 'disabled');
      expect(h.native.enabled, isFalse);
    },
  );
  test(
    'foreground restart renews the server clock and does not assume the previous native revision remains enabled',
    () async {
      final h = Harness();
      await h.enable();
      final oldRevision = h.native.revision;
      final restarted = h.controller();
      await restarted.initialize();
      expect(h.native.enabled, isFalse);
      await restarted.setScope(child);
      await restarted.synchronize(child, slots);
      expect(h.remote.calls.last, 'renew_task_push_device');
      expect(h.native.revision, greaterThan(oldRevision));
      expect(h.native.enabled, isTrue);
      expect(h.row['native_revision'], h.native.revision);
    },
  );
  test(
    'unconfigured builds and denied notification permission never activate a remote task registration',
    () async {
      final h = Harness();
      h.push = h.controller(configured: false);
      await expectLater(h.enable(), throwsStateError);
      expect(h.remote.calls, isEmpty);
      expect(h.native.enabled, isFalse);
      final denied = Harness();
      denied.native.permit = false;
      await expectLater(denied.enable(), throwsStateError);
      expect(denied.remote.calls, ['prepare_task_push_device']);
      expect(denied.native.enabled, isFalse);
    },
  );
  test(
    'corrupt capabilities are retained for recovery without issuing a replacement registration',
    () async {
      final h = Harness();
      h.secrets.values[h.push.storageKey] = '{broken';
      await h.push.initialize();
      await h.push.setScope(child);
      await expectLater(h.push.synchronize(child, slots), throwsStateError);
      expect(h.remote.calls, isEmpty);
      expect(h.native.enabled, isFalse);
      expect(h.secrets.values[h.push.storageKey], '{broken');
    },
  );
  test(
    'a reply for another child fails closed and a new explicit sync can recover',
    () async {
      final h = Harness();
      h.remote.intercept = (name, p) => {
        ...h.remote.reply(name, p),
        'child_id': sibling,
      };
      await expectLater(h.enable(), throwsFormatException);
      expect(h.native.enabled, isFalse);
      h.remote.intercept = null;
      await h.push.setScope(child);
      await h.push.synchronize(child, slots);
      expect(h.native.enabled, isTrue);
    },
  );
  test(
    'privacy generation changes during activation cannot publish the returned gate',
    () async {
      final h = Harness();
      h.remote.intercept = (name, p) {
        final reply = h.remote.reply(name, p);
        if (name == 'activate_task_push_device') h.privacy++;
        return reply;
      };
      await expectLater(h.enable(), throwsStateError);
      expect(h.native.enabled, isFalse);
      expect(h.native.slots, isEmpty);
    },
  );
}
