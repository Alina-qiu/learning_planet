import 'package:flutter/material.dart';
import '../domain/business_metrics.dart';
import '../domain/learning_report.dart';

class BusinessMetricsDetails extends StatelessWidget {
  const BusinessMetricsDetails({required this.metrics, super.key});
  final BusinessMetrics metrics;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('申请到履约中位时长：${fulfillmentDuration(metrics.medianSeconds)}'),
      Text(
        '本期已履约 ${metrics.fulfilled} 笔；本期申请中目前仍待履约 ${metrics.openRequests} 笔。',
      ),
      const Text('时长按本期实际履约记录统计，包含此前申请；待履约、拒绝和取消不作为零时长样本。'),
      const SizedBox(height: 16),
      Text(
        '金币产消比：${metrics.coinRatio == null ? '暂无履约消耗' : '${metrics.coinRatio!.toStringAsFixed(2)} : 1'}',
      ),
      const Text('金币收入 ÷ 已履约消耗；冻结与退款不计入，人工等其他扣减另列。'),
      const SizedBox(height: 16),
      Text('OCR 校正率：${reportPercent(metrics.correctionRate)}'),
      Text('首次确认时修改 ${metrics.correctedFields} / ${metrics.ocrFields} 个识别字段。'),
      const Text('按本期首次确认时间统计。目前识别字段为题干全文；仅去除首尾普通空格，后续题目编辑不改变校正结果。'),
      Text('手工录入 ${metrics.manualRecords} 条，不计入识别字段。'),
      if (metrics.unmeasuredRecords > 0)
        Text('另有 ${metrics.unmeasuredRecords} 条已保存记录缺少首次确认统计，未计入校正率。'),
      const SizedBox(height: 8),
      const Text('这些指标用于一起调整安排，不用于给孩子排名或扣除奖励。'),
    ],
  );
}
