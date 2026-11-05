import CryptoKit
import Flutter
import Foundation
import MetricKit

// Uses the MetricKit subscriber API available on the app's iOS 15.5 baseline.
// Never asks MetricKit for JSON, call stacks, exception metadata or app logs.
final class NativeDiagnostics: NSObject, MXMetricManagerSubscriber {
  private struct Event: Codable {
    let id: String
    let day: String
    let operation: String
    var wire: [String: String] { ["event_id": id, "day": day, "operation": operation] }
  }
  private struct Journal: Codable {
    var scope: String?
    var since: Double = 0
    var observed: Double = 0
    var pending: [Event] = []
    var seen: [String: String] = [:]
  }
  private let worker = DispatchQueue(label: "learning_planet.native_diagnostics")
  private static let operations: Set<String> = ["iosCrash", "iosHang"]

  func start() { MXMetricManager.shared.add(self) }
  deinit { MXMetricManager.shared.remove(self) }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    // Extract only period boundaries and counts, then release the OS payloads.
    let counts = payloads.prefix(50).map {
      ($0.timeStampBegin.timeIntervalSince1970, $0.timeStampEnd.timeIntervalSince1970,
       min($0.crashDiagnostics?.count ?? 0, 250), min($0.hangDiagnostics?.count ?? 0, 250))
    }
    worker.async {
      do {
        var state = try self.restore()
        guard let scope = state.scope else { return }
        let now = Date().timeIntervalSince1970
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
        try self.save(state)
      } catch { /* Diagnostics must never create a crash or log payload content. */ }
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "read" || call.method == "ack" else { result(FlutterMethodNotImplemented); return }
    worker.async {
      do {
        guard let args = call.arguments as? [String: Any] else { throw Failure.invalid }
        let scope = args["scope"] as? String
        guard args["scope"] is NSNull || (scope != nil && Self.validUUID(scope!)) else { throw Failure.invalid }
        var state = try self.restore()
        let response: Any?
        if call.method == "read" {
          guard Set(args.keys) == ["scope"] else { throw Failure.invalid }
          state = Self.bind(state, scope: scope, now: Date().timeIntervalSince1970)
          try self.save(state)
          response = state.pending.prefix(50).map { $0.wire }
        } else {
          guard Set(args.keys) == ["scope", "ids"], let scope = scope,
                let ids = args["ids"] as? [String], ids.count <= 50,
                ids.allSatisfy(Self.validUUID) else { throw Failure.invalid }
          if scope == state.scope {
            let removed = Set(ids)
            state.pending.removeAll { removed.contains($0.id) }
            try self.save(state)
          }
          response = nil
        }
        DispatchQueue.main.async { result(response) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "native_diagnostics_unavailable", message: "运行诊断暂不可用", details: nil)) }
      }
    }
  }

  private enum Failure: Error { case invalid }
  private static func validUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
  private static func day(_ seconds: Double) -> String {
    let format = ISO8601DateFormatter()
    format.timeZone = TimeZone(secondsFromGMT: 0)
    format.formatOptions = [.withFullDate]
    return format.string(from: Date(timeIntervalSince1970: seconds))
  }
  private static func oldest(_ now: Double) -> String { day(now - 7 * 86400) }
  private static func identifier(_ input: String) -> String {
    var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }
    return [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]].map { $0.joined() }.joined(separator: "-")
  }
  private static func bind(_ state: Journal, scope: String?, now: Double) -> Journal {
    guard scope != nil, scope == state.scope, state.since > 0, now >= state.observed else {
      return Journal(scope: scope, since: now, observed: now)
    }
    var next = state
    next.observed = now
    let first = oldest(now), last = day(now)
    next.pending = Array(state.pending.filter { $0.day >= first && $0.day <= last }.suffix(250))
    next.seen = state.seen.filter { $0.value >= first && $0.value <= last }
    return next
  }
  private func file() throws -> URL {
    let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return directory.appendingPathComponent("native-diagnostics-v1.json", isDirectory: false)
  }
  private func restore() throws -> Journal {
    let url = try file()
    if !FileManager.default.fileExists(atPath: url.path) { return Journal() }
    let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
          let size = attributes.fileSize, size <= 262144 else { throw Failure.invalid }
    let data = try Data(contentsOf: url)
    let format = ISO8601DateFormatter()
    format.timeZone = TimeZone(secondsFromGMT: 0)
    format.formatOptions = [.withFullDate]
    func validDay(_ value: String) -> Bool {
      guard let date = format.date(from: value) else { return false }
      return format.string(from: date) == value
    }
    // Unreadable/locked files throw and are retained; malformed data resets to
    // an unbound baseline so no old identity or malformed content is imported.
    guard data.count <= 262144, let state = try? JSONDecoder().decode(Journal.self, from: data),
          state.since > 0, state.observed >= state.since,
          state.scope == nil || Self.validUUID(state.scope!),
          state.pending.count <= 250, state.seen.count <= 1250,
          Set(state.pending.map { $0.id }).count == state.pending.count,
          state.pending.allSatisfy({ Self.validUUID($0.id) && Self.operations.contains($0.operation) && state.seen[$0.id] == $0.day }),
          state.seen.allSatisfy({ Self.validUUID($0.key) && validDay($0.value) }) else { return Journal() }
    return state
  }
  private func save(_ state: Journal) throws {
    var url = try file()
    try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtection])
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }
}
