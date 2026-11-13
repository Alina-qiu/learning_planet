import Foundation
import CoreFoundation

// Pure policy shared by background receipt and foreground presentation. Time
// comes from a server anchor advanced by the native continuous clock.
enum PushDeliveryPolicy {
  static func number(_ row: [String: Any], _ field: String) -> Int64? {
    guard let n = row[field] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
      n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
      abs(n.doubleValue) <= 9_007_199_254_740_991 else { return nil }
    return n.int64Value
  }
  static func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: "\\A(?:\(pattern))\\z", options: .regularExpression) != nil
  }
  static func quiet(_ millis: Int64, _ policy: [String: String]) -> Bool? {
    guard let start = policy["quiet_start"], let end = policy["quiet_end"],
      matches(start, "([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]"),
      matches(end, "([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]"),
      let name = policy["timezone"], name.count <= 100, let zone = TimeZone(identifier: name) else { return nil }
    if start == end { return false }
    func seconds(_ text: String) -> Int {
      let parts = text.split(separator: ":").map { Int($0)! }
      return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
    let parts = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: Double(millis) / 1000))
    let local = parts.hour! * 3600 + parts.minute! * 60 + parts.second!
    let a = seconds(start), b = seconds(end)
    return a < b ? local >= a && local < b : local >= a || local < b
  }
  static func plan(_ value: Any?) -> [String: [String: String]]? {
    guard let entries = value as? [[String: Any]], entries.count <= 60 else { return nil }
    var result: [String: [String: String]] = [:]
    for entry in entries {
      guard let at = number(entry, "at"), (1_000_000_000_000...9_999_999_999_999).contains(at),
        let zone = entry["timezone"] as? String, let start = entry["quiet_start"] as? String,
        let end = entry["quiet_end"] as? String, result[String(at)] == nil else { return nil }
      let policy = ["timezone": zone, "quiet_start": start, "quiet_end": end]
      guard quiet(at, policy) == false else { return nil }
      result[String(at)] = policy
    }
    return result
  }
  static func outsideQuiet(_ low: Int64, _ high: Int64, _ policy: [String: String]) -> Bool {
    guard high >= low, high - low <= 11000 else { return false }
    // Checking only the endpoints could miss a short quiet interval between
    // them. Include every second in the bounded server-clock uncertainty range.
    var instant = low
    while instant < high {
      if quiet(instant, policy) != false { return false }
      instant += 1000
    }
    return quiet(high, policy) == false
  }
  static func allows(_ data: [String: String], gate row: [String: Any],
    clock now: (wall: Int64, elapsed: Int64, boot: String), task: Bool = false,
    plan: [String: [String: String]] = [:], allowSeen: Bool = false) -> Bool {
    var fields: Set<String> = ["version", "message_id", "scope_nonce", "kind", "issued_ms", "expires_ms", "timezone", "quiet_start", "quiet_end", "settings_version"]
    if task { fields.insert("scheduled_ms") }
    let uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    guard Set(data.keys) == fields, data["version"] == (task ? "task-push-v1" : "parent-push-v1"),
      let nonce = row["nonce"] as? String, nonce == data["scope_nonce"], matches(nonce, uuid),
      let id = data["message_id"], matches(id, uuid), let seen = row["seen"] as? [String],
      seen.count <= 1000, allowSeen || !seen.contains(id),
      (task ? ["task"] : ["redemption", "weekly"]).contains(data["kind"] ?? ""),
      let rawVersion = data["settings_version"], matches(rawVersion, "[1-9][0-9]{0,15}"),
      let version = Int64(rawVersion), version <= 9_007_199_254_740_991,
      let minimum = number(row, "settings"), version >= minimum,
      let rawIssued = data["issued_ms"], matches(rawIssued, "[0-9]{13}"), let issued = Int64(rawIssued),
      let rawExpires = data["expires_ms"], matches(rawExpires, "[0-9]{13}"), let expires = Int64(rawExpires),
      let server = number(row, "server"), let until = number(row, "expires"), let rtt = number(row, "rtt"),
      let wall = number(row, "wall"), let elapsed = number(row, "elapsed"), let boot = row["boot"] as? String else { return false }
    let delta = now.elapsed - elapsed
    guard !boot.isEmpty, now.boot == boot, delta >= 0, (0...10000).contains(rtt), minimum > 0,
      (1_000_000_000_000...9_999_999_999_999).contains(server), (1...2_592_001_000).contains(until - server),
      abs((now.wall - wall) - delta) <= 30000 else { return false }
    let low = server + delta, high = low + rtt + 1000
    guard issued <= low + 30000, (1...60000).contains(expires - issued), expires > high, expires <= until, high < until,
      outsideQuiet(low, high, data) else { return false }
    if task {
      guard let raw = data["scheduled_ms"], matches(raw, "[0-9]{13}"), let at = Int64(raw), at <= low,
        expires <= at + 900000, let local = plan[raw],
        outsideQuiet(low, high, local) else { return false }
    }
    return true
  }
}
