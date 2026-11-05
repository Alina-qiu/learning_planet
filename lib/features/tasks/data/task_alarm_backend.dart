import 'package:flutter/services.dart';

/// Android owns delivery-time checks; no child identity or task text is sent.
abstract interface class TaskAlarmBackend {
  Future<void> clear();
  Future<void> replace(List<Map<String, Object>> alarms);
}

class MethodChannelTaskAlarms implements TaskAlarmBackend {
  static const channel = MethodChannel('learning_planet/task_alarms');
  int? _revision;
  @override
  Future<void> clear() async {
    _revision = await channel.invokeMethod<int>('clear');
    if (_revision == null) throw StateError('本机提醒范围未能清理');
  }

  @override
  Future<void> replace(List<Map<String, Object>> alarms) async {
    if (_revision == null) await clear();
    try {
      await channel.invokeMethod<void>('replace', {
        'revision': _revision,
        'alarms': alarms,
      });
    } on PlatformException {
      // Native replacement failures also retire the previous policy.
      _revision = null;
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> pending() async =>
      (await channel.invokeListMethod<dynamic>('pending') ?? [])
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
}
