import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/security/device_secrets.dart';
import '../domain/parent_notification.dart';

final remoteParentPushProvider = Provider<RemoteParentPush?>((_) => null);
final remoteParentPushRevisionProvider = StateProvider<int>((_) => 0);
final remoteParentPushStatusProvider = FutureProvider.autoDispose
    .family<RemotePushStatus, String>((ref, family) {
      ref.watch(remoteParentPushRevisionProvider);
      final controller = ref.watch(remoteParentPushProvider);
      if (controller == null) {
        return Future.value(RemotePushStatus.unconfigured);
      }
      controller.addListener(ref.invalidateSelf);
      ref.onDispose(() => controller.removeListener(ref.invalidateSelf));
      return controller.status(family);
    });

enum RemotePushStatus { unconfigured, unavailable, disabled, enabled, revoking }

abstract interface class ParentPushNative {
  Future<Map<String, dynamic>> availability();
  Future<int> disable({bool startup = false});
  Future<String?> token(int revision);
  Future<bool> enable(Map<String, dynamic> gate);
}

class MethodChannelParentPush implements ParentPushNative {
  const MethodChannelParentPush();
  static const channel = MethodChannel('learning_planet/parent_push');
  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
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
}

abstract interface class ParentPushRemote {
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> params);
  Future<void> revoke(Map<String, dynamic> params);
}

class SupabaseParentPushRemote implements ParentPushRemote {
  SupabaseParentPushRemote(this.client, this.anonymous);
  final SupabaseClient client;

  /// Separate, never-signed-in client: revocation must not retain an old JWT.
  final SupabaseClient anonymous;
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
        .rpc('revoke_parent_push_device', params: params)
        .timeout(const Duration(seconds: 10));
    if (result is! Map ||
        result['revoked'] != true ||
        result['device_id'] != params['target_device_id'] ||
        result['intent_version'] != params['requested_version']) {
      throw const FormatException('后台提醒撤销回执不匹配');
    }
  }
}

/// Installation capabilities are kept in device secure storage, never in child
/// exports or account JWTs. All persistence is serialized; network calls aren't,
/// so a local disable can overtake a stalled activation. Native revision checks
/// fence a late MethodChannel enable as well as late server replies.
class RemoteParentPush extends ChangeNotifier {
  RemoteParentPush({
    required this.native,
    required this.remote,
    required this.secrets,
    required String backendUrl,
    required this.accountId,
    required this.privacyGeneration,
    this.configured = false,
  }) : storageKey = 'parent-push-v1:${sha256.convert(utf8.encode(backendUrl))}';
  final ParentPushNative native;
  final ParentPushRemote remote;
  final DeviceSecrets secrets;
  final String storageKey;
  final String? Function() accountId;
  final int Function() privacyGeneration;
  final bool configured;
  Future<void> _storageQueue = Future.value();
  final _uptime = Stopwatch()..start();
  int _generation = 0, _nextRefresh = 0;
  int? _nativeRevision;
  String? _boundScope;
  String? _pendingDisabledScope;
  bool _refreshing = false, _revoking = false;
  bool _pendingLocalDisable = false;

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
          !Uuid.isValidUUID(fromString: row['device'] as String) ||
          row['secret'] is! String ||
          !RegExp(
            r'^[A-Za-z0-9_-]{43,128}$',
          ).hasMatch(row['secret'] as String) ||
          row['version'] is! int ||
          (row['version'] as int) < 1 ||
          (row['version'] as int) >= 9007199254740990 ||
          !{
            'preparing',
            'enabled',
            'revoking',
            'disabled',
          }.contains(row['state'])) {
        throw const FormatException();
      }
      if (row['state'] == 'enabled' &&
          (row['owner'] is! String ||
              row['family'] is! String ||
              row['native_revision'] is! int ||
              row['nonce'] is! String ||
              !Uuid.isValidUUID(fromString: row['nonce'] as String) ||
              !{'hms', 'apns'}.contains(row['transport']))) {
        throw const FormatException();
      }
      return row;
    } catch (_) {
      // Do not replace a corrupt capability: that could orphan an active server
      // registration. Native delivery is disabled before any recovery attempt.
      throw const LocalDataException('后台提醒记录暂时无法读取，请保持关闭并重试。');
    }
  }

  Map<String, dynamic> _newIdentity() {
    final random = Random.secure();
    return {
      'schema': 1,
      'device': const Uuid().v4(),
      'secret': base64Url
          .encode(List.generate(32, (_) => random.nextInt(256)))
          .replaceAll('=', ''),
      'version': 1,
      'state': 'disabled',
    };
  }

  Future<void> _write(Map<String, dynamic> row) =>
      secrets.write(storageKey, jsonEncode(row));
  Map<String, dynamic> _capability(Map<String, dynamic> row) => {
    'target_device_id': row['device'],
    'device_secret': row['secret'],
    'requested_version': row['version'],
  };
  bool _current(String owner, int generation, int privacy) =>
      accountId() == owner &&
      generation == _generation &&
      privacyGeneration() == privacy;

  Future<void> initialize() async {
    Map<String, dynamic> before;
    try {
      before = await native.availability();
    } catch (_) {
      before = {};
    }
    _nativeRevision = await native.disable(startup: true);
    Map<String, dynamic>? row;
    try {
      row = await _serialize(_read);
    } catch (_) {
      // An optional reminder must not prevent opening the learning app after
      // native delivery has been durably fenced. Keep its capability to retry.
      _pendingLocalDisable = true;
      return;
    }
    if (row?['state'] == 'enabled') {
      _boundScope = 'parent:${row!['owner']}:${row['family']}';
    }
    if (row?['state'] == 'preparing' ||
        row?['state'] == 'enabled' &&
            (row?['owner'] != accountId() ||
                !configured ||
                before['enabled'] != true ||
                before['revision'] != row?['native_revision'])) {
      await disable();
    } else {
      unawaited(flushRevocation());
    }
  }

  Future<RemotePushStatus> status(String family) async {
    if (!configured) return RemotePushStatus.unconfigured;
    final available = await native.availability();
    if (available['configured'] != true) return RemotePushStatus.unconfigured;
    if (available['available'] != true) return RemotePushStatus.unavailable;
    final row = await _serialize(_read);
    if (row?['state'] == 'revoking') return RemotePushStatus.revoking;
    return row?['state'] == 'enabled' &&
            row?['owner'] == accountId() &&
            row?['family'] == family &&
            available['enabled'] == true &&
            available['revision'] == row?['native_revision']
        ? RemotePushStatus.enabled
        : RemotePushStatus.disabled;
  }

  Future<void> setScope(String? scope) async {
    if (scope == null || scope != _boundScope) await disable();
  }

  Future<void> disableFamilyAccess(String owner, String family) =>
      accountId() == owner &&
          (_boundScope == 'parent:$owner:$family' ||
              _pendingLocalDisable &&
                  _pendingDisabledScope == 'parent:$owner:$family')
      ? disable()
      : Future.value();

  Future<void> disable() async {
    final generation = ++_generation;
    _pendingDisabledScope = _boundScope ?? _pendingDisabledScope;
    _boundScope = null;
    _nextRefresh = 0;
    _pendingLocalDisable = true;
    // Complete the native fence before touching secure storage or the network.
    final revision = await native.disable();
    if (generation != _generation) return;
    _nativeRevision = revision;
    notifyListeners();
    try {
      await _serialize(() async {
        final previous = await _read();
        if (generation != _generation) return;
        if (previous == null ||
            previous['state'] == 'disabled' ||
            previous['state'] == 'revoking') {
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
      if (generation == _generation) {
        _pendingLocalDisable = false;
        _pendingDisabledScope = null;
      }
    } catch (_) {
      // Native revision persists even if secure storage is unavailable. On the
      // next launch a stale active row cannot silently restore this opt-out.
      if (generation == _generation) _pendingLocalDisable = true;
    }
    notifyListeners();
    unawaited(flushRevocation());
  }

  Future<void> flushRevocation() async {
    if (_revoking) return;
    _revoking = true;
    try {
      var row = await _serialize(_read);
      if (_pendingLocalDisable) {
        await disable();
        row = await _serialize(_read);
      }
      if (row == null || row['state'] != 'revoking') return;
      final pending = row;
      await remote.revoke(_capability(pending));
      await _serialize(() async {
        final latest = await _read();
        if (latest?['version'] == pending['version'] &&
            latest?['state'] == 'revoking') {
          await _write({...pending, 'state': 'disabled'});
          notifyListeners();
        }
      });
    } catch (_) {
      // Durable capability is retried on foreground refresh, even after logout.
    } finally {
      _revoking = false;
    }
  }

  void resumed() {
    _nextRefresh = 0;
    unawaited(flushRevocation());
  }

  Future<void> enable(
    String family,
    ParentNotificationSettings settings, {
    required bool Function() canConfigure,
  }) async {
    final owner = accountId(),
        generation = ++_generation,
        privacy = privacyGeneration();
    if (!configured || owner == null || !settings.enabled || !canConfigure()) {
      throw StateError('请在家长模式下启用通知后重试。');
    }
    bool current() => _current(owner, generation, privacy) && canConfigure();
    try {
      final revision = await native.disable();
      if (!current()) throw StateError('后台提醒授权已变化。');
      _nativeRevision = revision;
      final available = await native.availability();
      if (available['configured'] != true ||
          available['available'] != true ||
          !{'hms', 'apns'}.contains(available['transport'])) {
        throw StateError('当前版本或设备尚不支持后台提醒。');
      }
      if (!current()) throw StateError('后台提醒授权已变化。');
      final row = await _serialize(() async {
        final previous = await _read() ?? _newIdentity();
        if (!current()) throw StateError('后台提醒授权已变化。');
        final next = {
          ...previous,
          'version': (previous['version'] as int) + 1,
          'state': 'preparing',
          'owner': owner,
          'family': family,
          'nonce': const Uuid().v4(),
          'transport': available['transport'],
        };
        await _write(next);
        if (!current()) throw StateError('后台提醒授权已变化。');
        _pendingLocalDisable = false;
        _pendingDisabledScope = null;
        _boundScope = 'parent:$owner:$family';
        return next;
      });
      final prepared = await remote.call('prepare_parent_push_device', {
        ..._capability(row),
        'target_family_id': family,
        'requested_nonce': row['nonce'],
      });
      _validateReply(prepared, row, 'prepared');
      if (!current()) throw StateError('后台提醒授权已变化。');
      final token = await native.token(revision);
      if (token == null || token.isEmpty) throw StateError('暂未取得后台提醒授权，请重试。');
      if (!current()) throw StateError('后台提醒授权已变化。');
      final watch = Stopwatch()..start();
      final enabled = await remote.call('activate_parent_push_device', {
        ..._capability(row),
        'requested_transport': row['transport'],
        'push_token': token,
      });
      _validateReply(enabled, row, 'enabled');
      if (!current()) throw StateError('后台提醒授权已变化。');
      await _serialize(() async {
        if (!current()) throw StateError('后台提醒授权已变化。');
        await _write({...row, 'state': 'enabled', 'native_revision': revision});
      });
      if (!current() ||
          !await _enableGate(revision, enabled, settings, watch)) {
        throw StateError('后台提醒范围已变化，请重试。');
      }
      if (!current()) throw StateError('后台提醒授权已变化。');
      notifyListeners();
      _nextRefresh =
          _uptime.elapsedMilliseconds +
          const Duration(hours: 12).inMilliseconds;
    } catch (_) {
      // A newer intent owns its own native fence and pending revoke. Never let
      // the old request's exception disable that newer registration.
      if (_generation == generation) await disable();
      rethrow;
    }
  }

  void _validateReply(
    Map<String, dynamic> reply,
    Map<String, dynamic> row,
    String state,
  ) {
    if (reply['device_id'] != row['device'] ||
        reply['family_id'] != row['family'] ||
        reply['scope_nonce'] != row['nonce'] ||
        reply['intent_version'] != row['version'] ||
        reply['state'] != state ||
        state == 'enabled' && reply['transport'] != row['transport']) {
      throw const FormatException('后台提醒回执范围不匹配');
    }
  }

  Future<bool> _enableGate(
    int revision,
    Map<String, dynamic> reply,
    ParentNotificationSettings settings,
    Stopwatch watch,
  ) async {
    final now = DateTime.parse(reply['server_time'] as String).toUtc();
    final expires = DateTime.parse(reply['expires_at'] as String).toUtc();
    if (watch.elapsedMilliseconds > 10000 ||
        !expires.isAfter(now) ||
        expires.difference(now) > const Duration(days: 30, seconds: 1)) {
      return false;
    }
    return native.enable({
      'revision': revision,
      'scope_nonce': reply['scope_nonce'],
      'server_ms': now.millisecondsSinceEpoch,
      'expires_ms': expires.millisecondsSinceEpoch,
      'rtt_ms': watch.elapsedMilliseconds,
      'settings_version': settings.version,
    });
  }

  Future<void> refresh(
    String family,
    ParentNotificationSettings settings,
  ) async {
    unawaited(flushRevocation());
    if (!configured ||
        _pendingLocalDisable ||
        _refreshing ||
        _uptime.elapsedMilliseconds < _nextRefresh) {
      return;
    }
    _refreshing = true;
    final owner = accountId(),
        generation = _generation,
        privacy = privacyGeneration();
    try {
      final row = await _serialize(_read);
      if (row == null || row['state'] != 'enabled') return;
      if (owner == null ||
          row['owner'] != owner ||
          row['family'] != family ||
          !settings.enabled) {
        await disable();
        return;
      }
      bool current() => _current(owner, generation, privacy);
      final revision = _nativeRevision;
      if (revision == null || !current()) return;
      final token = await native.token(revision);
      if (token == null || !current()) return;
      final watch = Stopwatch()..start();
      final reply = await remote.call('renew_parent_push_device', {
        ..._capability(row),
        'push_token': token,
      });
      _validateReply(reply, row, 'enabled');
      if (!current()) return;
      await _serialize(() async {
        if (!current()) return;
        await _write({...row, 'native_revision': revision});
      });
      if (!current()) return;
      if (!await _enableGate(revision, reply, settings, watch)) {
        if (current()) await disable();
        return;
      }
      notifyListeners();
      _nextRefresh =
          _uptime.elapsedMilliseconds +
          const Duration(hours: 12).inMilliseconds;
    } on PostgrestException catch (error) {
      if (generation == _generation &&
          (error.code == '42501' ||
              error.message.contains('STALE_PUSH_DEVICE_INTENT'))) {
        await disable();
      }
      _nextRefresh = _uptime.elapsedMilliseconds + 60000;
    } catch (_) {
      _nextRefresh = _uptime.elapsedMilliseconds + 60000;
    } finally {
      _refreshing = false;
    }
  }
}
