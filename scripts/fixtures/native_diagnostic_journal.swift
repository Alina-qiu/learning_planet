import Foundation

@main struct NativeDiagnosticJournalChecks {
  typealias Journal = NativeDiagnosticJournal
  static let scope = "10000000-0000-4000-8000-000000000001"
  static let other = "10000000-0000-4000-8000-000000000002"
  static let now: Double = 1_793_937_600 // 2026-11-06T04:00:00Z

  static func main() throws {
    // A fresh process reads exactly the bytes produced before process exit.
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "restore" {
      let restored = Journal.decode(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
      precondition(restored.scope == scope && restored.pending.count == 3)
      let replay = try Journal.recording(restored, counts: [(now, now + 10, 2, 1)], now: now + 30)
      precondition(replay.pending.map(\.id) == restored.pending.map(\.id))
      let ack = Journal.acknowledging(replay, scope: scope, ids: replay.pending.map(\.id))
      let final = try Journal.recording(ack, counts: [(now, now + 10, 2, 1)], now: now + 31)
      precondition(final.pending.isEmpty)
      return
    }
    var count = 0
    func check(_ value: Bool, _ label: String) {
      precondition(value, label); count += 1
    }
    func restored(_ state: Journal.State) throws -> Journal.State {
      Journal.decode(try JSONEncoder().encode(state))
    }
    func rejected(_ state: Journal.State, _ label: String) throws {
      let value = try restored(state)
      check(value.scope == nil && value.pending.isEmpty && value.seen.isEmpty, label)
    }
    let empty = Journal.State()
    check(try Journal.recording(empty, counts: [(now, now + 10, 2, 1)], now: now + 20).pending.isEmpty, "unbound does not collect")
    let bound = Journal.bind(empty, scope: scope, now: now)
    let first = try Journal.recording(bound, counts: [(now, now + 10, 2, 1)], now: now + 20)
    let ids = first.pending.map(\.id)
    check(first.pending.map(\.operation) == ["iosCrash", "iosCrash", "iosHang"], "only projected categories")
    check(Set(ids).count == 3 && ids.allSatisfy(Journal.validUUID), "stable distinct event UUIDs")
    check(first.pending.allSatisfy { Set($0.wire.keys) == ["event_id", "day", "operation"] && $0.day == "2026-11-06" }, "fixed wire schema and UTC day")
    check(try restored(first).pending.map(\.id) == ids, "journal codec preserves identity")
    let replay = try Journal.recording(first, counts: [(now, now + 10, 2, 1)], now: now + 30)
    check(replay.pending.map(\.id) == ids, "duplicate OS delivery does not append")
    let ack = Journal.acknowledging(first, scope: scope, ids: [ids[0]])
    check(ack.pending.map(\.id) == Array(ids.dropFirst()) && ack.seen[ids[0]] != nil, "acknowledgement keeps replay marker")
    check(try Journal.recording(ack, counts: [(now, now + 10, 2, 1)], now: now + 30).pending.map(\.id) == ack.pending.map(\.id), "acknowledged entries stay acknowledged")
    check(Journal.acknowledging(first, scope: other, ids: ids).pending.map(\.id) == ids, "late old-account acknowledgement ignored")
    let changed = Journal.bind(first, scope: other, now: now + 30)
    check(changed.pending.isEmpty && changed.seen.isEmpty && changed.since == now + 30, "account switch clears previous journal")
    check(try Journal.recording(changed, counts: [(now, now + 35, 1, 1)], now: now + 40).pending.isEmpty, "period spanning account switch excluded")
    let loggedOut = Journal.bind(first, scope: nil, now: now + 30)
    let rebound = Journal.bind(loggedOut, scope: scope, now: now + 40)
    check(try Journal.recording(rebound, counts: [(now, now + 45, 1, 1)], now: now + 50).pending.isEmpty, "logout and same-account login establish new boundary")
    let backwards = Journal.bind(first, scope: scope, now: now - 10)
    check(backwards.pending.isEmpty && backwards.seen.isEmpty && backwards.since == now - 10, "clock rollback resets attribution")
    check(try Journal.recording(bound, counts: [(now, now + 100, 1, 1), (now + 10, now, 1, 1)], now: now + 20).pending.isEmpty, "future and reversed periods rejected")
    check(Journal.bind(first, scope: scope, now: now + 7 * 86400).pending.count == 3, "inclusive UTC retention boundary")
    check(Journal.bind(first, scope: scope, now: now + 8 * 86400).pending.isEmpty, "expired diagnostics removed")
    check(try Journal.recording(bound, counts: [(now, now + 10, 2, 1)], now: now + 8 * 86400).pending.isEmpty, "expired OS delivery excluded")
    let bounded = try Journal.recording(bound, counts: (0..<6).map { (now + Double($0), now + 10 + Double($0), 250, 250) }, now: now + 30)
    check(bounded.pending.count == 250 && bounded.seen.count <= 1250, "pending and replay memory bounded")
    check(bounded.pending.allSatisfy { bounded.seen[$0.id] == $0.day }, "eviction preserves every pending replay marker")
    check(try restored(bounded).pending.map(\.id) == bounded.pending.map(\.id), "full bounded journal remains readable")
    check(try Journal.recording(bounded, counts: [(now + 5, now + 15, 0, 250)], now: now + 31).pending.map(\.id) == bounded.pending.map(\.id), "retained pending replay markers survive capacity eviction")

    var invalid = first; invalid.scope = "private-account-id"
    try rejected(invalid, "malformed scope discarded")
    invalid = first; invalid.pending.append(first.pending[0])
    try rejected(invalid, "duplicate event discarded")
    invalid = first; invalid.seen.removeValue(forKey: ids[0])
    try rejected(invalid, "missing replay marker discarded")
    invalid = first; invalid.seen[ids[0]] = "2026-02-30"
    try rejected(invalid, "invalid calendar day discarded")
    invalid = first; invalid.pending[0] = Journal.Event(id: ids[0], day: first.pending[0].day, operation: "private-stack-text")
    try rejected(invalid, "unrecognized category discarded")
    invalid = first; invalid.observed = now - 1
    try rejected(invalid, "invalid observation interval discarded")
    check(Journal.decode(Data("{broken".utf8)).scope == nil, "malformed JSON resets unbound")
    check(Journal.decode(Data(repeating: 32, count: 262145)).pending.isEmpty, "oversized input rejected")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lp-native-journal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("journal.json")
    try JSONEncoder().encode(first).write(to: file, options: .atomic)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["restore", file.path]
    try process.run(); process.waitUntilExit()
    check(process.terminationReason == .exit && process.terminationStatus == 0, "fresh process restores identity and acknowledges replay")
    print("All \(count) native diagnostic journal checks passed.")
  }
}
