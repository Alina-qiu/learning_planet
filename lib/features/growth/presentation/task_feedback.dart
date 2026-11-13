import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/feedback_preferences.dart';
import '../domain/task_adventure.dart';
import '../../tasks/application/task_providers.dart';

final completionSoundProvider = Provider<Future<void> Function()>(
  (ref) =>
      () => SystemSound.play(SystemSoundType.click),
);

bool taskMotionEnabled(BuildContext context, FeedbackPreferences preferences) =>
    preferences.animation &&
    !MediaQuery.disableAnimationsOf(context) &&
    !MediaQuery.accessibleNavigationOf(context);

/// Called only after a durable completion succeeds, never from a refresh/replay.
void showTaskCompletionFeedback(
  BuildContext context,
  WidgetRef ref, {
  required bool pending,
  bool review = false,
}) {
  final lifecycle = WidgetsBinding.instance.lifecycleState;
  if (!context.mounted ||
      ModalRoute.of(context)?.isCurrent == false ||
      (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
    return;
  }
  final preferences = ref.read(feedbackPreferencesProvider).value;
  final motion = taskMotionEnabled(context, preferences);
  final messenger = ScaffoldMessenger.of(context);
  messenger.removeCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(milliseconds: 1500),
      content: TaskCompletionNotice(
        animate: motion,
        message: pending
            ? '完成记录已保存本机，奖励待同步确认'
            : review
            ? '复习已完成'
            : '任务已完成',
      ),
    ),
    snackBarAnimationStyle: AnimationStyle(
      duration: Duration(milliseconds: motion ? 150 : 0),
      reverseDuration: Duration(milliseconds: motion ? 150 : 0),
    ),
  );
  if (preferences.sound) {
    try {
      unawaited(ref.read(completionSoundProvider)().catchError((Object _) {}));
    } catch (_) {
      /* Feedback must never fail a completed operation. */
    }
  }
}

class TaskCompletionNotice extends StatelessWidget {
  const TaskCompletionNotice({
    required this.animate,
    required this.message,
    super.key,
  });
  final bool animate;
  final String message;
  @override
  Widget build(BuildContext context) {
    final motion =
        animate &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context);
    return Semantics(
      liveRegion: true,
      child: Row(
        children: [
          ExcludeSemantics(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: motion ? 0 : 1, end: 1),
              duration: Duration(milliseconds: motion ? 600 : 0),
              builder: (context, value, child) => Transform.translate(
                offset: Offset(
                  0,
                  motion ? -8 * math.sin(value * math.pi * 2) : 0,
                ),
                child: child,
              ),
              child: const FriendlyMonster(size: 42, resting: true),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

class TaskAdventureView extends ConsumerWidget {
  const TaskAdventureView({
    required this.childId,
    this.compact = false,
    super.key,
  });
  final String childId;
  final bool compact;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksProvider(childId)),
        date = ref.watch(familyTodayProvider(childId));
    final pending =
        ref.watch(taskSyncStateProvider).valueOrNull?.pendingTaskIds ??
        const <String>{};
    if (tasks.hasError ||
        date.hasError ||
        tasks.valueOrNull == null ||
        date.valueOrNull == null) {
      return const SizedBox.shrink();
    }
    final progress = TaskAdventure.fromTasks(
      tasks.valueOrNull!,
      childId: childId,
      familyDate: date.valueOrNull!,
      pendingTaskIds: pending,
    );
    if (compact) {
      return Text(
        progress.total == 0
            ? '小怪兽在休息'
            : '怪兽能量 ${progress.remaining} 格${progress.pending > 0 ? ' · 有完成记录待确认' : ''}',
        style: Theme.of(context).textTheme.bodyMedium,
      );
    }
    return TaskAdventureCard(
      key: ValueKey('$childId:${date.valueOrNull}'),
      progress: progress,
    );
  }
}

class TaskAdventureCard extends ConsumerWidget {
  const TaskAdventureCard({required this.progress, super.key});
  final TaskAdventure progress;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferences = ref.watch(feedbackPreferencesProvider).value;
    final motion = taskMotionEnabled(context, preferences);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ExcludeSemantics(
                  child: FriendlyMonster(
                    size: 58,
                    resting: progress.remaining == 0,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    progress.total == 0
                        ? '小怪兽在休息'
                        : '怪兽能量 ${progress.remaining} 格',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (progress.total > 0) ...[
              TweenAnimationBuilder<double>(
                tween: Tween(begin: progress.energy, end: progress.energy),
                duration: Duration(milliseconds: motion ? 450 : 0),
                builder: (context, energy, _) => LinearProgressIndicator(
                  value: energy,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(8),
                  semanticsLabel: '怪兽剩余能量',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '今日任务已完成 ${progress.completed} 项${progress.pending == 0 ? '' : '，其中 ${progress.pending} 项待同步确认'}',
              ),
            ],
            Text(
              progress.total == 0
                  ? '有任务时再一起出发。'
                  : progress.remaining == 0
                  ? '这一轮完成啦，休息一下吧！'
                  : '完成任务让能量减少，按自己的节奏就好。',
            ),
          ],
        ),
      ),
    );
  }
}

/// Small code-native illustration; no assets, network or gameplay calculations.
class FriendlyMonster extends StatelessWidget {
  const FriendlyMonster({this.size = 58, required this.resting, super.key});
  final double size;
  final bool resting;
  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _MonsterPainter(Theme.of(context).colorScheme, resting),
  );
}

class _MonsterPainter extends CustomPainter {
  _MonsterPainter(this.colors, this.resting);
  final ColorScheme colors;
  final bool resting;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 64, size.height / 64);
    final body = Paint()..color = colors.primaryContainer;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(6, 12, 52, 46),
        const Radius.circular(20),
      ),
      body,
    );
    canvas.drawOval(const Rect.fromLTWH(9, 4, 14, 24), body);
    canvas.drawOval(const Rect.fromLTWH(41, 4, 14, 24), body);
    final ink = Paint()
      ..color = colors.onPrimaryContainer
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (final x in [23.0, 41.0]) {
      if (resting) {
        canvas.drawLine(Offset(x - 4, 32), Offset(x + 4, 32), ink);
      } else {
        canvas.drawCircle(Offset(x, 32), 3, ink);
      }
    }
    ink.style = PaintingStyle.stroke;
    canvas.drawArc(const Rect.fromLTWH(25, 36, 14, 10), 0, math.pi, false, ink);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MonsterPainter oldDelegate) =>
      oldDelegate.colors != colors || oldDelegate.resting != resting;
}
