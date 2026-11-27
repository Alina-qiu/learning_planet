#if targetEnvironment(simulator) && LP_QUIET_SIMULATOR_TEST
import Flutter
import ObjectiveC
import UIKit
import UserNotifications
import XCTest
@testable import Runner

private enum Probe {
  static let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("ac09-receipt", isDirectory: true)
  static let run = UUID().uuidString.lowercased()
  static var source = ""
  static let scope = UUID().uuidString.lowercased()
  static let ids = ["quiet": UUID().uuidString.lowercased(), "scope": UUID().uuidString.lowercased(),
                    "expired": UUID().uuidString.lowercased(),
                    "allowed": UUID().uuidString.lowercased()]
  // 12:00 UTC. The device advances this synthetic server anchor using its own continuous clock.
  static let anchor: Int64 = 1_773_057_600_000

  static func write(_ name: String, _ evidence: [String: Any]) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: evidence.merging(["run": run, "source": source]) { _, new in new })
    try data.write(to: root.appendingPathComponent(name + ".json"), options: .atomic)
  }
}

@MainActor private final class FixtureBackgroundTask {
  var identifier = UIBackgroundTaskIdentifier.invalid
  func start() {
    identifier = UIApplication.shared.beginBackgroundTask(withName: "XCTest native receipt") { [weak self] in
      Task { @MainActor in self?.end() }
    }
  }
  func end() {
    if identifier != .invalid {
      UIApplication.shared.endBackgroundTask(identifier)
      identifier = .invalid
    }
  }
}

// Unrelated notifications leave a count. Per-case evidence contains only fixture values.
private func writeObservation(_ name: String, _ values: [String: Any]) {
  do { try Probe.write(name, values) }
  catch { XCTFail("Could not record " + name + ": " + String(describing: error)) }
}

private func observeTask(_ stage: ParentPush.ReceiptStage, _ payload: [AnyHashable: Any], _ state: Int) {
  guard let id = payload["message_id"] as? String,
    let name = Probe.ids.first(where: { $0.value == id })?.key else { return }
  switch stage {
  case .entered: writeObservation("entered-" + name, ["message": id, "state": state])
  case .claimed: writeObservation("claimed-" + name, ["message": id, "state": state, "handled": true])
  case .completed(let outcome):
    let parameters = ["scope_nonce", "issued_ms", "scheduled_ms", "expires_ms", "version",
                      "message_id", "timezone", "quiet_start", "quiet_end", "kind", "settings_version"]
    let data = Dictionary(uniqueKeysWithValues: parameters.compactMap { key in
      (payload[key] as? String).map { (key, $0) }
    })
    writeObservation(name, ["payload": data, "aps": payload["aps"] as? [String: Any] ?? [:],
      "state": state, "result": outcome.rawValue, "message": id])
  }
}

final class RunnerTests: XCTestCase {
  @MainActor
  func testBackgroundQuietReceipt() async throws {
    try await checkReceipts(source: "system")
  }

  @MainActor
  func testNativeDelegateReceipt() async throws {
    try await checkReceipts(source: "native")
  }

  @MainActor
  private func checkReceipts(source: String) async throws {
    Probe.source = source
    let center = UNUserNotificationCenter.current()
    let granted = try await center.requestAuthorization(options: [.alert, .sound, .provisional])
    XCTAssertTrue(granted)
    let settings = await center.notificationSettings()
    XCTAssertTrue([UNAuthorizationStatus.authorized, .provisional].contains(settings.authorizationStatus))

    let selector = NSSelectorFromString("application:didReceiveRemoteNotification:fetchCompletionHandler:")
    let original = try XCTUnwrap(class_getInstanceMethod(ParentPush.self, selector))
    let originalTypes = String(cString: try XCTUnwrap(method_getTypeEncoding(original)))
    let app = UIApplication.shared
    let appDelegate = try XCTUnwrap(app.delegate as? AppDelegate)
    let remoteSupported = appDelegate.responds(to: selector)
    XCTAssertTrue(remoteSupported)
    let fetch = NSSelectorFromString("application:performFetchWithCompletionHandler:")
    let lifecycle = SimulatorReceiptObserver.shared
    var counts: [String: Int] = [:]
    func count(_ name: String, state: Int) {
      counts[name, default: 0] += 1
      writeObservation(name, ["state": state, "count": counts[name]!])
    }
    // FlutterAppDelegate dynamically forwards these optional selectors. A routing
    // observation identifies the selector but has no access to its arguments.
    SimulatorReceiptObserver.forwarded = { name in
      if Thread.isMainThread { count(name, state: app.applicationState.rawValue) }
      else { DispatchQueue.main.async { count(name, state: -1) } }
    }
    lifecycle.payload = { application, payload in
      let state = application.applicationState.rawValue
      if let id = payload["message_id"] as? String,
        let name = Probe.ids.first(where: { $0.value == id })?.key {
        writeObservation("app-" + name, ["message": id, "state": state])
      } else { count("app-unmatched", state: state) }
    }
    ParentPush.observeTaskReceipt = observeTask
    defer {
      SimulatorReceiptObserver.forwarded = nil
      lifecycle.payload = nil
      lifecycle.registration = nil
      ParentPush.observeTaskReceipt = nil
    }
    if source == "system" {
      lifecycle.registration = { application, status in
        writeObservation("registration", ["callback": status, "registered": application.isRegisteredForRemoteNotifications])
      }
      if lifecycle.registrationStatus != "pending" { lifecycle.registration?(app, lifecycle.registrationStatus) }
      app.registerForRemoteNotifications()
      for _ in 0..<50 where lifecycle.registrationStatus == "pending" {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }

    // The real AppDelegate's task delegate receives the notification. This
    // separate controller sets up the same app-wide preferences via production
    // native commands; it is never registered as a lifecycle delegate.
    let config = ParentPush(taskReminders: true)
    func command(_ name: String, _ args: [String: Any] = [:]) async -> Any? {
      await withCheckedContinuation { continuation in
        config.handle(FlutterMethodCall(methodName: name, arguments: args)) {
          continuation.resume(returning: $0)
        }
      }
    }
    let cleared = await command("disable")
    let revision = try XCTUnwrap(cleared as? NSNumber)
    let begin = await command("beginClockSample", ["revision": revision])
    let sample = try XCTUnwrap(begin as? String)
    let enabled = await command("enable", ["revision": revision, "scope_nonce": Probe.scope,
      "server_ms": Probe.anchor, "expires_ms": Probe.anchor + 1_800_000, "settings_version": 1,
      "clock_sample": sample])
    XCTAssertEqual(enabled as? Bool, true)
    let at = Probe.anchor - 90_000
    let slot: [String: Any] = ["at": at, "timezone": "UTC", "quiet_start": "00:00:00", "quiet_end": "00:00:00"]
    let accepted = await command("plan", ["revision": revision, "slots": [slot]])
    XCTAssertEqual(accepted as? Bool, true)
    let subscription = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
      object: nil, queue: .main) { _ in
      DispatchQueue.main.async {
        do { try Probe.write("background", ["state": UIApplication.shared.applicationState.rawValue]) }
        catch { XCTFail("Could not record background state: \(error)") }
      }
    }
    defer { NotificationCenter.default.removeObserver(subscription) }

    let empty = await center.deliveredNotifications()
    XCTAssertFalse(empty.contains { $0.request.identifier == "task-remote-v1" })
    let wall = Date().timeIntervalSince1970
    let lease = FixtureBackgroundTask()
    if source == "native" {
      lease.start()
      XCTAssertNotEqual(lease.identifier, .invalid)
    }
    defer { lease.end() }
    try Probe.write("ready", ["ids": Probe.ids, "scope": Probe.scope, "anchor": Probe.anchor,
      "scheduled": at, "state": UIApplication.shared.applicationState.rawValue, "started": wall,
      "registrationRequested": source == "system", "registered": app.isRegisteredForRemoteNotifications,
      "registrationCallback": source == "system" ? lifecycle.registrationStatus : "notRequested",
      "backgroundRefreshStatus": app.backgroundRefreshStatus.rawValue,
      "remoteSelectorSupported": remoteSupported, "fetchSelectorSupported": appDelegate.responds(to: fetch),
      "pid": ProcessInfo.processInfo.processIdentifier, "authorization": settings.authorizationStatus.rawValue,
      "selector": NSStringFromSelector(selector), "encoding": originalTypes])

    // The host backgrounds Runner, sends each case using its selected source,
    // and returns the same process to the foreground after all completions.
    var resumed = false
    let cases = ["quiet", "scope", "expired", "allowed"]
    var next = 0
    for _ in 0..<2000 {
      if source == "native", app.applicationState == .background, next < cases.count {
        let name = cases[next]
        let file = Probe.root.appendingPathComponent("invoke-" + Probe.run + "-" + name + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
          let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
          XCTAssertEqual(data["message_id"] as? String, Probe.ids[name])
          // Invoke the real UIApplicationDelegate selector. Flutter forwards it to the same registered task delegate.
          let delegate = try XCTUnwrap(app.delegate)
          let state = app.applicationState.rawValue
          let outcome: UIBackgroundFetchResult = try await withCheckedThrowingContinuation { continuation in
            let called: Void? = delegate.application?(app, didReceiveRemoteNotification: data,
              fetchCompletionHandler: { continuation.resume(returning: $0) })
            if called == nil { continuation.resume(throwing: NSError(domain: "MissingUIApplicationDelegateSelector", code: 1)) }
          }
          try Probe.write("invoked-" + name, ["message": Probe.ids[name]!, "state": state, "result": outcome.rawValue])
          next += 1
          if next == cases.count { lease.end() }
        }
      }
      if FileManager.default.fileExists(atPath: Probe.root.appendingPathComponent("resume-" + Probe.run).path),
        UIApplication.shared.applicationState == .active { resumed = true; break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertTrue(resumed)
    if source == "native" { XCTAssertEqual(next, cases.count) }
    var delivered: [String] = []
    for _ in 0..<40 {
      let notifications = await center.deliveredNotifications()
      delivered = notifications.compactMap { note in
        guard note.request.identifier == "task-remote-v1",
          let data = note.request.content.userInfo["task_push"] as? [String: String] else { return nil }
        return data["message_id"]
      }
      if delivered == [Probe.ids["allowed"]!] { break }
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    let row = try XCTUnwrap(UserDefaults.standard.dictionary(forKey: "task_push_gate_v1"))
    let seen = try XCTUnwrap(row["seen"] as? [String])
    XCTAssertEqual(seen, [try XCTUnwrap(Probe.ids["allowed"])])
    XCTAssertEqual(delivered, seen)
    try Probe.write("complete", ["delivered": delivered, "seen": seen,
      "quietSuppressed": !seen.contains(Probe.ids["quiet"]!), "scopeRejected": !seen.contains(Probe.ids["scope"]!),
      "expiredRejected": !seen.contains(Probe.ids["expired"]!)])
    _ = await command("disable")
  }
}
#else
import Flutter
import UIKit
import XCTest

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

}
#endif
