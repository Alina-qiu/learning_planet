import Flutter
import UIKit
import UserNotifications
import Darwin
import CoreFoundation

// Native-only background delivery: never opens Flutter's account database or
// stores a session/token in UserDefaults. All state transitions run on main.
final class ParentPush: NSObject, FlutterApplicationLifeCycleDelegate {
  private let store = UserDefaults.standard
  private let key = "parent_push_gate_v1"
  private let revisionKey = "parent_push_revision_v1"
  private let ids = ["parent-remote-v1-redemption", "parent-remote-v1-weekly"]
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
    guard userInfo["version"] as? String == "parent-push-v1" else { return false }
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
    case "token": token(call.arguments as? [String: Any] ?? [:], result)
    default: result(FlutterMethodNotImplemented)
    }
  }
  private func disable(_ result: @escaping FlutterResult) {
    let next = revision + 1
    guard next > 0 && next <= 9_007_199_254_740_991 else { error(result); return }
    store.set(next, forKey: revisionKey)
    store.removeObject(forKey: key)
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
  private func allowed(_ data: [String: String], _ row: [String: Any]) -> Bool {
    let fields: Set<String> = ["version", "message_id", "scope_nonce", "kind", "issued_ms", "expires_ms", "timezone", "quiet_start", "quiet_end", "settings_version"]
    guard Set(data.keys) == fields, data["version"] == "parent-push-v1",
      let nonce = row["nonce"] as? String, nonce == data["scope_nonce"], matches(nonce, uuid),
      let id = data["message_id"], matches(id, uuid), let seen = row["seen"] as? [String],
      seen.count <= 1000, !seen.contains(id), ["redemption", "weekly"].contains(data["kind"] ?? ""),
      let rawVersion = data["settings_version"], matches(rawVersion, "[1-9][0-9]{0,15}"),
      let version = Int64(rawVersion), version <= 9_007_199_254_740_991,
      let minimum = number(row, "settings"), version >= minimum,
      let rawIssued = data["issued_ms"], matches(rawIssued, "[0-9]{13}"), let issued = Int64(rawIssued),
      let rawExpires = data["expires_ms"], matches(rawExpires, "[0-9]{13}"), let expires = Int64(rawExpires),
      let server = number(row, "server"), let until = number(row, "expires"), let rtt = number(row, "rtt"),
      let wall = number(row, "wall"), let elapsed = number(row, "elapsed"), let boot = row["boot"] as? String else { return false }
    let now = clock()
    let delta = now.elapsed - elapsed
    guard !boot.isEmpty, now.boot == boot, delta >= 0, (0...10000).contains(rtt), minimum > 0,
      (1_000_000_000_000...9_999_999_999_999).contains(server), (1...2_592_001_000).contains(until - server),
      abs((now.wall - wall) - delta) <= 30000 else { return false }
    let low = server + delta, high = low + rtt + 1000
    guard issued <= low + 30000, (1...60000).contains(expires - issued), expires > high, expires <= until, high < until,
      let start = data["quiet_start"], let end = data["quiet_end"],
      matches(start, "([01][0-9]|2[0-3]):[0-5][0-9]:00"), matches(end, "([01][0-9]|2[0-3]):[0-5][0-9]:00"),
      let zoneName = data["timezone"], zoneName.count <= 100, let zone = TimeZone(identifier: zoneName) else { return false }
    func seconds(_ text: String) -> Int { let parts = text.split(separator: ":").map { Int($0)! }; return parts[0] * 3600 + parts[1] * 60 }
    func quiet(_ millis: Int64) -> Bool {
      if start == end { return false }
      var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
      let parts = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: Double(millis) / 1000))
      let local = parts.hour! * 3600 + parts.minute! * 60 + parts.second!
      let a = seconds(start), b = seconds(end)
      return a < b ? (local >= a && local < b) : (local >= a || local < b)
    }
    return !quiet(low) && !quiet(high)
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
        content.body = copied["kind"] == "weekly" ? "上一周学习报告已更新" : "有兑换申请待审批"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "parent-remote-v1-\(copied["kind"]!)", content: content, trigger: nil)
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
