const rewardQuotaPeriods = {
  'none': '不限次数',
  'day': '每天',
  'week': '每周（周一至周日）',
  'month': '每月',
  'lifetime': '累计',
};

String rewardQuotaDescription(Map<String, dynamic> reward) {
  final period = reward['quota_period'] as String? ?? 'none';
  if (period == 'none') return '每个孩子不限次数';
  return '每个孩子${rewardQuotaPeriods[period] ?? period}最多 ${reward['quota_limit']} 次';
}

String rewardCapacityDescription(Map<String, dynamic> reward) {
  final stock = reward['stock_total'] == null
      ? '家庭共享库存不限'
      : '可申请 ${reward['stock_available']} 份 · 总量 ${reward['stock_total']} 份\n已预留 ${reward['stock_reserved']} 份 · 已兑现 ${reward['stock_fulfilled']} 份';
  final remaining = reward['quota_remaining'];
  final reset = reward['quota_resets_on'];
  return '$stock\n${rewardQuotaDescription(reward)}'
      '${remaining == null ? '' : '，当前剩余 $remaining 次'}'
      '${reset == null ? '' : '\n下次额度更新 $reset（${reward['family_timezone']}）'}';
}
