/// Presentation of the server's versioned reward contract. Never changes a
/// wallet or derives a locally payable amount from pending answers.
bool usesReviewMilestones(Map<String, dynamic> task) =>
    task['review_reward_policy'] == 2;

String reviewRewardRules(Map<String, dynamic> task) =>
    usesReviewMilestones(task)
    ? '订正正确：15金币 / 15XP；7天复测正确：25金币 / 20XP；30天掌握：40金币 / 30XP。1、3天练习和答错不另发阶段奖励。同一题目未修改时，每个阶段只奖励一次，${task['review_auto_complete'] == true ? '全部作答后自动完成并结算' : '全部作答并完成后统一结算'}。'
    : '金币每答对一题5个；XP每作答一题3点，答对另加2点。需全部提交后统一结算，重复提交不重复发奖。';

String reviewItemReward(Map<String, dynamic> item) {
  final stage = switch (item['review_step_snapshot']) {
    0 => '订正',
    1 => '1天练习',
    2 => '3天练习',
    3 => '7天复测',
    4 => '30天掌握',
    _ => '阶段待确认',
  };
  final status = item['reward_status'];
  if (item['pending_answer'] != null && item['result'] == null) {
    return '$stage · 作答与阶段奖励待服务端确认';
  }
  return switch (status) {
    'awarded' =>
      '$stage · 本次阶段奖励 ${item['reward_coins']} 金币 / ${item['reward_xp']} XP',
    'eligible' => '$stage · 已答对，完成本任务后结算；同周期只奖励一次',
    'already_rewarded' => '$stage · 本周期已奖励，不重复发奖',
    'stale' => '题目内容或复习排期已更新；本次保留作答，不推进阶段或新增阶段奖励',
    'wrong' => '$stage · 本次未答对，不发阶段奖励',
    'practice' => '$stage · 已记录练习进度，不另发阶段奖励',
    _ =>
      '$stage · ${item['review_step_snapshot'] == 1 || item['review_step_snapshot'] == 2 ? '练习不另发阶段奖励' : '阶段奖励以服务端结算为准'}',
  };
}
