import Foundation

@main struct PushDeliveryPolicyChecks {
  static func main() {
    let now: Int64 = 1_793_937_600_000 // 2026-11-06T04:00:00Z
    let id = "10000000-0000-4000-8000-000000000001"
    let nonce = "10000000-0000-4000-8000-000000000002"
    let gate: [String: Any] = ["clock_version": PushDeliveryPolicy.clockVersion,
      "nonce": nonce, "seen": [String](), "settings": 3,
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
    var old = gate; old.removeValue(forKey: "clock_version")
    check(!allowed(data, old), "legacy task clock cannot authorize background receipt")
    check(!PushDeliveryPolicy.allows(parent, gate: old, clock: (now, 1000, "boot-a")), "legacy parent clock rejected")
    let sample = PushDeliveryPolicy.ClockSample(revision: 4, boot: "boot-a", elapsed: 1000)
    func width(_ elapsed: Int64, _ boot: String = "boot-a", _ revision: Int64 = 4, _ id: String? = nil) -> Int64? {
      sample.uncertainty(id: id ?? sample.id, revision: revision, boot: boot, elapsed: elapsed)
    }
    check(width(4050) == 3050, "RPC and delayed native settings callback both count")
    check(width(11000) == 10000 && width(11001) == nil, "native window limit")
    check(width(999) == nil && width(1050, "boot-b") == nil, "reset or reboot during RPC rejected")
    check(width(1050, "boot-a", 5) == nil && width(1050, "boot-a", 4, "other") == nil, "foreign sample rejected")
    // Only 50 ms elapsed before Dart dispatched enable. Native authorization
    // and the main queue take another 3 s. Receipt occurs 100 ms into quiet.
    var delayedGate = gate
    delayedGate["server"] = now - 20000; delayedGate["elapsed"] = 4050; delayedGate["wall"] = now - 17000
    delayedGate["expires"] = now + 86_400_000
    delayedGate["rtt"] = width(4050)!
    var delayedTask = data
    delayedTask["quiet_start"] = "12:00:00"; delayedTask["quiet_end"] = "13:00:00"
    delayedTask["issued_ms"] = String(now - 18000); delayedTask["expires_ms"] = String(now + 42000)
    let receipt = (wall: now + 100, elapsed: Int64(4050 + 17100), boot: "boot-a")
    var truncated = delayedGate; truncated["rtt"] = 50
    check(PushDeliveryPolicy.allows(delayedTask, gate: truncated, clock: receipt, task: true, plan: plan),
      "a truncated calibration window reproduces delivery 100 ms into quiet")
    check(!PushDeliveryPolicy.allows(delayedTask, gate: delayedGate, clock: receipt, task: true, plan: plan),
      "task received after quiet starts is suppressed")
    check(!PushDeliveryPolicy.allows(delayedTask, gate: delayedGate, clock: receipt, task: true, plan: plan, allowSeen: true),
      "foreground recheck includes the complete calibration window")
    var delayedParent = delayedTask
    delayedParent.removeValue(forKey: "scheduled_ms"); delayedParent["version"] = "parent-push-v1"; delayedParent["kind"] = "weekly"
    check(!PushDeliveryPolicy.allows(delayedParent, gate: delayedGate, clock: receipt), "delayed parent receipt is suppressed")
    let earlier = (wall: now - 5000, elapsed: Int64(4050 + 12000), boot: "boot-a")
    check(PushDeliveryPolicy.allows(delayedTask, gate: delayedGate, clock: earlier, task: true, plan: plan),
      "ordinary daytime delivery remains possible with the same native delay")
    print("All \(count) native push policy checks passed.")
  }
}
