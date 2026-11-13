import Foundation

@main struct PushDeliveryPolicyChecks {
  static func main() {
    let now: Int64 = 1_793_937_600_000 // 2026-11-06T04:00:00Z
    let id = "10000000-0000-4000-8000-000000000001"
    let nonce = "10000000-0000-4000-8000-000000000002"
    let gate: [String: Any] = ["nonce": nonce, "seen": [String](), "settings": 3,
      "server": now, "expires": now + 2_592_000_000, "rtt": 100,
      "wall": now, "elapsed": 1000, "boot": "boot-a"]
    let data = ["version": "task-push-v1", "kind": "task", "message_id": id, "scope_nonce": nonce,
      "scheduled_ms": String(now - 60000), "issued_ms": String(now), "expires_ms": String(now + 60000),
      "timezone": "Asia/Shanghai", "quiet_start": "21:00:00", "quiet_end": "07:00:00", "settings_version": "3"]
    let slot: [String: Any] = ["at": now - 60000, "timezone": "Asia/Shanghai", "quiet_start": "21:00:00", "quiet_end": "07:00:00"]
    let plan = PushDeliveryPolicy.plan([slot])!
    var count = 0
    func check(_ value: Bool, _ label: String) {
      precondition(value, label); count += 1
    }
    func allowed(_ d: [String: String]? = nil, _ g: [String: Any]? = nil,
      _ p: [String: [String: String]]? = nil, _ wall: Int64? = nil, _ elapsed: Int64 = 1000, _ boot: String = "boot-a") -> Bool {
      PushDeliveryPolicy.allows(d ?? data, gate: g ?? gate, clock: (wall ?? now, elapsed, boot), task: true, plan: p ?? plan)
    }
    check(allowed(), "valid task")
    check(!allowed(data, gate, [:]), "removed/completed slot")
    for (field, value) in [("scope_nonce", id), ("settings_version", "2"), ("version", "parent-push-v1"),
      ("expires_ms", String(now)), ("expires_ms", String(now + 60001)), ("scheduled_ms", String(now + 1)),
      ("timezone", "unknown-zone"), ("message_id", id + "\n"), ("quiet_start", "25:00:00")] {
      var changed = data; changed[field] = value;check(!allowed(changed), field)
    }
    var seen = gate;seen["seen"] = [id];check(!allowed(data, seen), "duplicate receipt")
    check(PushDeliveryPolicy.allows(data, gate: seen, clock: (now, 1000, "boot-a"), task: true, plan: plan, allowSeen: true), "foreground recheck")
    check(!allowed(data, gate, plan, now, 1000, "boot-b"), "reboot invalidates clock")
    check(!allowed(data, gate, plan, now + 31001), "wall clock jump")
    check(!allowed(data, gate, plan, now, 999), "continuous clock rollback")
    var quiet = data;quiet["quiet_start"] = "12:00:00";quiet["quiet_end"] = "13:00:00"
    check(!allowed(quiet), "server quiet start inclusive")
    quiet["quiet_start"] = "11:00:00";quiet["quiet_end"] = "12:00:00"
    check(allowed(quiet), "server quiet end exclusive")
    quiet["quiet_start"] = "12:00:01";quiet["quiet_end"] = "12:00:02"
    var uncertain = gate;uncertain["rtt"] = 10000
    check(!allowed(quiet, uncertain), "short quiet period within uncertainty interval")
    var local = plan;local[String(now - 60000)] = ["timezone": "Asia/Shanghai", "quiet_start": "12:00:00", "quiet_end": "13:00:00"]
    check(!allowed(data, gate, local), "newer local quiet policy")
    check(PushDeliveryPolicy.plan(Array(repeating: slot, count: 61)) == nil, "bounded plan")
    check(PushDeliveryPolicy.plan([slot, slot]) == nil, "duplicate slot")
    var invalid = slot;invalid["at"] = true
    check(PushDeliveryPolicy.plan([invalid]) == nil, "boolean not timestamp")
    var parent = data;parent.removeValue(forKey: "scheduled_ms");parent["version"] = "parent-push-v1";parent["kind"] = "weekly"
    check(PushDeliveryPolicy.allows(parent, gate: gate, clock: (now, 1000, "boot-a")), "parent path remains independent")
    print("All \(count) native push policy checks passed.")
  }
}
