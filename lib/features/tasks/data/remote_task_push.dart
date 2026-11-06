import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/security/device_secrets.dart';
import '../../notifications/data/remote_parent_push.dart';

abstract interface class TaskPushNative implements ParentPushNative {
  Future<bool> plan(int revision, List<Map<String, Object>> slots);
}

class MethodChannelTaskPush implements TaskPushNative {
  const MethodChannelTaskPush();
  static const channel = MethodChannel('learning_planet/task_push');
  bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  @override
  Future<Map<String, dynamic>> availability() async => !_supported
      ? {}
      : Map<String, dynamic>.from(
          await channel.invokeMethod<Map>('availability') ?? {},
        );
  @override
  Future<int> disable({bool startup = false}) async => !_supported
      ? 0
      : (await channel.invokeMethod<num>(
          startup ? 'startup' : 'disable',
        ))!.toInt();
  @override
  Future<String?> token(int revision) =>
      channel.invokeMethod<String>('token', {'revision': revision});
  @override
  Future<bool> enable(Map<String, dynamic> gate) async =>
      await channel.invokeMethod<bool>('enable', gate) == true;
  @override
  Future<bool> plan(int revision, List<Map<String, Object>> slots) async =>
      await channel.invokeMethod<bool>('plan', {
        'revision': revision,
        'slots': slots,
      }) ==
      true;
}

class SupabaseTaskPushRemote implements ParentPushRemote {
  SupabaseTaskPushRemote(this.client, this.anonymous);
  final SupabaseClient client, anonymous;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async => Map<String, dynamic>.from(
    await client.rpc(name, params: params).timeout(const Duration(seconds: 10))
        as Map,
  );
  @override
  Future<void> revoke(Map<String, dynamic> params) async {
    final result = await anonymous
        .rpc('revoke_task_push_device', params: params)
        .timeout(const Duration(seconds: 10));
    if (result is! Map ||
        result['revoked'] != true ||
        result['device_id'] != params['target_device_id'] ||
        result['intent_version'] != params['requested_version']) {
      throw const FormatException('任务提醒撤销回执不匹配');
    }
  }
}

/// A task installation belongs to one selected child. Native delivery is fenced
/// before network/storage work, and only locally valid reminder slots may show.
class RemoteTaskPush {
  RemoteTaskPush({
    required this.native,
    required this.remote,
    required this.secrets,
    required String backendUrl,
    required this.accountId,
    required this.privacyGeneration,
    this.configured = false,
  }) : storageKey = 'task-push-v1:${sha256.convert(utf8.encode(backendUrl))}';
  final TaskPushNative native;
  final ParentPushRemote remote;
  final DeviceSecrets secrets;
  final String storageKey;
  final String? Function() accountId;
  final int Function() privacyGeneration;
  final bool configured;
  final _uptime = Stopwatch()..start();
  Future<void> _storageQueue = Future.value(), _syncQueue = Future.value();
  int _generation = 0, _scopeIntent = 0, _nextRefresh = 0;
  int? _revision;
  String? _scope;
  bool _pendingDisable = false, _revoking = false;

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _storageQueue.then((_) => operation());
    _storageQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<Map<String, dynamic>?> _read() async {
    final raw = await secrets.read(storageKey);
    if (raw == null) return null;
    try {
      final row = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (row['schema'] != 1 ||
          row['device'] is! String ||
          !Uuid.isValidUUID(fromString: row['device']) ||
          row['secret'] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(row['secret']) ||
          row['version'] is! int ||
          row['version'] < 1 ||
          row['version'] >= 9007199254740990 ||
          !{
            'disabled',
            'preparing',
            'enabled',
            'revoking',
          }.contains(row['state'])) {
        throw const FormatException();
      }
      if (row['state'] == 'enabled' &&
          (row['owner'] is! String ||
              row['child'] is! String ||
              !Uuid.isValidUUID(fromString: row['child']) ||
              row['nonce'] is! String ||
              !Uuid.isValidUUID(fromString: row['nonce']) ||
              row['native_revision'] is! int)) {
        throw const FormatException();
      }
      return row;
    } catch (_) {
      throw const LocalDataException('任务提醒记录暂时无法读取，请保持关闭并重试。');
    }
  }

  Future<void> _write(Map<String, dynamic> row) =>
      secrets.write(storageKey, jsonEncode(row));
  Map<String, dynamic> _identity() {
    final random = Random.secure();
    return {
      'schema': 1,
      'device': const Uuid().v4(),
      'version': 1,
      'state': 'disabled',
      'secret': base64Url
          .encode(List.generate(32, (_) => random.nextInt(256)))
          .replaceAll('=', ''),
    };
  }

  Map<String, dynamic> _capability(Map<String, dynamic> row) => {
    'target_device_id': row['device'],
    'device_secret': row['secret'],
    'requested_version': row['version'],
  };

  Future<void> initialize() async {
    Map<String, dynamic> before;
    try {
      before = await native.availability();
    } catch (_) {
      before = {};
    }
    _revision = await native.disable(startup: true);
    Map<String, dynamic>? row;
    try {
      row = await _serialize(_read);
    } catch (_) {
      _revision = await native.disable();
      _pendingDisable = true;
      return;
    }
    if (row?['state'] == 'enabled') _scope = row!['child'] as String;
    if (before['enabled'] == true && row?['state'] != 'enabled' ||
        row?['state'] == 'preparing' ||
        row?['state'] == 'enabled' &&
            (!configured ||
                row?['owner'] != accountId() ||
                before['enabled'] != true ||
                before['revision'] != row?['native_revision'])) {
      await disable();
    } else {
      unawaited(flushRevocation());
    }
  }

  Future<void> setScope(String? scope) async {
    final child = scope != null && Uuid.isValidUUID(fromString: scope)
        ? scope
        : null;
    if (child != null && child == _scope && !_pendingDisable) return;
    final intent = ++_scopeIntent;
    await disable();
    if (intent == _scopeIntent) _scope = child;
  }

  Future<void> disable() async {
    final generation = ++_generation;
    _scope = null;
    _nextRefresh = 0;
    _pendingDisable = true;
    final revision = await native.disable();
    if (generation != _generation) return;
    _revision = revision;
    try {
      await _serialize(() async {
        final previous = await _read();
        if (generation != _generation ||
            previous == null ||
            {'disabled', 'revoking'}.contains(previous['state'])) {
          return;
        }
        await _write({
          'schema': 1,
          'device': previous['device'],
          'secret': previous['secret'],
          'version': (previous['version'] as int) + 1,
          'state': 'revoking',
        });
      });
      if (generation == _generation) _pendingDisable = false;
    } catch (_) {
      if (generation == _generation) _pendingDisable = true;
    }
    unawaited(flushRevocation());
  }

  Future<void> flushRevocation() async {
    if (_revoking) return;
    _revoking = true;
    try {
      if (_pendingDisable) await disable();
      final row = await _serialize(_read);
      if (row == null || row['state'] != 'revoking') return;
      await remote.revoke(_capability(row));
      await _serialize(() async {
        final latest = await _read();
        if (latest?['version'] == row['version'] &&
            latest?['state'] == 'revoking') {
          await _write({...row, 'state': 'disabled'});
        }
      });
    } catch (_) {
      /* The capability remains durable for the next foreground retry. */
    } finally {
      _revoking = false;
    }
  }

  Future<void> synchronize(String child, List<Map<String, Object>> slots) {
    final generation = _generation;
    final result = _syncQueue.then((_) async {
      if (_scope == child && generation == _generation) {
        try {
          await _synchronize(child, slots);
        } catch (_) {
          if (generation == _generation) await disable();
          rethrow;
        }
      }
    });
    _syncQueue = result.catchError((Object _) {});
    return result;
  }

  Future<void> _synchronize(
    String child,
    List<Map<String, Object>> slots,
  ) async {
    final owner = accountId(),
        generation = _generation,
        privacy = privacyGeneration();
    bool current() =>
        owner != null &&
        accountId() == owner &&
        generation == _generation &&
        privacy == privacyGeneration() &&
        _scope == child &&
        !_pendingDisable;
    void check() {
      if (!current()) throw StateError('任务提醒范围已变化，请刷新。');
    }

    check();
    unawaited(flushRevocation());
    var revision = _revision;
    if (revision == null) {
      revision = await native.disable();
      check();
      _revision = revision;
    }
    if (!await native.plan(revision, slots)) {
      throw StateError('任务提醒校验未能更新，请重试。');
    }
    check();
    // An empty plan closes native delivery, including offline completed tasks.
    if (slots.isEmpty) return;
    if (!configured) throw StateError('此版本尚未配置 iPhone 远程任务提醒，应用内提醒仍可使用。');
    var row = await _serialize(_read);
    check();
    final active =
        row?['state'] == 'enabled' &&
        row?['owner'] == owner &&
        row?['child'] == child;
    if (active && _uptime.elapsedMilliseconds < _nextRefresh) return;
    try {
      if (!active) {
        revision = await native.disable();
        check();
        _revision = revision;
        final available = await native.availability();
        check();
        if (available['available'] != true ||
            available['transport'] != 'apns') {
          throw StateError('此设备暂不支持远程任务提醒。');
        }
        row = await _serialize(() async {
          final previous = await _read() ?? _identity();
          check();
          final next = {
            ...previous,
            'version': (previous['version'] as int) + 1,
            'state': 'preparing',
            'owner': owner,
            'child': child,
            'nonce': const Uuid().v4(),
          };
          await _write(next);
          check();
          return next;
        });
        final preparing = row!;
        final prepared = await remote.call('prepare_task_push_device', {
          ..._capability(preparing),
          'target_child_id': child,
          'requested_nonce': preparing['nonce'],
        });
        _validateReply(prepared, preparing, 'prepared');
        check();
      }
      final identity = row!;
      final token = await native.token(revision);
      check();
      if (token == null || token.isEmpty) {
        throw StateError('暂未取得 iPhone 远程提醒授权，请重试。');
      }
      final watch = Stopwatch()..start();
      final reply = await remote.call(
        active ? 'renew_task_push_device' : 'activate_task_push_device',
        {..._capability(identity), 'push_token': token},
      );
      _validateReply(reply, identity, 'enabled');
      check();
      final server = DateTime.parse(reply['server_time'] as String),
          expires = DateTime.parse(reply['expires_at'] as String);
      final policyVersion = reply['settings_version'];
      if (watch.elapsedMilliseconds > 10000 ||
          !expires.isAfter(server) ||
          expires.difference(server) > const Duration(days: 30, seconds: 1) ||
          policyVersion is! int ||
          policyVersion < 1) {
        throw const FormatException('任务提醒时间校验失败');
      }
      if (!await native.plan(revision, slots)) throw StateError('任务提醒校验未能更新。');
      check();
      await _serialize(() async {
        check();
        await _write({
          ...identity,
          'state': 'enabled',
          'native_revision': revision,
        });
      });
      check();
      if (!await native.enable({
        'revision': revision,
        'scope_nonce': identity['nonce'],
        'server_ms': server.millisecondsSinceEpoch,
        'expires_ms': expires.millisecondsSinceEpoch,
        'rtt_ms': watch.elapsedMilliseconds,
        'settings_version': policyVersion,
      })) {
        throw StateError('任务提醒接收校验未能启用。');
      }
      check();
      _nextRefresh =
          _uptime.elapsedMilliseconds +
          const Duration(hours: 12).inMilliseconds;
    } catch (_) {
      if (generation == _generation) {
        final intent = _scopeIntent;
        await disable();
        if (_generation == generation + 1 &&
            intent == _scopeIntent &&
            accountId() == owner &&
            privacyGeneration() == privacy) {
          _scope = child;
        }
      }
      rethrow;
    }
  }

  void _validateReply(
    Map<String, dynamic> reply,
    Map<String, dynamic> row,
    String state,
  ) {
    if (reply['device_id'] != row['device'] ||
        reply['child_id'] != row['child'] ||
        reply['scope_nonce'] != row['nonce'] ||
        reply['intent_version'] != row['version'] ||
        reply['state'] != state ||
        reply['transport'] != 'apns') {
      throw const FormatException('任务提醒回执范围不匹配');
    }
  }
}
