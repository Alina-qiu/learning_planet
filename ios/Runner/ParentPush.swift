import Flutter
import UIKit
import UserNotifications
import Darwin
import CoreFoundation

// Native-only background delivery: never opens Flutter's account database or
// stores a session/token in UserDefaults. All state transitions run on main.
final class ParentPush: NSObject, FlutterApplicationLifeCycleDelegate {
  private let taskReminders: Bool
  init(taskReminders: Bool = false) { self.taskReminders = taskReminders; super.init() }
  private let store = UserDefaults.standard
  private var key: String { taskReminders ? "task_push_gate_v1" : "parent_push_gate_v1" }
  private var revisionKey: String { taskReminders ? "task_push_revision_v1" : "parent_push_revision_v1" }
  private let planKey = "task_push_plan_v1"
  private var ids: [String] { taskReminders ? ["task-remote-v1"] : ["parent-remote-v1-redemption", "parent-remote-v1-weekly"] }
  private var pendingTokens: [(Int64, FlutterResult)] = []
  private var pendingAdds = 0
  private var disabledCallbacks: [(Int64, FlutterResult)] = []
  private var revision: Int64 { (store.object(forKey: revisionKey) as? NSNumber)?.int64Value ?? 0 }

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    registered(deviceToken)
  }
  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    registered(nil)
  }
  func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
    guard userInfo["version"] as? String == (taskReminders ? "task-push-v1" : "parent-push-v1") else { return false }
    receive(userInfo, completion: completionHandler)
    return true
  }

  private func clock() -> (wall: Int64, elapsed: Int64, boot: String) {
    var base = mach_timebase_info_data_t()
    mach_timebase_info(&base)
    let elapsed = Int64(Double(mach_continuous_time()) * Double(base.numer) / Double(base.denom) / 1_000_000)
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    var value = timeval()
    var size = MemoryLayout<timeval>.size
    let success = sysctl(&mib, 2, &value, &size, nil, 0) == 0
    return (Int64(Date().timeIntervalSince1970 * 1000), elapsed, success ? "\(value.tv_sec):\(value.tv_usec)" : "")
  }
  private func cancelVisible() {
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: ids)
    center.removeDeliveredNotifications(withIdentifiers: ids)
  }
  private func error(_ result: FlutterResult) {
    result(FlutterError(code: "parent_push_unavailable", message: "后台提醒暂时不可用，请重试。", details: nil))
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "availability": result(["transport": "apns", "configured": true, "available": true,
      "revision": revision, "enabled": store.dictionary(forKey: key) != nil])
    case "startup" where UIApplication.shared.applicationState == .background: result(revision)
    case "startup", "disable": disable(result)
    case "enable": enable(call.arguments as? [String: Any] ?? [:], result)
    case "plan" where taskReminders:
      let input = call.arguments as? [String: Any] ?? [:]
      guard number(input, "revision") == revision else { result(false); return }
      guard let plan = PushDeliveryPolicy.plan(input["slots"]) else {
        store.removeObject(forKey: planKey)
        if store.synchronize() { result(false) } else { error(result) }
        return
      }
      store.set(plan, forKey: planKey)
      if store.synchronize() { result(true) } else { store.removeObject(forKey: planKey); error(result) }
    case "token": token(call.arguments as? [String: Any] ?? [:], result)
    default: result(FlutterMethodNotImplemented)
    }
  }
  private func disable(_ result: @escaping FlutterResult) {
    let next = revision + 1
    guard next > 0 && next <= 9_007_199_254_740_991 else { error(result); return }
    store.set(next, forKey: revisionKey)
    store.removeObject(forKey: key)
    if taskReminders { store.removeObject(forKey: planKey) }
    let saved = store.synchronize()
    cancelVisible()
    let tokens = pendingTokens
    pendingTokens.removeAll()
    tokens.forEach { $0.1(nil) }
    guard saved else { error(result); return }
    // Wait for already-submitted UN requests, then cancel again. A late add
    // completion cannot survive a completed logout/disable operation.
    if pendingAdds > 0 { disabledCallbacks.append((next, result)) }
    else { result(next) }
  }
  private func number(_ row: [String: Any], _ field: String) -> Int64? {
    guard let n = row[field] as? NSNumber,
      CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
      n.doubleValue.rounded() == n.doubleValue,
      abs(n.doubleValue) <= 9_007_199_254_740_991 else { return nil }
    return n.int64Value
  }
  private func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: "^(?:\(pattern))$", options: .regularExpression) != nil
  }
  private let uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  private func enable(_ input: [String: Any], _ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      DispatchQueue.main.async {
        let now = self.clock()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
          let expected = self.number(input, "revision"), expected == self.revision,
          let nonce = input["scope_nonce"] as? String, self.matches(nonce, self.uuid),
          let server = self.number(input, "server_ms"), (1_000_000_000_000...9_999_999_999_999).contains(server),
          let expires = self.number(input, "expires_ms"), (1...2_592_001_000).contains(expires - server),
          let rtt = self.number(input, "rtt_ms"), (0...10000).contains(rtt),
          let version = self.number(input, "settings_version"), version > 0, !now.boot.isEmpty else { result(false); return }
        let previous = self.store.dictionary(forKey: self.key)
        let seen: [String] = (previous?["nonce"] as? String) == nonce ? (previous?["seen"] as? [String] ?? []) : []
        guard seen.count <= 1000 else { result(false); return }
        let persisted: [String: Any] = ["nonce": nonce, "server": server, "expires": expires, "rtt": rtt,
          "settings": version, "wall": now.wall, "elapsed": now.elapsed, "boot": now.boot, "seen": seen]
        self.store.set(persisted, forKey: self.key)
        if self.store.synchronize() { result(true) } else { self.store.removeObject(forKey: self.key); self.error(result) }
      }
    }
  }
  private func token(_ input: [String: Any], _ result: @escaping FlutterResult) {
    guard let expected = number(input, "revision"), expected == revision else { result(nil); return }
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      DispatchQueue.main.async {
        guard self.revision == expected,
          settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { result(nil); return }
        self.pendingTokens.append((expected, result))
        UIApplication.shared.registerForRemoteNotifications()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
          let old = self.pendingTokens.filter { $0.0 == expected }
          self.pendingTokens.removeAll { $0.0 == expected }
          old.forEach { $0.1(nil) }
        }
      }
    }
  }
  func registered(_ token: Data?) {
    let value = token?.map { String(format: "%02x", $0) }.joined()
    let waiting = pendingTokens
    pendingTokens.removeAll()
    waiting.forEach { $0.1($0.0 == revision ? value : nil) }
  }
  private func allowed(_ data: [String: String], _ row: [String: Any], allowSeen: Bool = false) -> Bool {
    PushDeliveryPolicy.allows(data, gate: row, clock: clock(), task: taskReminders,
      plan: store.dictionary(forKey: planKey) as? [String: [String: String]] ?? [:], allowSeen: allowSeen)
  }
  func canPresent(_ content: UNNotificationContent) -> Bool {
    guard taskReminders, let data = content.userInfo["task_push"] as? [String: String],
      let expected = content.userInfo["revision"] as? NSNumber, expected.int64Value == revision,
      let row = store.dictionary(forKey: key) else { return false }
    return allowed(data, row, allowSeen: true)
  }
  func receive(_ userInfo: [AnyHashable: Any], completion: @escaping (UIBackgroundFetchResult) -> Void) {
    var data: [String: String] = [:]
    for (key, value) in userInfo {
      guard let name = key as? String else { completion(.noData); return }
      if name == "aps" {
        guard let aps = value as? [String: Any], aps.count == 1, (aps["content-available"] as? NSNumber)?.intValue == 1 else { completion(.noData); return }
      } else {
        guard let text = value as? String else { completion(.noData); return }
        data[name] = text
      }
    }
    guard data.values.reduce(0, { $0 + $1.utf8.count }) <= 4096 else { completion(.noData); return }
    let copied = data
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      DispatchQueue.main.async {
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
          var row = self.store.dictionary(forKey: self.key), self.allowed(copied, row) else { completion(.noData); return }
        let expected = self.revision
        row["seen"] = Array(((row["seen"] as? [String] ?? []) + [copied["message_id"]!]).suffix(1000))
        self.store.set(row, forKey: self.key)
        guard self.store.synchronize() else { completion(.failed); return }
        let content = UNMutableNotificationContent()
        content.title = "学习星球"
        content.body = self.taskReminders ? "有学习任务需要关注，请打开应用查看。" : copied["kind"] == "weekly" ? "上一周学习报告已更新" : "有兑换申请待审批"
        content.sound = .default
        if self.taskReminders { content.userInfo = ["task_push": copied, "revision": expected] }
        let request = UNNotificationRequest(identifier: self.taskReminders ? "task-remote-v1" : "parent-remote-v1-\(copied["kind"]!)", content: content, trigger: nil)
        self.pendingAdds += 1
        UNUserNotificationCenter.current().add(request) { failure in
          DispatchQueue.main.async {
            self.pendingAdds -= 1
            if expected != self.revision { self.cancelVisible() }
            if self.pendingAdds == 0 && !self.disabledCallbacks.isEmpty {
              self.cancelVisible()
              let callbacks = self.disabledCallbacks; self.disabledCallbacks.removeAll()
              callbacks.forEach { $0.1($0.0) }
            }
            completion(failure == nil ? .newData : .failed)
          }
        }
      }
    }
  }
}
