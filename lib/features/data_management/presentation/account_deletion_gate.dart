import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/presentation/app_sign_out.dart';
import '../../auth_family/application/family_providers.dart';
import '../../auth_family/presentation/family_gate.dart';
import '../../auth_family/presentation/entry_recovery_screen.dart';
import '../../tasks/data/notification_scheduler.dart';
import '../data/account_deletion_repository.dart';
import 'account_deletion_screen.dart';

class AccountDeletionGate extends ConsumerStatefulWidget {
  const AccountDeletionGate({super.key});
  @override
  ConsumerState<AccountDeletionGate> createState() =>
      _AccountDeletionGateState();
}

class _AccountDeletionGateState extends ConsumerState<AccountDeletionGate>
    with WidgetsBindingObserver {
  Timer? _timer;
  Timer? _parentExpiry;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(parentAuthorizedUntilProvider, (_, until) {
      _scheduleParentExpiry(until);
    }, fireImmediately: true);
    if (ref.read(accountDeletionRepositoryProvider) != null) {
      _timer = Timer.periodic(const Duration(seconds: 30), (_) {
        // A cold offline check can take longer than a polling interval.
        if (!ref.read(accountDeletionStatusProvider).isLoading) {
          ref.invalidate(accountDeletionStatusProvider);
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _parentExpiry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _scheduleParentExpiry(DateTime? until) {
    _parentExpiry?.cancel();
    if (until == null) return;
    final remaining = until.difference(
      ref.read(parentAuthorizationNowProvider)(),
    );
    if (remaining <= Duration.zero) return;
    _parentExpiry = Timer(remaining, () {
      ref.invalidate(activeParentFamilyProvider);
      // A platform timer may wake slightly before the continuous-clock deadline.
      _scheduleParentExpiry(until);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(authorizationClockProvider);
      ref.invalidate(activeParentFamilyProvider);
      _scheduleParentExpiry(ref.read(parentAuthorizedUntilProvider));
      ref.invalidate(accountDeletionStatusProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(accountDeletionStatusProvider, (previous, next) {
      if (next.valueOrNull == null || previous?.valueOrNull != null) return;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      ref.read(notificationSchedulerProvider).setScope(null).catchError((
        Object _,
      ) {
        if (mounted) {
          ref.read(notificationErrorProvider.notifier).state = '清除旧提醒失败，请重试。';
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      });
    });
    return ref
        .watch(accountDeletionStatusProvider)
        .when(
          data: (status) => status == null
              ? const FamilyGate()
              : AccountDeletionScreen(initialStatus: status),
          loading: () => const Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 24),
                  AppSignOutButton(),
                ],
              ),
            ),
          ),
          error: (error, _) => EntryRecoveryScreen(
            check: EntryCheck.account,
            error: error,
            retrying: ref.watch(accountDeletionStatusProvider).isLoading,
            onRetry: () => ref.invalidate(accountDeletionStatusProvider),
          ),
        );
  }
}
