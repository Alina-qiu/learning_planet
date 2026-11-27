/// Aggregate-only report fields. No original question, OCR text or reward title.
class BusinessMetrics {
  BusinessMetrics.fromJson(Map<String, dynamic> row)
    : fulfilled = _count(row['fulfillment']['samples']),
      medianSeconds = _number(row['fulfillment']['median_seconds']),
      openRequests = _count(row['fulfillment']['open_requests']),
      ocrFields = _count(row['ocr']['ocr_fields']),
      correctedFields = _count(row['ocr']['corrected_fields']),
      correctionRate = _number(row['ocr']['correction_rate']),
      manualRecords = _count(row['ocr']['manual_records']),
      unmeasuredRecords = _count(row['ocr']['unmeasured_saved_records']),
      coinRatio = _number(row['coin_income_to_spent']) {
    if (row['version'] != 'business-v1' ||
        correctedFields > ocrFields ||
        (fulfilled == 0) != (medianSeconds == null) ||
        (ocrFields == 0) != (correctionRate == null) ||
        (correctionRate != null &&
            (correctionRate! - correctedFields / ocrFields).abs() > 0.000051)) {
      throw const FormatException('报告统计格式无效');
    }
  }
  final int fulfilled, openRequests, ocrFields, correctedFields;
  final int manualRecords, unmeasuredRecords;
  final double? medianSeconds, correctionRate, coinRatio;

  static int _count(Object? value) {
    if (value is! num ||
        !value.isFinite ||
        value < 0 ||
        value != value.round()) {
      throw const FormatException('报告数量无效');
    }
    return value.toInt();
  }

  static double? _number(Object? value) {
    if (value == null) return null;
    if (value is! num || !value.isFinite || value < 0) {
      throw const FormatException('报告指标无效');
    }
    return value.toDouble();
  }
}

String fulfillmentDuration(double? seconds) {
  if (seconds == null) return '暂无已履约样本';
  final total = seconds.round();
  if (total < 60) return '$total 秒';
  if (total < 3600) return '${total ~/ 60} 分 ${total % 60} 秒';
  if (total < 86400) return '${total ~/ 3600} 小时 ${(total % 3600) ~/ 60} 分';
  return '${total ~/ 86400} 天 ${(total % 86400) ~/ 3600} 小时';
}
