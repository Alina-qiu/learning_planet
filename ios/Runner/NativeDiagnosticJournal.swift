import CryptoKit
import Foundation

// The same journal policy is used by the MetricKit adapter and native checks.
// Inputs are period boundaries and counts only, never diagnostic payload text.
enum NativeDiagnosticJournal {
  struct Event: Codable {
    let id: String
    let day: String
    let operation: String
    var wire: [String: String] { ["event_id": id, "day": day, "operation": operation] }
  }
  struct State: Codable {
    var scope: String?
    var since: Double = 0
    var observed: Double = 0
    var pending: [Event] = []
    var seen: [String: String] = [:]
  }
  private static let operations: Set<String> = ["iosCrash", "iosHang"]
  private enum Failure: Error { case invalid }
  typealias Counts = (Double, Double, Int, Int)

  static func recording(_ original: State, counts: [Counts], now: Double) throws -> State {
    var state = original
    guard let scope = state.scope else { return state }
    state = Self.bind(state, scope: scope, now: now)
    for (begin, end, crashes, hangs) in counts {
      // A period crossing logout/account change cannot be attributed safely.
      guard begin >= state.since, end >= begin, end <= now,
            Self.day(end) >= Self.oldest(now) else { continue }
      let day = Self.day(end)
      for (operation, count) in [("iosCrash", crashes), ("iosHang", hangs)] {
        for index in 0..<count {
          let id = Self.identifier("\(scope):\(state.since):\(begin):\(end):\(operation):\(index)")
          guard state.seen[id] == nil else { continue }
          state.pending.append(Event(id: id, day: day, operation: operation))
          state.seen[id] = day
        }
      }
    }
    state.pending = Array(state.pending.suffix(250))
    if state.seen.count > 1000 {
      let kept = state.seen.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }.suffix(1000)
      state.seen = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
      // Always retain replay markers for entries still waiting for Dart.
      for event in state.pending { state.seen[event.id] = event.day }
      if state.seen.count > 1250 { throw Failure.invalid }
    }
    return state
  }

  static func acknowledging(_ original: State, scope: String, ids: [String]) -> State {
    var state = original
    if scope == state.scope {
      let removed = Set(ids)
      state.pending.removeAll { removed.contains($0.id) }
    }
    return state
  }

  static func validUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
  static func day(_ seconds: Double) -> String {
    let format = ISO8601DateFormatter()
    format.timeZone = TimeZone(secondsFromGMT: 0)
    format.formatOptions = [.withFullDate]
    return format.string(from: Date(timeIntervalSince1970: seconds))
  }
  static func oldest(_ now: Double) -> String { day(now - 7 * 86400) }
  static func identifier(_ input: String) -> String {
    var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }
    return [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]].map { $0.joined() }.joined(separator: "-")
  }
  static func bind(_ state: State, scope: String?, now: Double) -> State {
    guard scope != nil, scope == state.scope, state.since > 0, now >= state.observed else {
      return State(scope: scope, since: now, observed: now)
    }
    var next = state
    next.observed = now
    let first = oldest(now), last = day(now)
    next.pending = Array(state.pending.filter { $0.day >= first && $0.day <= last }.suffix(250))
    next.seen = state.seen.filter { $0.value >= first && $0.value <= last }
    return next
  }
  static func decode(_ data: Data) -> State {
    let format = ISO8601DateFormatter()
    format.timeZone = TimeZone(secondsFromGMT: 0)
    format.formatOptions = [.withFullDate]
    func validDay(_ value: String) -> Bool {
      guard let date = format.date(from: value) else { return false }
      return format.string(from: date) == value
    }
    // Unreadable/locked files throw and are retained; malformed data resets to
    // an unbound baseline so no old identity or malformed content is imported.
    guard data.count <= 262144, let state = try? JSONDecoder().decode(State.self, from: data),
          state.since > 0, state.observed >= state.since,
          state.scope == nil || validUUID(state.scope!),
          state.pending.count <= 250, state.seen.count <= 1250,
          Set(state.pending.map { $0.id }).count == state.pending.count,
          state.pending.allSatisfy({ validUUID($0.id) && operations.contains($0.operation) && state.seen[$0.id] == $0.day }),
          state.seen.allSatisfy({ validUUID($0.key) && validDay($0.value) }) else { return State() }
    return state
  }
}
