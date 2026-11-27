/// A child's self-assessment before grading; unrelated to OCR/model confidence.
enum ReviewConfidence {
  unsure(1, '不太确定'),
  somewhat(2, '有点把握'),
  confident(3, '很有把握');

  const ReviewConfidence(this.wire, this.label);
  final int wire;
  final String label;

  static ReviewConfidence? fromWire(Object? value) => value is int
      ? values.where((level) => level.wire == value).firstOrNull
      : null;
}
