enum ConfigurationKind { task, rules }

/// Monotonic, foreground-only editing time, including reading and cancelled edits.
/// No text, key codes, field names or control values enter the measurement.
class ConfigurationSession {
  ConfigurationSession({
    required DateTime startedAt,
    required this.elapsed,
    required this.onInterval,
    this.idleLimit = const Duration(minutes: 2),
  }) : _startedAt = startedAt.toUtc(),
       _origin = elapsed() {
    _cursor = _origin;
    _activeUntil = _origin + idleLimit;
  }
  final DateTime _startedAt;
  final Duration _origin, idleLimit;
  final Duration Function() elapsed;
  final void Function(DateTime start, DateTime end) onInterval;
  late Duration _cursor, _activeUntil;
  bool _enabled = true, _foreground = true, _closed = false;

  void sample() {
    if (_closed) return;
    final now = elapsed();
    final end = now < _activeUntil ? now : _activeUntil;
    if (_enabled && _foreground) {
      var start = _cursor;
      while (end - start >= const Duration(milliseconds: 1)) {
        final next = end - start > const Duration(seconds: 30)
            ? start + const Duration(seconds: 30)
            : end;
        onInterval(
          _startedAt.add(start - _origin),
          _startedAt.add(next - _origin),
        );
        start = next;
      }
    }
    _cursor = now;
  }

  void activity() {
    // Input renews the idle deadline without creating one event per keystroke.
    if (!_closed && elapsed() > _activeUntil) sample();
    if (!_closed && _enabled && _foreground) {
      _activeUntil = elapsed() + idleLimit;
    }
  }

  void setEnabled(bool value) {
    if (_enabled == value || _closed) return;
    sample();
    _enabled = value;
    if (value) activity();
  }

  void setForeground(bool value) {
    if (_foreground == value || _closed) return;
    sample();
    _foreground = value;
    if (value) activity();
  }

  void close() {
    sample();
    _closed = true;
  }
}
