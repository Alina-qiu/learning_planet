import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/feedback_preferences.dart';

class FeedbackSettingsScreen extends ConsumerWidget {
  const FeedbackSettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(feedbackPreferencesProvider);
    final controller = ref.read(feedbackPreferencesProvider.notifier);
    final enabled = state.ready && !state.saving;
    return Scaffold(
      appBar: AppBar(title: const Text('声音与动画')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('任务完成反馈', style: TextStyle(fontSize: 20)),
          const Text('这些偏好只保存在这台设备，对本机所有孩子生效。'),
          if ((!state.ready && state.error == null) || state.saving)
            const LinearProgressIndicator(),
          SwitchListTile(
            title: const Text('完成提示音'),
            subtitle: const Text('短促系统提示音，遵守设备声音设置。默认关闭。'),
            value: state.value.sound,
            onChanged: enabled
                ? (v) => controller.save(
                    FeedbackPreferences(
                      sound: v,
                      animation: state.value.animation,
                    ),
                  )
                : null,
          ),
          SwitchListTile(
            title: const Text('任务反馈动画'),
            subtitle: const Text('小怪兽轻动和能量变化，播放不超过2秒。'),
            value: state.value.animation,
            onChanged: enabled
                ? (v) => controller.save(
                    FeedbackPreferences(sound: state.value.sound, animation: v),
                  )
                : null,
          ),
          if (MediaQuery.disableAnimationsOf(context) ||
              MediaQuery.accessibleNavigationOf(context))
            const Text('系统已启用减少动态效果或辅助导航，本应用将使用静态反馈。'),
          const Text('关闭后仍显示完成状态和同步提示，不影响任务、金币、XP或成长解锁。'),
          if (state.error != null) ...[
            Text(state.error!),
            if (!state.ready)
              OutlinedButton(
                onPressed: controller.load,
                child: const Text('重试读取'),
              ),
          ],
        ],
      ),
    );
  }
}
