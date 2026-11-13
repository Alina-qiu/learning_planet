import 'dart:async';
import 'dart:convert';

import 'package:learning_planet/core/security/device_secrets.dart';
import 'package:learning_planet/features/notifications/data/remote_parent_push.dart';
import 'package:learning_planet/features/tasks/data/remote_task_push.dart';

const child = '10000000-0000-4000-8000-000000000001';
const sibling = '10000000-0000-4000-8000-000000000002';
final slots = <Map<String, Object>>[
  {
    'at': 1793937600000,
    'timezone': 'Asia/Shanghai',
    'quiet_start': '21:00:00',
    'quiet_end': '07:00:00',
  },
];

class Secrets implements DeviceSecrets {
  final values = <String, String>{};
  bool fail = false, failRead = false;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw const LocalDataException('locked');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (fail) throw const LocalDataException('locked');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class Native implements TaskPushNative {
  int revision = 0, enables = 0;
  bool enabled = false, permit = true, backgroundStartup = false;
  List<Map<String, Object>> slots = [];
  Map<String, dynamic>? gate;
  Completer<void>? heldEnable;
  @override
  Future<Map<String, dynamic>> availability() async => {
    'transport': 'apns',
    'available': true,
    'configured': true,
    'enabled': enabled,
    'revision': revision,
  };
  @override
  Future<int> disable({bool startup = false}) async {
    if (startup && backgroundStartup) return revision;
    enabled = false;
    slots = [];
    return ++revision;
  }

  @override
  Future<String?> token(int revision) async =>
      revision == this.revision && permit ? 'ab' * 32 : null;
  @override
  Future<bool> plan(int revision, List<Map<String, Object>> slots) async {
    if (revision != this.revision) return false;
    this.slots = [for (final slot in slots) Map.of(slot)];
    return true;
  }

  @override
  Future<bool> enable(Map<String, dynamic> gate) async {
    final held = heldEnable;
    heldEnable = null;
    if (held != null) await held.future;
    if (gate['revision'] != revision || !permit) return false;
    this.gate = Map.of(gate);
    enabled = true;
    enables++;
    return true;
  }
}

class Remote implements ParentPushRemote {
  Map<String, dynamic>? prepared;
  final calls = <String>[], revoked = <Map<String, dynamic>>[];
  FutureOr<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
  intercept;
  bool offline = false;
  Map<String, dynamic> reply(String name, Map<String, dynamic> p) {
    if (name == 'prepare_task_push_device') prepared = Map.of(p);
    return {
      'device_id': p['target_device_id'],
      'child_id': prepared!['target_child_id'],
      'family_id': 'private-family',
      'scope_nonce': prepared!['requested_nonce'],
      'intent_version': p['requested_version'],
      'state': name == 'prepare_task_push_device' ? 'prepared' : 'enabled',
      'transport': 'apns',
      'server_time': '2026-11-06T04:00:00Z',
      'expires_at': '2026-12-06T04:00:00Z',
      'settings_version': 3,
    };
  }

  @override
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> p) async {
    calls.add(name);
    if (offline) throw StateError('offline');
    return intercept == null ? reply(name, p) : await intercept!(name, p);
  }

  @override
  Future<void> revoke(Map<String, dynamic> p) async {
    revoked.add(Map.of(p));
    if (offline) throw StateError('offline');
  }
}

class Harness {
  final native = Native(), remote = Remote(), secrets = Secrets();
  String? owner = 'owner';
  int privacy = 0;
  late RemoteTaskPush push = controller();
  RemoteTaskPush controller({bool configured = true}) => RemoteTaskPush(
    native: native,
    remote: remote,
    secrets: secrets,
    backendUrl: 'https://test.invalid',
    accountId: () => owner,
    privacyGeneration: () => privacy,
    configured: configured,
  );
  Future<void> enable() async {
    await push.initialize();
    await push.setScope(child);
    await push.synchronize(child, slots);
  }

  Map<String, dynamic> get row =>
      jsonDecode(secrets.values[push.storageKey]!) as Map<String, dynamic>;
}

Future<void> drain() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
