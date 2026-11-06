import Flutter
import Foundation
import MetricKit

// Uses the MetricKit subscriber API available on the app's iOS 15.5 baseline.
// Never asks MetricKit for JSON, call stacks, exception metadata or app logs.
final class NativeDiagnostics: NSObject, MXMetricManagerSubscriber {
  private typealias Journal = NativeDiagnosticJournal.State
  private let worker = DispatchQueue(label: "learning_planet.native_diagnostics")

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
        let original = try self.restore()
        guard original.scope != nil else { return }
        let state = try NativeDiagnosticJournal.recording(
          original, counts: counts, now: Date().timeIntervalSince1970)
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
        guard args["scope"] is NSNull || (scope != nil && NativeDiagnosticJournal.validUUID(scope!)) else { throw Failure.invalid }
        var state = try self.restore()
        let response: Any?
        if call.method == "read" {
          guard Set(args.keys) == ["scope"] else { throw Failure.invalid }
          state = NativeDiagnosticJournal.bind(state, scope: scope, now: Date().timeIntervalSince1970)
          try self.save(state)
          response = state.pending.prefix(50).map { $0.wire }
        } else {
          guard Set(args.keys) == ["scope", "ids"], let scope = scope,
                let ids = args["ids"] as? [String], ids.count <= 50,
                ids.allSatisfy(NativeDiagnosticJournal.validUUID) else { throw Failure.invalid }
          if scope == state.scope {
            state = NativeDiagnosticJournal.acknowledging(state, scope: scope, ids: ids)
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
    return NativeDiagnosticJournal.decode(data)
  }
  private func save(_ state: Journal) throws {
    var url = try file()
    try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtection])
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }
}
