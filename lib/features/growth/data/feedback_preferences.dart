import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FeedbackPreferences {
  const FeedbackPreferences({this.sound = false, this.animation = true});
  final bool sound, animation;
  Map<String, dynamic> toJson() => {'sound': sound, 'animation': animation};
  factory FeedbackPreferences.fromJson(Map<String, dynamic> value) {
    if (value['sound'] is! bool || value['animation'] is! bool) {
      throw const FormatException('Invalid feedback preferences');
    }
    return FeedbackPreferences(
      sound: value['sound'] as bool,
      animation: value['animation'] as bool,
    );
  }
}

abstract interface class FeedbackPreferencesStore {
  Future<FeedbackPreferences> read();
  Future<void> write(FeedbackPreferences value);
}

/// Two device-wide presentation flags; never contains account or child data.
class DeviceFeedbackPreferences implements FeedbackPreferencesStore {
  DeviceFeedbackPreferences([SharedPreferencesAsync? storage])
    : _storage = storage;
  SharedPreferencesAsync? _storage;
  SharedPreferencesAsync get storage => _storage ??= SharedPreferencesAsync();
  static const key = 'learning_planet.task_feedback.v1';
  @override
  Future<FeedbackPreferences> read() async {
    final encoded = await storage.getString(key);
    return encoded == null
        ? const FeedbackPreferences()
        : FeedbackPreferences.fromJson(
            jsonDecode(encoded) as Map<String, dynamic>,
          );
  }

  @override
  Future<void> write(FeedbackPreferences value) =>
      storage.setString(key, jsonEncode(value.toJson()));
}

class FeedbackPreferencesState {
  const FeedbackPreferencesState({
    this.value = const FeedbackPreferences(sound: false, animation: false),
    this.ready = false,
    this.saving = false,
    this.error,
  });
  final FeedbackPreferences value;
  final bool ready, saving;
  final String? error;
}

final feedbackPreferencesStoreProvider = Provider<FeedbackPreferencesStore>(
  (ref) => DeviceFeedbackPreferences(),
);
final feedbackPreferencesProvider =
    StateNotifierProvider<
      FeedbackPreferencesController,
      FeedbackPreferencesState
    >(
      (ref) => FeedbackPreferencesController(
        ref.watch(feedbackPreferencesStoreProvider),
      ),
    );

class FeedbackPreferencesController
    extends StateNotifier<FeedbackPreferencesState> {
  FeedbackPreferencesController(this.store)
    : super(const FeedbackPreferencesState()) {
    load();
  }
  final FeedbackPreferencesStore store;
  bool _reading = false;
  Future<void> load() async {
    if (_reading || state.saving) return;
    _reading = true;
    state = const FeedbackPreferencesState();
    try {
      final value = await store.read();
      if (mounted) state = FeedbackPreferencesState(value: value, ready: true);
    } catch (_) {
      if (mounted) {
        state = const FeedbackPreferencesState(error: '未能读取偏好，声音和动画暂时关闭。请重试。');
      }
    } finally {
      _reading = false;
    }
  }

  Future<void> save(FeedbackPreferences value) async {
    if (!state.ready || state.saving) return;
    final previous = state.value;
    state = FeedbackPreferencesState(
      value: previous,
      ready: true,
      saving: true,
    );
    try {
      await store.write(value);
      if (mounted) state = FeedbackPreferencesState(value: value, ready: true);
    } catch (_) {
      if (mounted) {
        state = FeedbackPreferencesState(
          value: previous,
          ready: true,
          error: '偏好未能保存，仍使用原设置。请重试。',
        );
      }
    }
  }
}
