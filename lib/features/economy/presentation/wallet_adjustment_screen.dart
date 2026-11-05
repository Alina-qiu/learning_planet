import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/offline/network_failure.dart';
import '../../auth_family/application/family_providers.dart';
import '../data/economy_repository.dart';
import '../domain/wallet_adjustment_details.dart';
import 'economy_text.dart';

typedef AdjustmentScope = ({String child, String family, String entryId});
final walletAdjustmentProvider = FutureProvider.autoDispose
    .family<WalletAdjustmentDetails, AdjustmentScope>((ref, scope) {
      final repository = ref.watch(economyRepositoryProvider);
      ref.watch(parentAuthorizationRevisionProvider);
      if (ref.watch(activeParentFamilyProvider) != scope.family ||
          repository is! AuditedEconomyRepository) {
        throw StateError('请返回首页重新验证家长PIN');
      }
      return repository.adjustmentDetails(
        scope.child,
        scope.family,
        scope.entryId,
      );
    });

class WalletAdjustmentScreen extends ConsumerWidget {
  const WalletAdjustmentScreen({required this.scope, super.key});
  final AdjustmentScope scope;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authorized = ref.watch(activeParentFamilyProvider) == scope.family;
    return Scaffold(
      appBar: AppBar(title: const Text('调账明细')),
      body: SafeArea(
        child: !authorized
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('家长授权已结束，请返回首页重新验证PIN。'),
                ),
              )
            : ref
                  .watch(walletAdjustmentProvider(scope))
                  .when(
                    skipLoadingOnRefresh: false,
                    skipLoadingOnReload: false,
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, _) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              isNetworkFailure(error)
                                  ? '调账明细需联网读取。请连接网络后重试。'
                                  : '暂时无法读取明细。请刷新或返回首页重新验证家长PIN。',
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: () => ref.invalidate(
                                walletAdjustmentProvider(scope),
                              ),
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    data: (details) {
                      final time = EconomyTime(details.timezone),
                          audit = details.audit;
                      final actor = audit?['actor'] as Map?;
                      final actorLabel =
                          actor == null || actor['status'] == 'unavailable'
                          ? '未记录账号'
                          : '${actor['is_self'] == true ? '我 · ' : ''}${actor['email'] ?? '家庭成员'}${actor['status'] == 'former_member' ? '（已离开家庭）' : ''}';
                      return ListView(
                        padding: const EdgeInsets.all(24),
                        children: [
                          Text(
                            ledgerChangeLabel(details.entry),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '入账时间：${time.format(details.entry['created_at'])}',
                          ),
                          Text(time.label),
                          const SizedBox(height: 24),
                          if (audit == null)
                            const Text('这笔历史调账的操作说明已不可用。账本金额仍保留；不推测操作者或原因。')
                          else ...[
                            Text(
                              '同次调账：金币 ${signedAmount(audit['coins'] as int)} · XP ${signedAmount(audit['xp'] as int)}',
                            ),
                            const SizedBox(height: 16),
                            Text('操作人：$actorLabel'),
                            const SizedBox(height: 16),
                            Text('操作时间：${time.format(audit['created_at'])}'),
                            const SizedBox(height: 16),
                            const Text('调账原因'),
                            const SizedBox(height: 8),
                            SelectableText(audit['reason'] as String),
                          ],
                          const SizedBox(height: 24),
                          const Text('明细仅供核对。历史账本不能修改；如需纠正，请由家长另记一笔调账并填写原因。'),
                        ],
                      );
                    },
                  ),
      ),
    );
  }
}
