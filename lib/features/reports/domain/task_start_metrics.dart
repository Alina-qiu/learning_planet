class TaskStartMetrics {
  TaskStartMetrics.fromJson(Map<String, dynamic> row)
    : eligible = _count(row['eligible']),
      autonomous = _count(row['autonomous']),
      parentAssisted = _count(row['parent_assisted']),
      outsideWindow = _count(row['outside_window']),
      unknown = _count(row['unknown']),
      notStarted = _count(row['not_started']),
      futureWindows = _count(row['future_windows']),
      invalidWindows = _count(row['invalid_windows']),
      rate = _rate(row['rate']) {
    final measurable = eligible > 0 && unknown == 0 && invalidWindows == 0;
    if (row['version'] != 'start-v1' ||
        eligible !=
            autonomous +
                parentAssisted +
                outsideWindow +
                unknown +
                notStarted ||
        measurable != (rate != null) ||
        (rate != null && (rate! - autonomous / eligible).abs() > 0.000051)) {
      throw const FormatException('自主开始统计不一致');
    }
  }
  final int eligible, autonomous, parentAssisted, outsideWindow, unknown;
  final int notStarted, futureWindows, invalidWindows;
  final double? rate;

  static int _count(Object? value) {
    if (value is! num ||
        !value.isFinite ||
        value < 0 ||
        value != value.round()) {
      throw const FormatException('自主开始数量无效');
    }
    return value.toInt();
  }

  static double? _rate(Object? value) {
    if (value == null) return null;
    if (value is! num || !value.isFinite || value < 0 || value > 1) {
      throw const FormatException('自主开始率无效');
    }
    return value.toDouble();
  }
}
